import Foundation

// MARK: - F2-A actionable-push REST surface
//

// Two endpoints the notification-action + Live-Activity paths reach, kept on
// `RestClient` so they inherit the loopback `Host` override, the
// `X-Hermes-Session-Token` auth header, the ephemeral session, and the 15s
// timeout (no cloned plumbing). Both run fine from a background notification
// action: `RestClient` is a `Sendable` struct over an ephemeral `URLSession`
// with no actor isolation, so the `UNUserNotificationCenterDelegate` callback
// (which runs the app in the background) can build one and call these without
// touching the main actor.
//

// These deliberately DO NOT use `perform(_:)` (which throws on any non-2xx):
// the respond endpoint's whole contract is in the status code — 200 carries
// `{"resolved":bool}`, 404 means the runtime is gone, 401 a bad token — so we
// classify the status into a typed outcome instead of mapping everything to a
// thrown error. The Live-Activity register/unregister likewise wants a soft
// classification (404 = endpoint not deployed) rather than a throw, mirroring
// `PushTokenPoster`.
extension RestClient {

    /// Outcome of `POST /api/approvals/respond`.
    ///

    /// Mirrors the spec's status semantics:
    ///  - 200 `{"resolved": true}` → the approval was pending and is now resolved.
    ///  - 200 `{"resolved": false}` → nothing pending / already handled elsewhere.
    ///  - 404 → the runtime session is gone (also "already
    ///  handled" from the user's perspective — the prompt window closed).
    ///  - 401 / transport / other → could not deliver; the inbox stays
    ///  authoritative and the user can retry.
    enum ApprovalRespondOutcome: Sendable, Equatable {
        /// 200 with `resolved == true`.
        case resolved
        /// 200 with `resolved == false`, OR 404 — both mean "already handled /
        /// nothing to do here", which the action path surfaces as a local
        /// "Already handled elsewhere" feedback notification.
        case alreadyHandled
        /// 401, a 5xx, a transport failure, or an undecodable body. The send did
        /// not land authoritatively; keep the inbox as the source of truth.
        case failed
    }

    /// `POST <prefix>/approvals/respond {"session_id","choice","all"}`.
    ///

    /// - Parameters:
    ///  - sessionId: the **runtime** session id the approval belongs to.
    ///  - approve: `true` → `"approve"`, `false` → `"deny"`.
    ///  - all: approve/deny every remaining request in that turn.
    /// - Returns: a classified ``ApprovalRespondOutcome``; never throws.
    ///

    /// Self-healing path-family retry: this runs from a
    /// background-launched notification action, where the cached
    /// ``APIPathStyle`` can be stale (the gateway swapped legacy↔plugin under
    /// the same URL). A `404` is ambiguous there — missing route vs. gone
    /// session — so on the FIRST 404 the call retries once on the alternate
    /// family. Resolution is idempotent server-side (a second resolve returns
    /// `resolved:false`), and a 404 on BOTH families is the genuine
    /// "runtime session gone" → `.alreadyHandled`, matching the old contract.
    func respondToApproval(
        sessionId: String,
        approve: Bool,
        all: Bool
    ) async -> ApprovalRespondOutcome {
        let first = await respondToApprovalAttempt(
            style: pathStyle, sessionId: sessionId, approve: approve, all: all
        )
        guard case .routeMiss = first else { return first.outcome }
        let second = await respondToApprovalAttempt(
            style: pathStyle.alternate, sessionId: sessionId, approve: approve, all: all
        )
        return second.outcome
    }

    /// One respond attempt against one path family. `routeMiss` keeps the 404
    /// distinguishable so the caller can retry the alternate family exactly once.
    private enum RespondAttempt {
        case outcome(ApprovalRespondOutcome)
        case routeMiss

        var outcome: ApprovalRespondOutcome {
            switch self {
            case .outcome(let value): return value
            case .routeMiss: return .alreadyHandled
            }
        }
    }

    private func respondToApprovalAttempt(
        style: APIPathStyle,
        sessionId: String,
        approve: Bool,
        all: Bool
    ) async -> RespondAttempt {
        var request = makeRequest(
            path: "\(style.mobileAPIPrefix)/approvals/respond", method: "POST"
        )
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: JSONValue = .object([
            "session_id": .string(sessionId),
            "choice": .string(approve ? "approve" : "deny"),
            "all": .bool(all),
        ])
        guard let payload = try? encodeBody(body, context: "approvals/respond") else {
            return .outcome(.failed)
        }
        request.httpBody = payload

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            return .outcome(.failed)
        }
        guard let http = response as? HTTPURLResponse else { return .outcome(.failed) }
        switch http.statusCode {
        case 200, 201:
            // Decode `{"resolved": bool}`. A missing/odd body on a 2xx is treated
            // as "already handled" rather than a hard failure — the server
            // accepted the request, so the inbox should clear regardless.
            let root = try? decodeJSONValue(from: data, context: "approvals/respond")
            let resolved = root?["resolved"]?.boolValue ?? false
            return .outcome(resolved ? .resolved : .alreadyHandled)
        case 404:
            return .routeMiss
        default:
            // 401 (bad token), 4xx, 5xx → could not deliver authoritatively.
            return .outcome(.failed)
        }
    }

    // MARK: - Pending-approvals catch-up (reconnect recovery)

    /// `GET <prefix>/approvals/pending` → `{"pending":[...]}`.
    ///
    /// The catch-up fetch: re-pulls every approval/clarify the server still holds
    /// pending, so a prompt the app missed while suspended in the background (a
    /// dropped WS broadcast) is recovered on reconnect. Soft and non-throwing,
    /// mirroring ``respondToApproval`` and the spec's gotchas:
    ///  - non-200 (incl. 401/403 bad-or-missing auth) → `[]` ("show nothing",
    ///    never an error state).
    ///  - empty store → `200 {"pending":[]}` → `[]`.
    ///  - records are decoded tolerantly (`PendingPrompt.init?(record:)`); a
    ///    malformed entry is skipped, not fatal to the batch.
    ///
    /// Self-healing path-family retry (same rationale as `respondToApproval`):
    /// the cached ``APIPathStyle`` can be stale after a gateway swap, so a `404`
    /// on the resolved family retries once on the alternate before giving up.
    func pendingPrompts() async -> [PendingPrompt] {
        let first = await pendingPromptsAttempt(style: pathStyle)
        if case .routeMiss = first {
            if case .ok(let prompts) = await pendingPromptsAttempt(style: pathStyle.alternate) {
                return prompts
            }
            return []
        }
        if case .ok(let prompts) = first { return prompts }
        return []
    }

    private enum PendingPromptsAttempt {
        case ok([PendingPrompt])
        /// 404 — route missing on this family; caller retries the alternate once.
        case routeMiss
        /// Any other non-200 / transport / undecodable → treat as empty.
        case empty
    }

    private func pendingPromptsAttempt(style: APIPathStyle) async -> PendingPromptsAttempt {
        let request = makeRequest(
            path: "\(style.mobileAPIPrefix)/approvals/pending", method: "GET"
        )
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            return .empty
        }
        guard let http = response as? HTTPURLResponse else { return .empty }
        switch http.statusCode {
        case 200, 201:
            guard
                let root = try? decodeJSONValue(from: data, context: "approvals/pending"),
                let array = root["pending"]?.arrayValue
            else { return .ok([]) }
            return .ok(array.compactMap(PendingPrompt.init(record:)))
        case 404:
            return .routeMiss
        default:
            // 401/403 bad-or-missing auth, 5xx, etc. → show nothing, not an error.
            return .empty
        }
    }

    // MARK: - Live Activity token registration (A3)

    /// Result of a Live-Activity token register/unregister call. Soft, never a
    /// throw — a 404 just means the patched endpoint isn't deployed on this
    /// gateway, which must not break a device that can still run the activity
    /// locally.
    enum LiveActivityTokenOutcome: Sendable, Equatable {
        case success
        /// 404 — `/api/push/live-activity` isn't routed on this gateway.
        case notDeployed
        /// Any other status or a transport error.
        case failed
    }

    /// `POST /api/push/live-activity {"token","session_id","env"}` — upsert the
    /// activity's push token, keyed by session id. Re-POST on rotation.
    func registerLiveActivity(
        token: String,
        sessionId: String,
        env: String
    ) async -> LiveActivityTokenOutcome {
        await sendLiveActivity(method: "POST", token: token, sessionId: sessionId, env: env)
    }

    /// `DELETE /api/push/live-activity {"token","session_id","env"}` — unregister
    /// on activity end.
    func unregisterLiveActivity(
        token: String,
        sessionId: String,
        env: String
    ) async -> LiveActivityTokenOutcome {
        await sendLiveActivity(method: "DELETE", token: token, sessionId: sessionId, env: env)
    }

    /// Self-healing path-family retry: Live-Activity registration can
    /// race the connect-time capability probe (APNs callbacks are OS-timed), so
    /// a `404` on the resolved family retries once on the alternate. A 404 on
    /// BOTH families is the genuine "endpoint not deployed" → `.notDeployed`.
    private func sendLiveActivity(
        method: String,
        token: String,
        sessionId: String,
        env: String
    ) async -> LiveActivityTokenOutcome {
        let first = await sendLiveActivityAttempt(
            style: pathStyle, method: method, token: token, sessionId: sessionId, env: env
        )
        guard first == .notDeployed else { return first }
        return await sendLiveActivityAttempt(
            style: pathStyle.alternate, method: method, token: token,
            sessionId: sessionId, env: env
        )
    }

    private func sendLiveActivityAttempt(
        style: APIPathStyle,
        method: String,
        token: String,
        sessionId: String,
        env: String
    ) async -> LiveActivityTokenOutcome {
        var request = makeRequest(
            path: "\(style.mobileAPIPrefix)/push/live-activity", method: method
        )
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: JSONValue = .object([
            "token": .string(token),
            "session_id": .string(sessionId),
            "env": .string(env),
        ])
        guard let payload = try? encodeBody(body, context: "push/live-activity") else {
            return .failed
        }
        request.httpBody = payload
        do {
            let (_, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return .failed }
            if (200..<300).contains(http.statusCode) { return .success }
            if http.statusCode == 404 { return .notDeployed }
            return .failed
        } catch {
            return .failed
        }
    }
}
