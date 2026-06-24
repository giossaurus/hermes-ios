import Foundation
import LocalAuthentication
import UIKit
import UserNotifications

/// Local notifications + haptics for approval / clarification prompts and turn
/// completion.
///

/// All entry points are `@MainActor`. Authorization is requested *lazily* — the
/// first time an approval/clarify actually arrives — so the user is never
/// ambushed with a permission dialog at first launch; the "asked once" flag is
/// persisted in `UserDefaults`.
///

/// Because iOS suspends the WebSocket while the app is backgrounded, these
/// notifications effectively fire while the app is active or just-foregrounded.
/// That is expected v1 behavior. The future path for true background delivery is
/// APNs (the gateway pushing remote notifications when a turn needs the user),
/// which would replace these local-only requests.
@MainActor
enum NotificationService {
    // Notification category identifiers — these are `UNNotificationCategory`
    // identifiers, NOT `UserDefaults` keys, so they stay local to this type.
    //

    // The `hermes.*` ids are the LOCAL-notification categories (B-wave, fired
    // in-process). The `HERMES_*` ids are the REMOTE APNs categories the gateway
    // stamps into `aps.category` (F2-S), which carry the actionable buttons. The
    // two namespaces coexist: a local approval notification has no action buttons
    // (it routes a tap to the inbox), while a remote `HERMES_APPROVAL` push
    // renders Approve / Deny inline (A1).
    private static let approvalCategory = "hermes.approval"
    private static let clarifyCategory = "hermes.clarify"

    // MARK: - Actionable push categories + actions (A1)
    //

    // BINDING (contract A1): registered exactly as
    //  HERMES_APPROVAL → APPROVE [.authenticationRequired],
    //  DENY [.destructive, .authenticationRequired]
    //  HERMES_CLARIFY / HERMES_TURN → no actions (open-app only).
    //

    // `.authenticationRequired` is the OS-level half of the BINDING "no approval
    // action may fire from a locked, unauthenticated device": iOS will not even
    // deliver an `.authenticationRequired` action to the app until the device is
    // unlocked, so a locked-screen Approve/Deny tap first forces a device unlock.
    // (Verified against the SDK: `UNNotificationActionOptionAuthenticationRequired`
    // in UNNotificationAction.h.) The app-level half — an explicit `LAContext`
    // re-check for destructive approvals — is layered on top in `didReceive`.

    // `nonisolated` so the nonisolated decoders (`decodeTap`) and the unit tests
    // can read them without hopping to the main actor; they're immutable string
    // constants, so this is sound.

    /// Remote APNs category id for an approval request (carries action buttons).
    nonisolated static let remoteApprovalCategory = "HERMES_APPROVAL"
    /// Remote APNs category id for a clarification (open-app only).
    nonisolated static let remoteClarifyCategory = "HERMES_CLARIFY"
    /// Remote APNs category id for a long-turn completion (open-app only).
    nonisolated static let remoteTurnCategory = "HERMES_TURN"

    /// Action id for the inline "Approve" button on a `HERMES_APPROVAL` push.
    nonisolated static let approveActionIdentifier = "APPROVE"
    /// Action id for the inline "Deny" button on a `HERMES_APPROVAL` push.
    nonisolated static let denyActionIdentifier = "DENY"

    // MARK: - Tap routing (B5)

    /// What a tapped notification asks the app to do, decoded from the push
    /// payload's `event_type` + `session_id`. Both the local notifications fired
    /// here and the remote APNs alerts the gateway sends (see `push_notify.py` /
    /// `tui_gateway/server.py` `_push_hook`) share this contract: the custom keys
    /// live under the `hermes` block of the APNs payload, namespaced as
    /// `{"hermes": {"event_type": "approval"|"clarify"|"turn_complete",
    /// "session_id": <runtime sid>}}`. Local notifications post the same keys flat
    /// in `userInfo` (no `aps` envelope), so the decoder looks in both places.
    enum Tap: Sendable, Equatable {
        /// An approval / clarification needs the user — open its session (and
        /// surface the inbox if the session can't be located).
        case attention(sessionId: String)
        /// A long turn finished — open its session.
        case turnComplete(sessionId: String)
    }

    /// The app-supplied sink that routes a decoded tap into the live store graph.
    /// Wired once at launch by `HermesMobileApp` (it forwards to
    /// `HermesURLRouter.routePushTap`). Set on the main actor; read on the main
    /// actor from the delegate callback after a hop.
    nonisolated(unsafe) static var tapHandler: (@MainActor (Tap) -> Void)?

    /// Install the app's tap router. Idempotent; safe to call at launch.
    static func setTapHandler(_ handler: @escaping @MainActor (Tap) -> Void) {
        installDelegateIfNeeded()
        registerCategories()
        tapHandler = handler
    }

    // MARK: - Action backend resolution (A2)

    /// Resolved gateway endpoint for the approval-action REST call: the base URL
    /// and the session token, packaged so the (possibly background-launched)
    /// notification-action delegate can build a ``RestClient`` without reaching
    /// into the `@MainActor` store graph.
    struct ActionEndpoint: Sendable {
        let baseURL: URL
        let token: String
        /// REST path family for the mobile endpoints. Resolved from
        /// the live/cached capability snapshot; a stale value self-heals via
        /// ``RestClient/respondToApproval``'s alternate-family 404 retry.
        var pathStyle: APIPathStyle = .legacy
    }

    /// App-supplied resolver for the current gateway endpoint. Wired once at
    /// launch by `HermesMobileApp` off the live `ConnectionStore` (mirrors how
    /// `PushRegistrar.makePoster()` resolves URL + token). Read on the main actor
    /// from the action callback. `nil` when the app isn't configured yet, in
    /// which case the action falls back to a feedback notification.
    nonisolated(unsafe) static var endpointProvider: (@MainActor () -> ActionEndpoint?)?

    /// Seam over `LAContext` so the destructive-approval gate is unit-testable
    /// (XCTest can't satisfy a real biometric prompt). Defaults to the live
    /// `LAContext`-backed implementation reused from ``AppLock``.
    nonisolated(unsafe) static var biometricAuthenticator: BiometricAuthenticating
        = LAContextAuthenticator()

    /// Install the action backend resolver (endpoint + categories). Idempotent.
    static func setActionEndpointProvider(_ provider: @escaping @MainActor () -> ActionEndpoint?) {
        installDelegateIfNeeded()
        registerCategories()
        endpointProvider = provider
    }

    // MARK: - Approval action handling (A2)

    /// Whether a given action identifier maps to approve vs deny. `nil` for any
    /// other action (e.g. the default open-app tap, dismiss).
    ///

    /// Pure mapping, exposed for the unit tests (A5: action→request mapping).
    nonisolated static func approveChoice(for actionIdentifier: String) -> Bool? {
        switch actionIdentifier {
        case approveActionIdentifier: return true
        case denyActionIdentifier: return false
        default: return nil
        }
    }

    /// Handle an `APPROVE` / `DENY` notification action.
    ///

    /// Flow (contract A2):
    ///  1. Decode the `hermes` block → runtime session id + `destructive`.
    ///  2. If `destructive == true`, gate behind an explicit `LAContext`
    ///  biometric re-check (the `.authenticationRequired` action option
    ///  already forced a device unlock to even reach here; this is the
    ///  app-level Wave-2.2 amendment for dangerous actions). A failed/cancelled
    ///  gate aborts the send and posts feedback — the inbox stays authoritative.
    ///  3. `POST /api/approvals/respond` with the Keychain token + loopback Host
    ///  override (via ``RestClient``, which runs fine from this possibly
    ///  background-launched callback).
    ///  4. `resolved:false` / 404 → "Already handled elsewhere" feedback.
    ///  Transport / 401 failure → feedback + the inbox remains the source of
    ///  truth (nothing is silently dropped).
    ///

    /// Returns when the work is done so the delegate can call its completion
    /// handler — the system keeps the app alive for the action only until then.
    @MainActor
    static func handleApprovalAction(
        approve: Bool,
        action: ApprovalActionPayload
    ) async {
        // Destructive approvals (and the BINDING for dangerous actions) require an
        // explicit biometric re-check before the response is sent. Deny is also
        // gated when destructive: confirming a dangerous decision either way
        // should prove device ownership.
        if action.destructive {
            let result = await biometricAuthenticator.evaluate(
                reason: approve ? "Approve a destructive action"
                                : "Respond to a destructive action"
            )
            if case .failure = result {
                // Authentication failed/cancelled: do not send. Keep the prompt
                // actionable in-app and tell the user why nothing happened.
                postFeedbackNotification(
                    title: "Not confirmed",
                    body: "Face ID was needed to \(approve ? "approve" : "deny") this. Open Hermes to respond."
                )
                return
            }
        }

        guard let endpoint = endpointProvider?() else {
            // Not configured (no server/token yet): can't reach the gateway.
            postFeedbackNotification(
                title: "Couldn't respond",
                body: "Open Hermes to respond to this request."
            )
            return
        }

        let rest = RestClient(
            baseURL: endpoint.baseURL, token: endpoint.token, pathStyle: endpoint.pathStyle
        )
        let outcome = await rest.respondToApproval(
            sessionId: action.sessionId,
            approve: approve,
            // A single inline action answers just this request (not approve-all);
            // approve-all is an in-app affordance (handled by InboxStore).
            all: false
        )

        switch outcome {
        case .resolved:
            // Mirror the in-flight Live Activity: the turn resumes.
            LiveActivityManager.shared.clearNeedsApproval()
        case .alreadyHandled:
            postFeedbackNotification(
                title: "Already handled elsewhere",
                body: feedbackBody(for: action)
            )
        case .failed:
            postFeedbackNotification(
                title: "Couldn't respond",
                body: "The request didn't go through. Open Hermes to respond."
            )
        }
    }

    /// Body line for the "already handled" feedback, naming the target when known.
    private static func feedbackBody(for action: ApprovalActionPayload) -> String {
        if let title = action.approvalTitle, !title.isEmpty {
            return "\(title) was already resolved."
        }
        return "This request was already resolved."
    }

    /// Fire a local feedback notification for an action that couldn't land
    /// authoritatively (already handled, failed, not confirmed). No category /
    /// userInfo so a tap just opens the app.
    private static func postFeedbackNotification(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
    }

    /// Decode a tap from a notification's `userInfo`. Tolerant of both shapes:
    /// the gateway's APNs payload (`userInfo["hermes"]`) and a local
    /// notification's flat keys. Returns `nil` for payloads we don't route.
    nonisolated static func decodeTap(from userInfo: [AnyHashable: Any]) -> Tap? {
        // Prefer the namespaced `hermes` block (remote APNs), fall back to flat.
        let custom: [AnyHashable: Any]
        if let block = userInfo["hermes"] as? [AnyHashable: Any] {
            custom = block
        } else {
            custom = userInfo
        }
        guard
            let sessionId = (custom["session_id"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
            !sessionId.isEmpty
        else { return nil }

        let eventType = (custom["event_type"] as? String)?.lowercased() ?? ""
        switch eventType {
        case "approval", "clarify":
            return .attention(sessionId: sessionId)
        case "turn_complete":
            return .turnComplete(sessionId: sessionId)
        default:
            // No `event_type` (the F2-S remote payload routes by `aps.category`
            // instead of a flat event_type). Fall back to the APNs category so a
            // tapped HERMES_APPROVAL / HERMES_CLARIFY still surfaces its session
            // as "attention", and HERMES_TURN as "open the session".
            switch apsCategory(in: userInfo) {
            case remoteApprovalCategory, remoteClarifyCategory:
                return .attention(sessionId: sessionId)
            case remoteTurnCategory:
                return .turnComplete(sessionId: sessionId)
            default:
                // A session id is present but no event_type / category — treat as
                // plain "open the session" (older / local notifications).
                return .turnComplete(sessionId: sessionId)
            }
        }
    }

    /// The `aps.category` value from a notification's `userInfo`, if present.
    /// On a delivered remote notification the category also rides on
    /// `UNNotificationContent.categoryIdentifier`; this reads it straight from
    /// the raw payload so the decoder is exercisable in unit tests.
    nonisolated static func apsCategory(in userInfo: [AnyHashable: Any]) -> String? {
        (userInfo["aps"] as? [AnyHashable: Any])?["category"] as? String
    }

    // MARK: - Approval action payload (A2)

    /// The fields an `APPROVE` / `DENY` action needs, decoded from a
    /// `HERMES_APPROVAL` push's `hermes` block. Per the pinned interface the
    /// block carries `session_id` (runtime sid), `stored_session_id` (when
    /// resolvable), `destructive` (bool, default false), and `approval_title`.
    struct ApprovalActionPayload: Sendable, Equatable {
        /// Runtime session id — the target of `POST /api/approvals/respond`.
        let sessionId: String
        /// Persistent stored session id, when the push carried it.
        let storedSessionId: String?
        /// `true` when the approval marks a destructive/dangerous action: gates
        /// the action behind an explicit `LAContext` biometric re-check.
        let destructive: Bool
        /// Short target string, surfaced in the "Already handled" feedback.
        let approvalTitle: String?
    }

    /// Decode the approval-action payload from a notification's `userInfo`.
    /// Returns `nil` when there is no usable runtime `session_id`.
    nonisolated static func decodeApprovalAction(
        from userInfo: [AnyHashable: Any]
    ) -> ApprovalActionPayload? {
        guard let block = userInfo["hermes"] as? [AnyHashable: Any] else { return nil }
        guard
            let sessionId = (block["session_id"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
            !sessionId.isEmpty
        else { return nil }

        let stored = (block["stored_session_id"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let title = (block["approval_title"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return ApprovalActionPayload(
            sessionId: sessionId,
            storedSessionId: (stored?.isEmpty == false) ? stored : nil,
            // Tolerate both a real JSON bool and a "true"/"1" string, since some
            // APNs JSON paths stringify booleans.
            destructive: boolValue(block["destructive"]),
            approvalTitle: (title?.isEmpty == false) ? title : nil
        )
    }

    /// Coerce a JSON value (Bool, NSNumber, or "true"/"1" string) to a Bool.
    private nonisolated static func boolValue(_ any: Any?) -> Bool {
        if let bool = any as? Bool { return bool }
        if let number = any as? NSNumber { return number.boolValue }
        if let string = (any as? String)?.lowercased() {
            return string == "true" || string == "1" || string == "yes"
        }
        return false
    }

    /// Ask for notification authorization. Also installs the foreground-
    /// presentation delegate so notifications fired while the app is active still
    /// show a banner + play a sound.
    ///

    /// `force` distinguishes the once-per-install LAUNCH path (`false` — suppress
    /// the prompt after the first ask so we never nag on every cold start) from an
    /// EXPLICIT user action (`true` — toggling notifications ON in Settings).
    /// `requestAuthorization` only presents the system dialog when status is
    /// `.notDetermined`, so re-calling with `force` is safe: it lets a user who
    /// dismissed the first prompt ("Don't Allow"/"Ask Next Time") get it again by
    /// toggling ON (the latch previously swallowed that forever). When already
    /// `.denied`, the OS returns the denial without a prompt and Settings surfaces
    /// its "Open Settings" path.
    static func requestAuthorizationIfNeeded(force: Bool = false) {
        installDelegateIfNeeded()
        registerCategories()
        let defaults = UserDefaults.standard
        if !force {
            guard !defaults.bool(forKey: DefaultsKeys.notificationsDidRequestAuthorization) else { return }
        }
        UNUserNotificationCenter.current().requestAuthorization(
            options: [.alert, .sound, .badge]
        ) { _, _ in
            // Latch "asked once" only AFTER the dialog resolves (release
            // audit): setting it before meant an app kill mid-dialog consumed
            // the one-shot without an answer — the prompt never re-showed.
            UserDefaults.standard.set(true, forKey: DefaultsKeys.notificationsDidRequestAuthorization)
        }
    }

    // MARK: - Category registration (A1)

    private static var didRegisterCategories = false

    /// Register the actionable-push categories with the notification center.
    ///

    /// Idempotent and cheap; called from `requestAuthorizationIfNeeded()` (so the
    /// categories exist before any push lands) and again at launch via
    /// ``setActionHandler(_:)``. `setNotificationCategories` REPLACES the whole
    /// set, so we register all categories in one call.
    static func registerCategories() {
        guard !didRegisterCategories else { return }
        didRegisterCategories = true
        installDelegateIfNeeded()

        let approve = UNNotificationAction(
            identifier: approveActionIdentifier,
            title: "Approve",
            options: [.authenticationRequired]
        )
        let deny = UNNotificationAction(
            identifier: denyActionIdentifier,
            title: "Deny",
            // `.destructive` renders the button red; `.authenticationRequired`
            // forces a device unlock before the action reaches the app.
            options: [.destructive, .authenticationRequired]
        )
        let approvalCat = UNNotificationCategory(
            identifier: remoteApprovalCategory,
            actions: [approve, deny],
            intentIdentifiers: [],
            options: []
        )
        // Clarify + turn-complete are open-app only: a tap launches the app and
        // routes via `decodeTap`; no inline actions.
        let clarifyCat = UNNotificationCategory(
            identifier: remoteClarifyCategory,
            actions: [],
            intentIdentifiers: [],
            options: []
        )
        let turnCat = UNNotificationCategory(
            identifier: remoteTurnCategory,
            actions: [],
            intentIdentifiers: [],
            options: []
        )
        UNUserNotificationCenter.current().setNotificationCategories(
            [approvalCat, clarifyCat, turnCat]
        )
    }

    /// Fire a local notification for an approval request, immediately.
    ///

    /// `sessionId` (the runtime session id) is optional and, when supplied, is
    /// stamped into `userInfo` under the same flat `{event_type, session_id}`
    /// keys the remote APNs path uses (`decodeTap` reads both shapes) so a tap on
    /// a *local* notification routes to its session too.
    static func postApprovalNotification(title: String, body: String, sessionId: String? = nil) {
        post(title: title, body: body, categoryIdentifier: approvalCategory,
             eventType: "approval", sessionId: sessionId)
    }

    /// Fire a local notification for a clarification request, immediately.
    static func postClarifyNotification(question: String, sessionId: String? = nil) {
        post(
            title: "Agent needs input",
            body: question,
            categoryIdentifier: clarifyCategory,
            eventType: "clarify",
            sessionId: sessionId
        )
    }

    private static func post(
        title: String,
        body: String,
        categoryIdentifier: String,
        eventType: String? = nil,
        sessionId: String? = nil
    ) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.categoryIdentifier = categoryIdentifier
        var info: [AnyHashable: Any] = [:]
        if let eventType { info["event_type"] = eventType }
        if let sessionId, !sessionId.isEmpty { info["session_id"] = sessionId }
        if !info.isEmpty { content.userInfo = info }
        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil // deliver immediately
        )
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
    }

    // MARK: - Haptics

    /// Warning haptic — used when an approval/clarification needs attention.
    static func approvalHaptic() {
        let generator = UINotificationFeedbackGenerator()
        generator.prepare()
        generator.notificationOccurred(.warning)
    }

    /// Success haptic — used when a (long-running) turn completes.
    static func turnCompleteHaptic() {
        let generator = UINotificationFeedbackGenerator()
        generator.prepare()
        generator.notificationOccurred(.success)
    }

    // MARK: - Notification center delegate (presentation + tap routing)

    private static var didInstallDelegate = false

    private static func installDelegateIfNeeded() {
        guard !didInstallDelegate else { return }
        didInstallDelegate = true
        UNUserNotificationCenter.current().delegate = NotificationDelegate.shared
    }

    /// Notification-center delegate: presents banners while foregrounded and
    /// routes taps. Stateless (the routing state lives in `tapHandler`), so the
    /// unchecked cross-actor singleton is safe; the tap callback hops to the main
    /// actor before touching any `@MainActor` state.
    private final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
        nonisolated(unsafe) static let shared = NotificationDelegate()

        /// One-shot `@unchecked Sendable` carrier for a `UNUserNC` completion
        /// handler so it can cross into the `@MainActor` Task that runs the
        /// async action work. Apple documents these completion handlers as
        /// callable from any thread, so the crossing is sound; the box is never
        /// aliased or re-used.
        private struct CompletionBox: @unchecked Sendable {
            let handler: () -> Void
        }

        func userNotificationCenter(
            _ center: UNUserNotificationCenter,
            willPresent notification: UNNotification,
            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
        ) {
            completionHandler([.banner, .sound])
        }

        func userNotificationCenter(
            _ center: UNUserNotificationCenter,
            didReceive response: UNNotificationResponse,
            withCompletionHandler completionHandler: @escaping () -> Void
        ) {
            let userInfo = response.notification.request.content.userInfo
            let actionId = response.actionIdentifier

            // Inline APPROVE / DENY actions (A2): resolve against the gateway,
            // then call the completion handler when done so the system keeps the
            // (possibly background-launched) process alive for the network call.
            // `userInfo` is non-Sendable; `decodeApprovalAction` / the whole
            // handler run on the main actor, so we snapshot the two Sendable bits
            // (the choice + a Sendable copy of the payload) before hopping.
            if let approve = NotificationService.approveChoice(for: actionId) {
                // Decode here (pure transform; no actor crossing) to a Sendable
                // payload, then hand only that across the boundary. The
                // `completionHandler` is not `Sendable`-annotated, but UNUserNC
                // documents it as callable from any thread, so it rides into the
                // `@MainActor` Task through a one-shot transfer box (mirrors the
                // `ActivityBox` pattern used for non-Sendable handoffs elsewhere).
                let action = NotificationService.decodeApprovalAction(from: userInfo)
                let completion = CompletionBox(handler: completionHandler)
                Task { @MainActor in
                    if let action {
                        await NotificationService.handleApprovalAction(
                            approve: approve,
                            action: action
                        )
                    } else {
                        // Malformed/older-server payload (no `hermes` block or
                        // empty session id): every OTHER failure on this path
                        // posts feedback — silence here meant the user "denied"
                        // and nothing happened.
                        NotificationService.postFeedbackNotification(
                            title: "Couldn't respond",
                            body: "Open Hermes to respond to this request."
                        )
                    }
                    completion.handler()
                }
                return
            }

            // Only the default action (a tap on the notification body) navigates;
            // dismiss / unknown actions are not routed.
            guard actionId == UNNotificationDefaultActionIdentifier else {
                completionHandler()
                return
            }
            // Decode synchronously on this callback's thread: `decodeTap` is a
            // pure transform over the non-Sendable `userInfo` dictionary, so it
            // never crosses an actor boundary. Only the resulting Sendable `Tap`
            // is sent to the main actor, and the completion handler fires now —
            // both avoid the Swift 6 "sending risks a data race" diagnostics.
            let tap = NotificationService.decodeTap(from: userInfo)
            completionHandler()
            guard let tap else { return }
            Task { @MainActor in
                NotificationService.tapHandler?(tap)
            }
        }
    }
}
