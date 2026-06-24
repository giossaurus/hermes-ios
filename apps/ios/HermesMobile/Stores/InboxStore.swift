import Foundation
#if DEBUG
import DebugBridgeCore  // @Snapshotable marker for the gstack debug bridge (UI-G)
#endif

/// Observable owner of the global approval / clarification inbox.
///

/// Where `ChatStore` only surfaces the approval / clarification belonging to the
/// transcript currently on screen, `InboxStore` accumulates **every**
/// `approval.request` / `clarify.request` the gateway emits — across all
/// sessions — because the gateway broadcasts these prompts to every connected
/// client (`HERMES_GATEWAY_BROADCAST=1`) and each carries its own `session_id`
/// (+ `stored_session_id`). This gives the user one place to clear pending
/// agent prompts no matter which session raised them, including turns driven by
/// another client (e.g. the desktop) or by a background cron session.
///

/// Each item is answered against **its own** `sessionId`, not the active
/// session: a broadcast approval from a foreign runtime must be resolved on
/// that runtime or it will hang forever. Answering removes the item; a
/// `message.complete` for an item's session marks any still-pending items for
/// that session as `expired` (the turn moved on without an answer, so the
/// prompt window is gone).
///

/// The store is fed by `ConnectionStore`'s event router via a single
/// ``handle(event:)`` call (see integration notes) and holds a back-reference
/// to the shared `HermesGatewayClient` for responses. That reference is set
/// once in ``attach(connection:)`` and lives for the app's lifetime.
@MainActor
@Observable
final class InboxStore {
    /// Whether an item is an approval or a free-form clarification.
    enum Kind: Sendable, Equatable {
        case approval
        case clarify
    }

    /// Lifecycle of an inbox item.
    enum ItemState: Sendable, Equatable {
        /// Awaiting a user response.
        case pending
        /// The user answered it (kept transiently before removal / for tests).
        case answered
        /// The owning turn completed before it was answered — no longer actionable.
        case expired
    }

    /// The typed payload behind an item. Mirrors the two prompt shapes the
    /// gateway emits, reusing the frozen wire payload types.
    enum Payload: Sendable, Equatable {
        case approval(ApprovalRequestPayload)
        case clarify(ClarifyRequestPayload)
    }

    /// One accumulated prompt awaiting (or having received) a response.
    struct Item: Identifiable, Sendable, Equatable {
        /// Stable identity for the row. For approvals this is the gateway's
        /// approval id; for clarifications (which carry no id on the wire) a
        /// synthesized UUID string, so SwiftUI keeps list identity stable.
        let id: String
        /// Runtime `session_id` the prompt belongs to — the target of the
        /// response RPC.
        let sessionId: String
        /// Persistent `stored_session_id`, when the gateway broadcast included
        /// it. Used for session-title lookup against `SessionStore`.
        let storedSessionId: String?
        let kind: Kind
        let payload: Payload
        let receivedAt: Date
        var state: ItemState

        /// Title shown in the row, derived from the payload.
        var title: String {
            switch payload {
            case .approval(let request): return request.title
            case .clarify(let request): return request.question
            }
        }

        /// One-line supporting text shown under the title, when available.
        var subtitle: String? {
            switch payload {
            case .approval(let request):
                if let description = request.descriptionText, !description.isEmpty { return description }
                return request.target
            case .clarify(let request):
                return request.choices.isEmpty ? nil : request.choices.joined(separator: " · ")
            }
        }
    }

    /// All accumulated items, newest first.
    private(set) var items: [Item] = []

    /// Number of items still awaiting a response — drives toolbar badges.
    #if DEBUG
    @Snapshotable
    #endif
    var pendingCount: Int {
        items.lazy.filter { $0.state == .pending }.count
    }

    /// Items still awaiting a response, newest first. The view's primary list.
    var pendingItems: [Item] {
        items.filter { $0.state == .pending }
    }

    // MARK: - Presentation request (B5 push tap routing)

    /// Monotonic token bumped whenever something (a push tap whose session can't
    /// be located) asks the UI to surface the inbox. The shell (B1 — RootView /
    /// drawer) observes this and presents `InboxView` on change. A token (rather
    /// than a `Bool`) means repeated requests always re-trigger, and there is no
    /// flag for the view to have to clear.
    private(set) var presentationRequestToken: Int = 0

    /// Ask the shell to surface the inbox. Used by `HermesURLRouter.routePushTap`
    /// when an approval/clarify push arrives for a session that isn't in the
    /// loaded list, so the user can still reach the pending prompt.
    func requestPresentation() {
        presentationRequestToken &+= 1
    }

    /// The stored-session id for a given runtime `session_id`, if any accumulated
    /// item carries that mapping. Push payloads carry the **runtime** session id;
    /// `SessionStore.open(_:)` needs the **stored** id, so this bridges the two
    /// using the broadcast prompts the inbox already holds.
    func storedSessionId(forRuntime sessionId: String) -> String? {
        items.first { $0.sessionId == sessionId }?.storedSessionId
    }

    private var connection: ConnectionStore?

    /// Ids the user has already answered/dismissed this session. The catch-up
    /// fetch (``catchUp(_:)``) consults this so a server record that hasn't been
    /// GC'd yet (the store keeps entries until `created_at + ttl`) can't
    /// resurrect a row the user just cleared. Bounded to the most recent ids.
    private var answeredIds: [String] = []
    private static let answeredIdCap = 256

    init() {}

    /// Wire up the gateway client back-reference. Called exactly once by
    /// `AppEnvironment`.
    func attach(connection: ConnectionStore) {
        self.connection = connection
    }

    private var client: HermesGatewayClient? { connection?.client }

    // MARK: - Event handling

    /// Route a gateway event into the inbox.
    ///

    /// `approval.request` / `clarify.request` are accumulated (deduped by id).
    /// `message.complete` expires any still-pending items for that event's
    /// session — the turn finished without the prompt being answered here, so
    /// it can no longer be acted on. All other event types are ignored.
    ///

    /// Unlike `ChatStore`, this is session-agnostic: it accepts prompts from
    /// every session the gateway broadcasts, which is the whole point of the
    /// inbox.
    func handle(event: GatewayEvent) {
        switch event.type {
        case .approvalRequest:
            ingestApproval(event)
        case .clarifyRequest:
            ingestClarify(event)
        case .messageComplete:
            if let sessionId = event.sessionId { expirePending(forSession: sessionId) }
        default:
            break
        }
    }

    private func ingestApproval(_ event: GatewayEvent) {
        guard let sessionId = event.sessionId, !sessionId.isEmpty else { return }
        let request = ApprovalRequestPayload(payload: event.payload)
        let item = Item(
            id: request.id,
            sessionId: sessionId,
            storedSessionId: event.storedSessionId,
            kind: .approval,
            payload: .approval(request),
            receivedAt: Date(),
            state: .pending
        )
        insert(item)
    }

    private func ingestClarify(_ event: GatewayEvent) {
        guard let sessionId = event.sessionId, !sessionId.isEmpty else { return }
        let request = ClarifyRequestPayload(payload: event.payload)
        // Clarifications carry no wire id; key them by session so a repeat
        // clarify on the same runtime replaces the previous one rather than
        // stacking stale prompts.
        let item = Item(
            id: "clarify:\(sessionId)",
            sessionId: sessionId,
            storedSessionId: event.storedSessionId,
            kind: .clarify,
            payload: .clarify(request),
            receivedAt: Date(),
            state: .pending
        )
        insert(item)
    }

    // MARK: - Catch-up (reconnect recovery)

    /// Merge a catch-up batch from `GET /approvals/pending` into the inbox.
    ///
    /// Called on (re)connect and on foreground so prompts the app missed while
    /// suspended in the background (a dropped WS broadcast) are recovered — the
    /// fix for "the approval card never appears after the app reconnects". Reuses
    /// the live path's payload parsers AND its id scheme, so a recovered prompt
    /// dedups against one already received over the socket:
    ///  - approvals key off `approval_id` (the gateway's stable id);
    ///  - clarifications key off `clarify:<sessionId>` (they carry no stable
    ///    wire id, matching ``ingestClarify``).
    ///
    /// A record is skipped when its id is already present (live event wins) or
    /// was already answered/dismissed this session (``answeredIds`` — stops a
    /// not-yet-GC'd server record from re-adding a just-cleared row). Records
    /// past `created_at + ttl` land as `.expired` so a stale prompt greys out
    /// rather than inviting an answer the gateway has already dropped.
    func catchUp(_ prompts: [PendingPrompt]) {
        for prompt in prompts {
            let kind: Kind = prompt.kind == .approval ? .approval : .clarify
            let id = kind == .approval ? prompt.id : "clarify:\(prompt.sessionId)"
            guard !answeredIds.contains(id),
                  !items.contains(where: { $0.id == id }) else { continue }

            let payload: Payload = kind == .approval
                ? .approval(ApprovalRequestPayload(payload: prompt.payload))
                : .clarify(ClarifyRequestPayload(payload: prompt.payload))
            let receivedAt = prompt.createdAt.map { Date(timeIntervalSince1970: $0) } ?? Date()
            let item = Item(
                id: id,
                sessionId: prompt.sessionId,
                storedSessionId: prompt.storedSessionId,
                kind: kind,
                payload: payload,
                receivedAt: receivedAt,
                state: isExpired(prompt) ? .expired : .pending
            )
            insertPreservingOrder(item)
        }
    }

    /// Whether a catch-up record is past its server-side validity window
    /// (`created_at + ttl`). Without both fields it is treated as live.
    private func isExpired(_ prompt: PendingPrompt) -> Bool {
        guard let createdAt = prompt.createdAt, let ttl = prompt.ttl else { return false }
        return Date().timeIntervalSince1970 > createdAt + Double(ttl)
    }

    /// Insert a catch-up item keeping the list newest-first by `receivedAt`.
    /// Live items (`insert`) prepend with `receivedAt == now`; catch-up items
    /// carry the older server `created_at`, so a plain prepend would mis-order
    /// them — slot each at the first position older than it instead.
    private func insertPreservingOrder(_ item: Item) {
        if let index = items.firstIndex(where: { $0.receivedAt < item.receivedAt }) {
            items.insert(item, at: index)
        } else {
            items.append(item)
        }
    }

    /// Insert (or replace) an item, keeping the list newest-first. A repeat of
    /// the same id refreshes the payload and re-arms it as pending.
    private func insert(_ item: Item) {
        if let index = items.firstIndex(where: { $0.id == item.id }) {
            items[index] = item
        } else {
            items.insert(item, at: 0)
        }
    }

    /// Mark every still-pending item belonging to `sessionId` as expired.
    private func expirePending(forSession sessionId: String) {
        for index in items.indices where items[index].sessionId == sessionId && items[index].state == .pending {
            items[index].state = .expired
        }
    }

    // MARK: - Responses

    /// Answer an approval item against its **own** session, then remove it.
    ///

    /// - Parameters:
    ///  - item: the inbox item to answer (must be `.approval`).
    ///  - approve: `true` to approve, `false` to deny.
    ///  - all: approve/deny all remaining requests in that turn.
    func respondApproval(_ item: Item, approve: Bool, all: Bool) async {
        guard case .approval = item.payload, let client else { return }
        let choice = approve ? "approve" : "deny"
        // Optimistically remove so the row clears instantly; restore on failure
        // so the user can retry rather than losing the prompt.
        removeItem(id: item.id)
        do {
            _ = try await client.requestRaw(
                "approval.respond",
                params: .object([
                    "session_id": .string(item.sessionId),
                    "choice": .string(choice),
                    "all": .bool(all),
                ])
            )
        } catch {
            rearm(item)
        }
    }

    /// Answer a clarification item against its **own** session, then remove it.
    ///

    /// The reply MUST echo the request's `request_id` — the gateway routes
    /// clarify answers via `_pending[request_id]` (`tui_gateway/server.py`
    /// `_respond`), and a reply without it 4009s ("no pending clarify
    /// request"), leaving the agent blocked on the prompt (item 2).
    func respondClarification(_ item: Item, answer: String) async {
        guard case .clarify(let request) = item.payload, let client else { return }
        let trimmed = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        removeItem(id: item.id)
        var params: [String: JSONValue] = [
            "session_id": .string(item.sessionId),
            "answer": .string(trimmed),
        ]
        if let rid = request.requestId {
            params["request_id"] = .string(rid)
        }
        do {
            _ = try await client.requestRaw("clarify.respond", params: .object(params))
        } catch {
            rearm(item)
        }
    }

    /// Drop an item without answering (user dismissed it). Recorded as answered
    /// so the catch-up fetch won't re-add it before the server GCs the record.
    func dismiss(_ item: Item) {
        markAnswered(item.id)
        items.removeAll { $0.id == item.id }
    }

    /// Drop all expired items — a tidy-up the view can offer.
    func clearExpired() {
        items.removeAll { $0.state == .expired }
    }

    // MARK: - Response bookkeeping

    /// Remove an item by id (optimistic clear on send). Recorded as answered so
    /// a catch-up fetch racing the server GC can't resurrect it.
    private func removeItem(id: String) {
        markAnswered(id)
        items.removeAll { $0.id == id }
    }

    /// Note an id as answered/dismissed this session (bounded, newest-kept). A
    /// later ``catchUp(_:)`` skips ids in this list even if the server still
    /// reports them pending (it holds records until `created_at + ttl`).
    private func markAnswered(_ id: String) {
        answeredIds.removeAll { $0 == id }
        answeredIds.append(id)
        if answeredIds.count > Self.answeredIdCap {
            answeredIds.removeFirst(answeredIds.count - Self.answeredIdCap)
        }
    }

    /// Restore a pending item whose response failed to send, so the user can
    /// retry. Skipped if a newer item with the same id already arrived (a
    /// gateway re-emit), which is authoritative.
    private func rearm(_ item: Item) {
        guard !items.contains(where: { $0.id == item.id }) else { return }
        var restored = item
        restored.state = .pending
        insert(restored)
    }
}
