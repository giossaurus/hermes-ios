import SwiftUI
#if canImport(UIKit)
import UIKit  // UIDevice.current.name — the auto-upgrade device-name hint (W3A-A)
#endif
#if DEBUG
import DebugBridgeCore  // @Snapshotable marker for the gstack debug bridge (UI-G)
#endif

/// A model pick made on a DRAFT chat (no gateway session yet) — pends until
/// the draft materializes, then applies session-scoped.
/// `reasoningEffort`/`fast` are nil when untouched (the session then keeps
/// the global defaults).
struct DraftModelSelection: Equatable, Sendable {
    var model: String
    var provider: String
    var reasoningEffort: String?
    var fast: Bool?
}

/// Observable owner of the gateway connection lifecycle.
///

/// Drives configuration/persistence, fans gateway events out to `SessionStore`
/// and `ChatStore`, mirrors the transport's connection state into a UI-facing
/// `Phase`, and runs the reconnect loop (exponential backoff with jitter). One
/// instance lives for the lifetime of the app; it holds the single
/// `HermesGatewayClient` whose long-lived streams it consumes.
@MainActor
@Observable
final class ConnectionStore {
    /// UI-facing connection lifecycle.
    enum Phase: Equatable {
        case needsSetup
        case connecting
        /// A verified connection whose gateway state (session list + running
        /// model) is still being hydrated. Drives the branded loading screen
        /// so the user sees a brand moment rather than a flash of an
        /// empty shell. ALWAYS transient: a hard `hydrationTimeout` fallback
        /// flips it to `.connected` even if the post-connect probes are slow, so
        /// the loading screen can never strand.
        case hydrating
        case connected
        case reconnecting(attempt: Int)
        case offline(String?)
    }

    /// Current high-level connection phase.
    var phase: Phase = .connecting
    #if DEBUG
    /// JSON-safe mirror of ``phase`` for the gstack debug bridge snapshot
    /// (task UI-G). `phase` is a Swift enum and not JSON-serializable, so the
    /// generated StateServer accessor reads this stable String label instead.
    /// Wrapped in `#if DEBUG` so it does not exist in Release.
    @Snapshotable var phaseLabel: String {
        switch phase {
        case .needsSetup: return "needsSetup"
        case .connecting: return "connecting"
        case .hydrating: return "hydrating"
        case .connected: return "connected"
        case .reconnecting(let attempt): return "reconnecting(\(attempt))"
        case .offline(let reason): return "offline(\(reason ?? ""))"
        }
    }
    #endif
    /// The server base URL string (persisted in UserDefaults).
    #if DEBUG
    @Snapshotable
    #endif
    var serverURLString: String = ""

    /// Set when a *configured* connection is rejected for authentication
    /// (HTTP 401/403 on the REST probe, or the WS handshake is rejected for auth
    /// repeatedly). The shell reads this alongside `.needsSetup` to route to
    /// ``WelcomeView`` with a "your pairing was revoked — scan a new code" banner
    /// instead of spinning in an endless reconnect. Cleared on a successful
    /// `configure` and on `disconnect`. (D3 RE-PAIR FLOW.)
    var reauthRequired = false

    /// Short display name of the gateway's currently-configured main model
    /// (F0 / Amendment B). Sourced from `GET /api/model/info` on connect and
    /// re-fetched after a model switch. `nil` until the first successful probe
    /// (or when the server reports no model) — the header/composer model chip
    /// renders only when this is non-nil. Provider prefixes and trailing date
    /// stamps are stripped (see ``shortModelName(provider:model:)``) so the chip
    /// shows e.g. "claude-opus-4" rather than "anthropic/claude-opus-4-20250514".
    var activeModelName: String?

    // MARK: - Active session hot-swap state
    //

    // These track the LIVE session's model/reasoning/fast as reported by the
    // gateway's `session.info` events (emitted after a `config.set` hot-swap).
    // They are nil when no session is active or no info has arrived yet.
    // The session popup reads these to show current state; the global defaults
    // are separate (Settings → ModelPickerView → POST /api/model/set).

    /// The live session's model id as reported by the last `session.info`.
    /// Distinct from `activeModelName`: this is the per-session override after a
    /// hot-swap; `activeModelName` remains the GLOBAL default (new-session model).
    var sessionModel: String?

    /// The live session's RAW model id (un-shortened) from `session.info`.
    /// The picker needs the raw id for exact row matching; `sessionModel`
    /// stays shortened for the composer chip display.
    var sessionModelRaw: String?

    /// The live session's provider slug from `session.info` (gateways that
    /// predate the field never set it; the picker then falls back to the
    /// session-scoped `model.options` current). Selection identity is
    /// (provider, model) — the model name alone is ambiguous when two
    /// providers offer the same model.
    var sessionProvider: String?

    /// The live session's reasoning effort level
    /// ("minimal"/"low"/"medium"/"high"/"xhigh"/"none"/"") from `session.info`.
    var sessionReasoningEffort: String?

    /// True when the live session is in fast mode (service_tier == "priority").
    var sessionFast: Bool?

    // MARK: Draft-mode model pick

    /// The model pick is allowed at ANY point — including a DRAFT chat that has
    /// no gateway session yet. The pick pends here and is applied to the session
    /// the moment the draft materializes (`SessionStore.createDraftSession`),
    /// BEFORE the first prompt is submitted — `config.set key=model` builds the
    /// session agent, so even the FIRST turn runs on the chosen model.
    var draftSelection: DraftModelSelection?

    /// Shortened display name of the pended draft pick (composer chip).
    var draftModelShortName: String? {
        guard let d = draftSelection, !d.model.isEmpty else { return nil }
        return Self.shortModelName(provider: d.provider, model: d.model)
    }

    /// Forget a pended draft pick (fresh draft, opening an existing chat).
    func clearDraftSelection() {
        draftSelection = nil
    }

    /// Apply a pended draft pick to the just-created session. Best-effort BY
    /// DESIGN: a failure must not block (or lose) the user's first message —
    /// the session then simply runs on the global default and the pill follows
    /// the server truth from `session.info`.
    func applyDraftSelection(sessionId: String) async {
        guard let d = draftSelection else { return }
        draftSelection = nil
        if !d.model.isEmpty {
            let value = d.provider.isEmpty ? d.model : "\(d.model) --provider \(d.provider)"
            try? await sessionSetModel(value, sessionId: sessionId)
        }
        if let effort = d.reasoningEffort {
            try? await sessionSetReasoning(effort.isEmpty ? "none" : effort, sessionId: sessionId)
        }
        if let fast = d.fast {
            try? await sessionSetFast(fast, sessionId: sessionId)
        }
    }

    /// Apply the typed `info` echoed by `session.create`/`session.resume` to
    /// the live session state. THIS is what keeps the composer pill session-
    /// true on every switch: the gateway sends the session's actual
    /// model/provider/reasoning/fast on resume, but the app previously used
    /// it only for profile confirmation — so the pill kept showing the LAST
    /// session's hot-swap (or the global default) until the picker was opened
    /// (build-27 QA).
    func applyRuntimeInfo(_ info: SessionRuntimeInfo) {
        if let model = info.model, !model.isEmpty {
            sessionModel = Self.shortModelName(provider: nil, model: model)
            sessionModelRaw = model
        }
        if let provider = info.provider, !provider.isEmpty {
            sessionProvider = provider
        }
        if let effort = info.reasoningEffort {
            sessionReasoningEffort = effort
        }
        if let fast = info.fast {
            sessionFast = fast
        }
    }

    /// Apply a `session.info` payload from the gateway to the live session state
    /// properties. Called from the event router on `.sessionInfo` events.
    func applySessionInfo(_ payload: JSONValue) {
        // Only update when the event belongs to the active runtime session.
        // The payload is the `_session_info()` dict from server.py.
        if let model = payload["model"]?.stringValue, !model.isEmpty {
            sessionModel = Self.shortModelName(provider: nil, model: model)
            sessionModelRaw = model
        }
        if let provider = payload["provider"]?.stringValue, !provider.isEmpty {
            sessionProvider = provider
        }
        if let effort = payload["reasoning_effort"]?.stringValue {
            sessionReasoningEffort = effort
        }
        if let fast = payload["fast"]?.boolValue {
            sessionFast = fast
        }
    }

    /// Reset active session hot-swap state when a session is torn down or
    /// the connection drops so a fresh session starts clean.
    func clearSessionState() {
        sessionModel = nil
        sessionModelRaw = nil
        sessionProvider = nil
        sessionReasoningEffort = nil
        sessionFast = nil
        draftSelection = nil
    }

    // MARK: - WS config.set helpers

    /// Session-scoped `model.options`: the gateway layers the LIVE session
    /// agent's provider/model on top of disk config, so `currentModel` /
    /// `currentProvider` reflect this session's hot-swap state — not the
    /// global default the REST endpoint reports. Mirrors the desktop, which
    /// calls WS `model.options` with `session_id` for its session dropdown.
    func sessionModelOptions(sessionId: String) async throws -> ModelOptions {
        let result = try await client.requestRaw(
            "model.options",
            params: .object(["session_id": .string(sessionId)]),
            timeout: .seconds(30)
        )
        return ModelOptions(json: result)
    }

    /// Send `config.set` with `key="model"` and the active `session_id` so the
    /// model switch is scoped to the live session only (not global).
    func sessionSetModel(_ model: String, sessionId: String) async throws {
        _ = try await client.requestRaw(
            "config.set",
            params: .object([
                "key": .string("model"),
                "value": .string(model),
                "session_id": .string(sessionId),
            ]),
            timeout: .seconds(30)
        )
    }

    /// Send `config.set` with `key="reasoning"` scoped to the live session.
    /// Pass an effort string from `VALID_REASONING_EFFORTS` ("none" to disable).
    func sessionSetReasoning(_ effort: String, sessionId: String) async throws {
        _ = try await client.requestRaw(
            "config.set",
            params: .object([
                "key": .string("reasoning"),
                "value": .string(effort),
                "session_id": .string(sessionId),
            ]),
            timeout: .seconds(30)
        )
    }

    /// Send `config.set` with `key="fast"` scoped to the live session.
    func sessionSetFast(_ enabled: Bool, sessionId: String) async throws {
        _ = try await client.requestRaw(
            "config.set",
            params: .object([
                "key": .string("fast"),
                "value": .string(enabled ? "fast" : "normal"),
                "session_id": .string(sessionId),
            ]),
            timeout: .seconds(30)
        )
    }

    /// Send `config.set` for the GLOBAL default reasoning effort (no session_id).
    func globalSetReasoning(_ effort: String) async throws {
        _ = try await client.requestRaw(
            "config.set",
            params: .object([
                "key": .string("reasoning"),
                "value": .string(effort),
            ]),
            timeout: .seconds(30)
        )
    }

    /// Send `config.set` for the GLOBAL default fast mode (no session_id).
    func globalSetFast(_ enabled: Bool) async throws {
        _ = try await client.requestRaw(
            "config.set",
            params: .object([
                "key": .string("fast"),
                "value": .string(enabled ? "fast" : "normal"),
            ]),
            timeout: .seconds(30)
        )
    }

    /// Number of consecutive auth-rejection probes seen by the reconnect loop.
    /// Used so a single transient 401 (e.g. a token-rotation race on the host)
    /// doesn't immediately bounce a live session to re-pair; we only flip after
    /// the failure is confirmed on the dedicated re-probe.
    private var consecutiveReconnectFailures = 0
    /// After this many consecutive WS reconnect failures, the loop re-probes REST
    /// to distinguish an auth revocation (→ re-pair) from plain unreachability
    /// (→ keep retrying).
    private static let authReprobeThreshold = 3

    /// Hard ceiling on the branded `.hydrating` loading screen. The
    /// post-connect hydration (session-list refresh + running-model probe) races
    /// against this timeout; whichever finishes first flips the phase to
    /// `.connected`, so a slow or hung probe can NEVER strand the user on the
    /// loading screen. Kept as a named constant so the test can pin it.
    static let hydrationTimeout: Duration = .seconds(8)

    /// The single, long-lived gateway client.
    let client = HermesGatewayClient()

    /// Which branch-only server features the connected gateway supports (E1).
    /// Probed after a successful configure/connect; views gate on it so one
    /// binary degrades gracefully against a stock hermes-agent. Owned here so the
    /// app has a single instance to read and (via the router) feed passive
    /// signals into.
    let capabilities = ServerCapabilities()

    /// A REST client built from the saved URL + token, or `nil` if unconfigured.
    /// Speaks the path family the capability probe resolved — `.legacy`
    /// until/unless the plugin-mount probe concludes `.available`.
    var rest: RestClient? {
        guard let url = URL(string: serverURLString), let token = currentToken else { return nil }
        return RestClient(
            baseURL: url, token: token, pathStyle: capabilities.resolvedPathStyle
        )
    }

    /// A ``RestClient`` for the control-surface panels (model / personality /
    /// usage / cron / skills — now ``RestClient`` extension members), built from
    /// the same saved URL + token as `rest`, or `nil` if unconfigured.
    var control: RestClient? {
        guard let url = URL(string: serverURLString), let token = currentToken else { return nil }
        return RestClient(
            baseURL: url, token: token, pathStyle: capabilities.resolvedPathStyle
        )
    }

    /// The persistent prompt outbox/queue. Drained here after reconnect backfill.
    /// Wired by `AppEnvironment` (ChatStore holds no reference to it).
    weak var queueStore: QueueStore?

    /// The global approval/clarification inbox. The event router fans the
    /// broadcast prompt events to it (in addition to `ChatStore`) so pending
    /// requests from every session collect in one place. Wired by
    /// `AppEnvironment`; `ChatStore` holds no reference to it.
    weak var inboxStore: InboxStore?

    private let sessionStore: SessionStore
    private let chatStore: ChatStore

    /// The token for the active connection (kept in memory; also in Keychain).
    private var currentToken: String?

    /// Tasks that live as long as the client: the event router and the
    /// state-change observer. Started once on the first successful configure.
    private var eventRouterTask: Task<Void, Never>?
    private var stateObserverTask: Task<Void, Never>?
    /// Pending coalesced session-list refresh (item 1). Cancelled and
    /// replaced whenever a new message.start / message.complete arrives during
    /// the debounce window; only the trailing edge fires the actual `refresh()`.
    /// Both the event-router path (streaming frames) and the foreground path
    /// (`handleScenePhase`) share this single task slot so concurrent triggers
    /// collapse to one fetch rather than piling up.
    private var sessionRefreshDebounceTask: Task<Void, Never>?
    /// Debounce interval for the coalesced session refresh (item 1).
    private static let sessionRefreshDebounceMs: Int = 400
    /// FIX 5 — WS intake yield budget. The event router drains an UNBOUNDED stream
    /// on the main actor; a queued frame burst (a long agentic turn, a reconnect
    /// backfill colliding with a live stream) would otherwise hold the main actor
    /// back-to-back with NO runloop turn between frames, freezing UIKit for the
    /// burst's duration. After each `route()` returns, the loop yields the main actor
    /// once a contiguous wall-clock budget is exceeded OR every `intakeYieldEveryK`
    /// frames — converting one long hold into many short ones BY CONSTRUCTION (a yield
    /// point, not timing luck), giving UIKit a runloop turn mid-burst. The stream stays
    /// UNBOUNDED (lossless — no frame is dropped); only the HOLD is capped.
    private static let intakeYieldBudget: Duration = .milliseconds(8)
    /// Hard frame-count ceiling between yields, as a floor under the wall-clock budget
    /// (so a run of cheap frames still yields periodically even if it never crosses the
    /// time budget). Bursts of expensive frames cross the time budget first.
    private static let intakeYieldEveryK = 32
    /// The in-flight reconnect loop, if any.
    private var reconnectTask: Task<Void, Never>?
    /// The in-flight post-connect hydration coordinator, if any. Owns
    /// the `.hydrating → .connected` transition and the timeout fallback;
    /// cancelled on disconnect so a teardown mid-hydration can't later flip the
    /// phase back to `.connected`.
    private var hydrationTask: Task<Void, Never>?
    /// Whether the session-list `refresh()` kicked off in ``startHydration`` actually
    /// COMPLETED, vs being cancelled by the hard-`hydrationTimeout` race. For a large
    /// account the list pull (hundreds/thousands of sessions) reliably loses the 8s
    /// race, so the refresh is cancelled and the drawer is left on STALE cache even
    /// though the phase flips to `.connected` (reported: cold-launch sessions stuck at
    /// an old timestamp, new messages not visible). ``finishHydration`` re-fires the
    /// refresh in the background when this is false — the same safety net the running-
    /// model probe already has.
    private var hydrationRefreshCompleted = false
    /// True once a connection has been established at least once, so that a
    /// later `.closed`/`.failed` should trigger reconnection rather than be
    /// treated as a clean initial idle state.
    ///

    /// ALSO the routing discriminator the shell needs: a
    /// `.connecting`/`.offline` phase means very different things before vs.
    /// after a verified connection. BEFORE — a manual/QR `configure` that failed
    /// validation (bad URL, unreachable host, transport error). The user must
    /// stay in onboarding with the inline error, NOT be dropped into the chat
    /// shell. AFTER — a live session that dropped → the shell with an offline
    /// banner + reconnect loop. `RootView` reads this so an invalid credential
    /// can never ride a non-`.needsSetup` failure phase into the main UI.
    /// `private(set)` so the view can read it but only the store mutates it.
    private(set) var hasConnected = false

    /// True only while the launch `bootstrap()` is resolving a SAVED config
    /// (UserDefaults URL + Keychain token, or the dev-env override). During this
    /// window `hasConnected` is still `false` (the reconnect hasn't completed)
    /// yet the user is a RETURNING user, not someone in first-run setup — so the
    /// shell should show the launch splash (chat shell + offline/connecting
    /// banner) rather than flashing `WelcomeView`. Set around the saved-config
    /// `configure` call in `bootstrap()` and cleared when it returns. A first-run
    /// launch (no saved config) never sets this, so it falls straight through to
    /// `.needsSetup` → `WelcomeView`.
    private(set) var isBootstrapping = false

    /// True when this install has a SAVED connection configuration — a previously-
    /// paired user. Read by `RootView` so the CACHE-FIRST shell (WhatsApp bar)
    /// renders for a paired user in `.offline`/`.connecting`/`.reconnecting` even
    /// after `isBootstrapping` has cleared (the cold-launch-offline window the old
    /// `hasConnected || isBootstrapping` gate dropped to `WelcomeView`).
    ///

    /// The signal is the persisted server URL: `configure()` writes it to
    /// UserDefaults ONLY after a verified connection, so a genuinely-unconfigured
    /// install (or one whose only `configure` attempt FAILED validation — nothing
    /// persisted) reports `false` and still routes to `WelcomeView`. The in-memory
    /// `serverURLString` is the cache-first early-set fallback (set in
    /// `paintCacheFirst` before any persistence) so the gate holds during the very
    /// first launch frames too. A deliberate `disconnect()` clears the persisted
    /// URL elsewhere? — no: `disconnect()` returns to `.needsSetup`, which routes
    /// to `WelcomeView` directly, so this gate is never consulted there.
    var hasSavedConfiguration: Bool {
        if let saved = UserDefaults.standard.string(forKey: DefaultsKeys.serverURL),
           !saved.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return true
        }
        // Cache-first early-set (pre-persistence) fallback — set by
        // `paintCacheFirst` from the saved/dev-env URL before `configure()`
        // persists. A failed `configure()` never reaches this set with a value
        // that outlives the launch (it returns early before any non-bootstrap
        // path), so a garbage manual entry does not spuriously flip the gate.
        return !serverURLString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    init(sessionStore: SessionStore, chatStore: ChatStore) {
        self.sessionStore = sessionStore
        self.chatStore = chatStore
    }

    // MARK: - Bootstrap

    /// Resolve the connection at launch: dev env override → saved config →
    /// `.needsSetup`.
    func bootstrap() async {
        #if DEBUG
        // Dev-only override (sim/test runs inject HERMES_URL/HERMES_TOKEN via
        // SIMCTL_CHILD_/TEST_RUNNER_). DEBUG-gated so a production binary can
        // never be silently re-pointed via injected env vars (release audit).
        let env = ProcessInfo.processInfo.environment
        if let url = env["HERMES_URL"], let token = env["HERMES_TOKEN"],
           !url.isEmpty, !token.isEmpty {
            // A saved/dev-env config: this is a RETURNING user. Flag the launch
            // window so the shell shows the splash rather than `WelcomeView` even
            // while the reconnect is still in flight.
            isBootstrapping = true
            // CACHE-FIRST (WhatsApp bar): bind the cache scope to this server and
            // paint the drawer from disk BEFORE the REST probe, so the session
            // list renders instantly regardless of whether the probe succeeds,
            // fails, or hangs. `serverURLString` is what `currentCacheScope`
            // resolves from, so it must be set before the paint — the later
            // `configure()` re-stamps it (trimmed) verbatim on a verified connect.
            await paintCacheFirst(serverURLString: url)
            _ = await configure(urlString: url, token: token)
            isBootstrapping = false
            return
        }
        #endif

        let savedURL = UserDefaults.standard.string(forKey: DefaultsKeys.serverURL)
        if let savedURL, !savedURL.isEmpty,
           let token = KeychainService.loadToken(server: savedURL) {
            isBootstrapping = true
            // CACHE-FIRST (WhatsApp bar): paint the drawer from disk BEFORE the
            // REST probe — this is the fix for the empty-drawer / Welcome-on-
            // offline cold start. The probe's early-return offline path no longer
            // strands an empty drawer because the cache read already ran here.
            await paintCacheFirst(serverURLString: savedURL)
            _ = await configure(urlString: savedURL, token: token)
            isBootstrapping = false
            return
        }

        phase = .needsSetup
    }

    /// Bind the session cache scope to `serverURLString` and paint the drawer from
    /// the local cache (WhatsApp bar — cache-first launch).
    ///

    /// `serverURLString` drives `SessionStore.currentCacheScope`; it is set HERE
    /// (trimmed, matching the Keychain/cache identity) so the cold read partitions
    /// correctly before any network call. `configure()` re-stamps the SAME trimmed
    /// value on a verified connection, so this early set is consistent with the
    /// post-connect state and is harmless if the connection later fails (the saved
    /// URL is the one the cache was written under). The paint itself is idempotent
    /// (`didColdReadCache`-latched), so the `refresh()` inside hydration collapses
    /// onto this same read rather than doing a second one.
    private func paintCacheFirst(serverURLString url: String) async {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        // Only the cache-scope identity is set here — NOT the persisted credential
        // (configure() still owns persistence after a verified connect).
        self.serverURLString = trimmed
        await sessionStore.paintFromCache()
    }

    // MARK: - Configure

    /// Validate, probe, persist, and connect to a gateway.
    ///

    /// Returns `nil` on success; otherwise a human-readable error string (and
    /// leaves `phase` reflecting the failure). On success the URL/token are
    /// persisted (UserDefaults + Keychain), the socket is connected, and the
    /// event/state tasks are started.
    ///

    /// - Parameter issuedDeviceId: the server-minted `device_id` when this pairing
    ///  came from a W3a v2 QR (`kind=device`) — `token` is then ALREADY a device
    ///  token, so we record the id and SKIP auto-upgrade. `nil` for a v1 (shared)
    ///  pairing, a manual token entry, or a saved-config bootstrap, where the
    ///  post-connect auto-upgrade transparently swaps the shared token for a
    ///  device token if the server advertises the `devices` capability.
    func configure(urlString: String, token: String, issuedDeviceId: String? = nil) async -> String? {
        let trimmedURL = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)

        // Scheme is restricted to http/https — `URL(string:)` happily accepts
        // `file:`, `javascript:`, `ftp:` etc., and a malformed QR code or a
        // typo'd manual entry must not reach the REST probe (release audit).
        guard let url = URL(string: trimmedURL),
              let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              url.host != nil else {
            phase = .offline("Invalid server URL")
            return "That doesn't look like a valid server URL."
        }
        guard !trimmedToken.isEmpty else {
            phase = .offline("Missing token")
            return "A session token is required."
        }

        // Cancel any reconnect loop tied to a previous configuration.
        reconnectTask?.cancel()
        reconnectTask = nil

        // Reset the initial-fill guard so the next refresh() after this
        // configure re-runs the fill-to-30 loop for the new server.
        sessionStore.resetInitialFill()

        phase = .connecting

        // Probe REST first to fail fast with a clear message before opening WS.
        let probe = RestClient(baseURL: url, token: trimmedToken)
        do {
            _ = try await probe.status()
        } catch {
            // An auth rejection on a probe means this token is no longer valid —
            // surface the re-pair affordance rather than a generic offline error
            // (D3 RE-PAIR FLOW). This covers both an explicit re-auth attempt and
            // a bootstrap of a now-revoked saved token.
            if Self.isAuthFailure(error) {
                reauthRequired = true
                phase = .needsSetup
                return Self.reauthMessage
            }
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            phase = .offline(message)
            return message
        }

        do {
            try await client.connect(baseURL: url, token: trimmedToken)
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            phase = .offline(message)
            return message
        }

        // Persist only after a verified connection.
        serverURLString = trimmedURL
        currentToken = trimmedToken
        UserDefaults.standard.set(trimmedURL, forKey: DefaultsKeys.serverURL)
        try? KeychainService.saveToken(trimmedToken, server: trimmedURL)

        // W3A-A QR v2: a `kind=device` pairing handed us a device token + its
        // server-minted `device_id`. Record the (non-secret) id so the panel can
        // mark "This device" and the auto-upgrade path sees this device already
        // holds a device token (so it does NOT re-issue). The token is already in
        // the Keychain above (it IS the stored credential). A v1/manual pairing
        // passes `nil` here, so any stale id for this server is cleared and the
        // post-connect auto-upgrade is free to issue a fresh device token.
        DefaultsKeys.setDeviceId(issuedDeviceId, server: trimmedURL)

        startLongLivedTasks()
        hasConnected = true
        // A verified connection clears any prior re-pair flag and failure tally.
        reauthRequired = false
        consecutiveReconnectFailures = 0
        // enter the branded loading screen rather than flashing the empty
        // shell. The hydration coordinator below flips this to `.connected` once
        // the gateway state has been pulled (or the timeout fires first).
        phase = .hydrating

        // Probe branch-only server capabilities (E1) so the UI can gate on a
        // stock vs. patched gateway. Cheap + cached per server URL + app version,
        // so a reconnect to the same server is a no-op. Fire-and-forget: the UI
        // shows features optimistically until a probe proves one unavailable.
        // NOT part of the hydration gate — it never blocks the loading screen.
        Task { [weak self] in
            guard let self, let rest = self.rest else { return }
            await self.capabilities.probe(serverURL: trimmedURL, rest: rest)
            // F4b: once the `profiles` capability has settled, load the profile
            // list backing the switcher (a no-op clearing the cache on a stock
            // gateway). Gated inside `loadProfiles()` on `profiles == .available`.
            await self.sessionStore.loadProfiles()
            // W3A-A: once the `devices` capability has settled, transparently
            // auto-upgrade a legacy shared token to a per-device token (a no-op on
            // a stock gateway, where `devices` is `.unavailable`, and on a device
            // that already holds a device token for this server). Runs AFTER the
            // probe so it sees the settled capability.
            await self.autoUpgradeToDeviceTokenIfNeeded(serverURL: trimmedURL)
        }

        // coordinate the `.hydrating → .connected` transition. The
        // user-visible hydration is the session-list refresh + the running-model
        // probe; both are raced against `hydrationTimeout` so a slow or hung
        // probe can never strand the loading screen. On completion (whichever
        // wins) we land on a fresh new-chat draft and reveal the connected UI.
        startHydration()
        return nil
    }

    // MARK: - Hydration

    /// Coordinate the post-connect `.hydrating → .connected` transition.
    ///

    /// Races the real gateway-state hydration (session-list refresh + running-
    /// model probe) against a hard `hydrationTimeout`: whichever finishes first
    /// flips the phase to `.connected` and lands on a fresh new-chat draft, so
    /// the branded loading screen NEVER strands even if a probe is slow or hangs.
    /// Idempotent in effect — `finishHydration()` only acts while still
    /// `.hydrating`, so the losing branch of the race is a no-op.
    /// The hydration session-list refresh, wrapped so its COMPLETION (vs being
    /// cancelled by the timeout race) is recorded on the main actor. `refresh()`
    /// returns early on cancellation, so `Task.isCancelled` distinguishes a real
    /// completion from a cancelled one; `finishHydration` re-fires the refresh in
    /// the background when this never set the flag.
    private func runHydrationRefresh() async {
        await sessionStore.refresh()
        if !Task.isCancelled { hydrationRefreshCompleted = true }
    }

    private func startHydration() {
        hydrationTask?.cancel()
        hydrationRefreshCompleted = false
        hydrationTask = Task { [weak self] in
            guard let self else { return }
            await withTaskGroup(of: Void.self) { group in
                // Branch 1: the real hydration — pull the session list (so the
                // drawer is populated when the shell reveals) AND resolve the
                // running model (so the composer chip can render immediately).
                // The two run CONCURRENTLY with each other via `async let`, not
                // chained: with hundreds of sessions the list pull can eat the
                // whole hydration budget, and sequencing the probe behind it meant
                // a slow first connect let the timeout branch win and cancel the
                // group before the probe ran — so the composer chip stayed empty
                // until a force-quit warmed the cache. Awaiting both here keeps
                // the outer race intact (this branch finishes only when BOTH are
                // done) while letting the chip resolve in parallel.
                group.addTask { [weak self] in
                    guard let self else { return }
                    async let sessions: Void = self.runHydrationRefresh()
                    async let model: Void = self.refreshActiveModel()
                    _ = await (sessions, model)
                }
                // Branch 2: the hard timeout fallback. Proceeds to `.connected`
                // even if hydration is slow — the loading screen must not strand.
                group.addTask {
                    try? await Task.sleep(for: Self.hydrationTimeout)
                }
                // The first branch to finish wins; cancel the rest so a pending
                // sleep (or a slow refresh after the timeout) does nothing more.
                _ = await group.next()
                group.cancelAll()
            }
            if Task.isCancelled { return }
            self.finishHydration()
        }
    }

    /// Complete hydration: reveal the connected UI on a fresh new-chat draft.
    /// Guarded on the phase so a late timeout branch (or a re-entrant call)
    /// after a disconnect/re-configure is a harmless no-op.
    ///

    /// `internal` (not `private`) so the phase-transition unit tests can drive it
    /// directly without standing up a live gateway — both race branches converge
    /// here, so pinning its guard + side effects is the seam that proves the
    /// timeout fallback lands on `.connected` + a fresh draft.
    func finishHydration() {
        guard phase == .hydrating else { return }
        // Land on a fresh draft chat (chat-as-home), but only when nothing is
        // already active — a manual re-configure while a session is open must not
        // stomp it.
        if sessionStore.activeStoredId == nil {
            sessionStore.startDraft()
        }
        phase = .connected
        // Safety net: if the hydration race was won by the hard timeout branch,
        // branch 1's model probe was cancelled mid-flight and the composer chip
        // would render empty. Re-run the probe (best-effort, off the reveal path)
        // whenever the model is still unresolved so the chip fills in shortly
        // after connect instead of staying blank until a force-quit.
        if activeModelName == nil {
            Task { [weak self] in await self?.refreshActiveModel() }
        }
        // STALE-DRAWER FIX: the hydration race cancels the session-list `refresh()`
        // when the 8s timeout branch wins — which it reliably does for a large account
        // (the list pull eats the whole budget). Without recovery the drawer stays on
        // STALE cache while the UI shows "connected" (reported: cold-launch sessions
        // stuck at an old timestamp; new messages not visible until a manual pull).
        // The model probe above already has this exact safety net; give the session
        // list one too — re-run the refresh in the BACKGROUND (off the reveal path,
        // phase is already `.connected`) so the drawer reconciles to the gateway's
        // fresh state shortly after connect. Opening a session then fetches its fresh
        // transcript on its own (the delta route falls back to a full resync).
        if !hydrationRefreshCompleted {
            Task { [weak self] in await self?.sessionStore.refresh() }
        }
        // CACHE-FIRST coverage (WhatsApp bar): hydration has settled and the
        // session list is populated — warm the top-N recent transcripts in the
        // background so nearly every subsequent drawer tap is a disk hit. Paced +
        // cancellable; a no-op when offline (no REST client) or on a cold cache.
        sessionStore.prefetchRecentTranscripts()
        // Hygiene (WhatsApp bar): run the daily-throttled eviction sweep so the
        // cache never grows unbounded. Self-throttled to once/24h in CacheStore.
        sessionStore.runEvictionIfNeeded()
        // Recover any pending approval/clarify already waiting on the server at
        // first connect (e.g. a Telegram-driven prompt raised before the app
        // opened) — same catch-up the reconnect path runs.
        catchUpPendingPrompts()
    }

    // MARK: - Disconnect

    /// Tear down the connection, returning to `.needsSetup`.
    ///

    /// The event-router and state-observer tasks are deliberately NOT cancelled
    /// `HermesGatewayClient.events`/`.stateChanges` are SINGLE-CONSUMER
    /// AsyncStreams that survive reconnects by design — cancelling their
    /// consumer terminates the stream, so the `for await` a later `configure()`
    /// restarted iterated a dead (or, racing the old task's exit, doubly-claimed)
    /// stream: every event after a disconnect→reconnect cycle was silently
    /// dropped, or the second `next()` trapped. The tasks idle at their
    /// suspension points while disconnected and cost nothing.
    func disconnect() async {
        reconnectTask?.cancel()
        reconnectTask = nil
        // Cancel any in-flight hydration so a teardown mid-load can't later flip
        // the phase back to `.connected`.
        hydrationTask?.cancel()
        hydrationTask = nil
        hasConnected = false
        // A deliberate disconnect is not an auth revocation — clear the re-pair
        // flag so the welcome screen shows its normal first-run copy.
        reauthRequired = false
        consecutiveReconnectFailures = 0
        // Drop live capability state (the cached snapshot is retained so a
        // reconnect to the same server reuses it — see ServerCapabilities).
        capabilities.reset()
        // Forget the resolved model so a fresh connection re-probes it (F0).
        activeModelName = nil
        // Clear the per-session hot-swap state so the next session starts clean.
        clearSessionState()
        // CACHE-FIRST coverage (WhatsApp bar): stop any paced background prefetch
        // so it never outlives the connection it ran under.
        sessionStore.cancelPrefetch()
        // Finalize any in-flight stream explicitly and SYNCHRONOUSLY (R1
        // #9/#42), before the teardown await opens a suspension window. The
        // live state observer will also see the `.closed` transition below and
        // re-run this — harmless, `handleConnectionDrop` is idempotent — and
        // its reconnect guard stays quiet because `hasConnected` was cleared
        // above, BEFORE the close.
        chatStore.handleConnectionDrop()
        await client.disconnect()
        phase = .needsSetup
    }

    // MARK: - Long-lived tasks

    /// Start the event router and state observer once. Idempotent.
    private func startLongLivedTasks() {
        if eventRouterTask == nil {
            eventRouterTask = Task { [weak self] in
                guard let self else { return }
                // FIX 5 — bound the main-actor HOLD, not the buffer. Track the start
                // of the current contiguous (un-yielded) drain and the frames since
                // the last yield. The `for await` only suspends on its own when the
                // buffer is EMPTY; for a queued burst we add an explicit yield once a
                // wall-clock budget OR a frame count is exceeded, so UIKit gets a
                // runloop turn mid-burst. Yielding ONLY AFTER `route()` returns means
                // no event is ever half-applied — an interleaved session switch is
                // already made safe by the openToken / streamingIsForeign ownership
                // gates. Lossless: every frame is still routed in order.
                var holdStart = ContinuousClock.now
                var sinceYield = 0
                for await event in self.client.events {
                    self.route(event: event)
                    sinceYield += 1
                    if sinceYield >= Self.intakeYieldEveryK
                        || ContinuousClock.now - holdStart >= Self.intakeYieldBudget {
                        await Task.yield()
                        holdStart = ContinuousClock.now
                        sinceYield = 0
                    }
                }
            }
        }
        if stateObserverTask == nil {
            stateObserverTask = Task { [weak self] in
                guard let self else { return }
                for await state in self.client.stateChanges {
                    self.handle(state: state)
                }
            }
        }
    }

    /// Fan a single gateway event out to the right store.
    private func route(event: GatewayEvent) {
        // The router task now outlives disconnects (— cancelling it
        // killed the single-consumer stream), so frames the dead socket
        // buffered into the unbounded stream can drain AFTER a deliberate
        // disconnect. `hasConnected` is cleared first thing in `disconnect()`
        // and only set after a verified `configure()` connect (with no
        // suspension before the flag, so a fresh connection's own frames can
        // never be dropped) — gate on it so a ghost frame from a server the
        // user just left can't re-claim a turn or mutate store state
        //.
        guard hasConnected else { return }
        // a frame carrying `broadcast_gap` means the gateway's
        // bounded per-client broadcast queue dropped frames before this one
        // (F3 overflow policy, ws.py). The live stream has a hole, so
        // reconcile: REST-backfill the active transcript (authoritative) and
        // refresh the drawer so list state catches up too. Runs alongside
        // normal routing — the carrying frame itself is still applied below.
        if let gap = event.broadcastGap, gap > 0 {
            Task {
                await self.chatStore.backfill()
                await self.sessionStore.refresh()
            }
        }
        switch event.type {
        case .gatewayReady:
            Task { await self.sessionStore.refresh() }
        case .messageStart, .messageDelta, .messageComplete,
             .thinkingDelta, .reasoningDelta,
             .toolStart, .toolProgress, .toolComplete,
             .approvalRequest, .clarifyRequest,
             // turn-level gateway failures route to ChatStore so a
             // failed turn clears streaming and surfaces, instead of dropping to
             // `.unknown` and spinning forever.
             .error,
             // F4A-A2: subagent delegation frames were previously dropped to
             // `.unknown` at this whitelist (one of the THREE drop layers). They
             // carry the parent runtime's `session_id` (+ `stored_session_id` on
             // broadcast frames), so they stamp activity and route through the
             // same ownership gate as message/tool frames.
             .subagentStart, .subagentThinking, .subagentTool,
             .subagentProgress, .subagentComplete,
             // F4A-A2: secure prompts. These are session-local (the gateway does
             // not broadcast-mirror them), carry the requesting runtime's
             // `session_id`, and drive ChatStore's transient secure-prompt state.
             .sudoRequest, .secretRequest:
            // The first observed subagent frame proves the patched gateway emits
            // delegation events (E1 passive capability signal — mirror
            // `noteBroadcastObserved`). Done here, at the routing source, before
            // ownership classification, so the inspector affordance can appear.
            switch event.type {
            case .subagentStart, .subagentThinking, .subagentTool,
                 .subagentProgress, .subagentComplete:
                capabilities.noteSubagentObserved()
            default:
                break
            }
            // Stamp the live-activity registry so the drawer can pulse a row
            // whose conversation just moved (this device or a broadcasting
            // client). Prefer the frame's stored id (present on broadcast /
            // mirror frames); otherwise, for our own active runtime turn, use
            // the active stored id. Stamping before `handle` is harmless — it
            // only feeds the drawer's dot and never gates transcript routing.
            stampActivity(for: event)
            // coalesced session-list refresh on streaming frames.
            // Both message.start (a new turn is beginning — the session's
            // last_active will move) and message.complete (the turn finished —
            // last_active is now authoritative) trigger a trailing debounce so
            // frame bursts collapse to one fetch. Skipped for every other frame
            // type (delta, tool, etc.) to avoid hammering the server during a
            // long streaming response.
            switch event.type {
            case .messageStart, .messageComplete:
                // optimistically re-sort the originating session to the
                // top of the drawer the instant a turn starts/finishes — the
                // server only advances lastActive on completion, so without this
                // the row sits in its old slot until a refresh round-trips. Use
                // the broadcast frame's stored id (foreign turns) or, for our own
                // active turn, the active stored id. Unknown ids no-op here and
                // are picked up by the debounced refresh below (covers a brand-new
                // remote session's first message).
                let activityStoredId = event.storedSessionId
                    ?? (event.sessionId == sessionStore.activeRuntimeId
                        ? sessionStore.activeStoredId : nil)
                sessionStore.noteActivity(storedId: activityStoredId)
                scheduleSessionRefresh()
            default:
                break
            }
            chatStore.handle(event: event)
            // The inbox accumulates broadcast approval/clarify prompts across
            // every session and expires them on message.complete. It ignores
            // all other event types, so forwarding here is a no-op for them.
            // Routed AFTER `chatStore.handle` so the active-session chat
            // behavior is unchanged.
            inboxStore?.handle(event: event)
        case .sessionInfo:
            // session hot-swap state update. The gateway emits session.info
            // after a config.set with a session_id (model/reasoning/fast hot-swap).
            // Only apply it when the event belongs to our active runtime session.
            if let sid = event.sessionId,
               !sid.isEmpty,
               sid == sessionStore.activeRuntimeId {
                applySessionInfo(event.payload)
            }
        case .statusUpdate, .unknown:
            break
        }
    }

    /// Schedule a coalesced session-list refresh with a trailing debounce
    /// (item 1). Calling this repeatedly during a streaming burst collapses
    /// all triggers to one `sessionStore.refresh()` that fires 400ms after the
    /// LAST call in each burst. The debounce task slot is shared by the
    /// event-router path (message frames) and the foreground path
    /// (`handleScenePhase`) so both sources collapse together.
    ///

    /// Not called during the connect/hydration phase: `gatewayReady` fires a
    /// direct `sessionStore.refresh()` (not via this debounce) and `recoverActiveSession`
    /// also ends with a direct refresh — the debounce is exclusively for the
    /// per-message streaming triggers.
    private func scheduleSessionRefresh() {
        sessionRefreshDebounceTask?.cancel()
        sessionRefreshDebounceTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(Self.sessionRefreshDebounceMs))
            guard !Task.isCancelled, let self else { return }
            await self.sessionStore.refresh()
        }
    }

    /// Resolve the *stored* session id a streaming frame belongs to and stamp the
    /// session store's live-activity registry. Broadcast/mirror frames carry
    /// `stored_session_id` directly; for a frame on our own active runtime turn
    /// (no stored id on the wire) we attribute it to the active stored session.
    private func stampActivity(for event: GatewayEvent) {
        if let stored = event.storedSessionId, !stored.isEmpty {
            // A frame carrying stored_session_id proves broadcast enrichment is
            // live on this gateway (E1: the broadcast capability is passive).
            capabilities.noteBroadcastObserved()
            sessionStore.noteActivity(storedSessionId: stored)
        } else if let sid = event.sessionId,
                  sid == sessionStore.activeRuntimeId,
                  let active = sessionStore.activeStoredId {
            sessionStore.noteActivity(storedSessionId: active)
        }
    }

    /// React to a transport state transition: keep `phase` honest and start the
    /// reconnect loop when an established connection drops.
    private func handle(state: GatewayConnectionState) {
        switch state {
        case .idle, .connecting:
            break
        case .open:
            // Don't override an in-flight hydration: the WS may resolve
            // `.open` right after `configure` sets `.hydrating`; the hydration
            // coordinator owns the `.hydrating → .connected` transition. The
            // reconnect loop sets `.connected` itself on success.
            if reconnectTask == nil, phase != .hydrating { phase = .connected }
        case .closed, .failed:
            // A dropped transport can never deliver the in-flight turn's
            // completion — tear down streaming state NOW so the post-reconnect
            // `backfill()` isn't no-op'd by its own `guard !isStreaming`
            // Idempotent, so the repeated `.failed` transitions
            // of the reconnect loop's own attempts are harmless.
            chatStore.handleConnectionDrop()
            // A drop after we were connected → reconnect. An expected close
            // (disconnect/needsSetup) leaves `hasConnected` false.
            guard hasConnected, reconnectTask == nil else { return }
            startReconnectLoop()
        }
    }

    // MARK: - Reconnect

    /// Exponential-backoff reconnect loop. Attempt 0 fires immediately (no
    /// pre-delay) so a foreground wake or an initial drop reconnects without
    /// any added latency. Subsequent attempts wait
    /// `min(0.5 * 2^attempt, 30)s + jitter(0…0.5s)` before retrying. On
    /// success, re-resumes the active session and backfills the transcript.
    private func startReconnectLoop() {
        reconnectTask = Task { [weak self] in
            guard let self else { return }
            var attempt = 0
            while !Task.isCancelled {
                self.phase = .reconnecting(attempt: attempt)

                // Attempt 0: connect immediately — no backoff delay.
                // The loop can be (re)started from `handleScenePhase` on
                // foreground, where the user expects an instant reconnect;
                // adding even the base 0.5s delay is perceptible dead air.
                // Subsequent attempts back off normally.
                if attempt > 0 {
                    let delay = Self.backoffDelay(attempt: attempt)
                    try? await Task.sleep(for: .seconds(delay))
                }
                if Task.isCancelled { return }

                guard let url = URL(string: self.serverURLString),
                      let token = self.currentToken else {
                    // Config vanished mid-loop (e.g. a disconnect raced the
                    // backoff sleep). Route to setup WITH `hasConnected`
                    // cleared — leaving it true would strand the user on the
                    // chat shell in `.offline` with NO re-pair affordance
                    // (RootView only shows WelcomeView when hasConnected is
                    // false). Release audit P1.
                    self.hasConnected = false
                    self.phase = .needsSetup
                    self.reconnectTask = nil
                    return
                }

                do {
                    try await self.client.connect(baseURL: url, token: token)
                    if Task.isCancelled { return }
                    await self.recoverActiveSession()
                    self.phase = .connected
                    self.reconnectTask = nil
                    self.consecutiveReconnectFailures = 0
                    return
                } catch {
                    // The WS handshake error is not typed as auth, so once a
                    // string of reconnects keep failing we re-probe REST to tell
                    // an auth *revocation* (→ re-pair) apart from plain
                    // unreachability (→ keep retrying). (D3 RE-PAIR FLOW: "WS
                    // rejects repeatedly".)
                    self.consecutiveReconnectFailures += 1
                    if self.consecutiveReconnectFailures >= Self.authReprobeThreshold,
                       await self.probeIsAuthRevoked(url: url, token: token) {
                        if Task.isCancelled { return }
                        self.reauthRequired = true
                        self.phase = .needsSetup
                        self.reconnectTask = nil
                        return
                    }
                    // Keep trying; bump the attempt for a longer next backoff.
                    attempt += 1
                }
            }
        }
    }

    /// Re-probe REST to determine whether the saved token has been revoked.
    /// Returns `true` only on a definitive auth rejection (401/403); any other
    /// outcome (success, network error, other status) returns `false` so the
    /// reconnect loop keeps retrying rather than dumping the user to re-pair on a
    /// transient outage.
    private func probeIsAuthRevoked(url: URL, token: String) async -> Bool {
        do {
            _ = try await RestClient(baseURL: url, token: token).status()
            return false
        } catch {
            return Self.isAuthFailure(error)
        }
    }

    /// Backoff in seconds for `attempt` ≥ 1: `min(0.5 * 2^attempt, 30) + jitter`.
    /// Attempt 0 is handled by the caller (immediate, no delay).
    static func backoffDelay(attempt: Int) -> Double {
        let base = min(0.5 * pow(2.0, Double(attempt)), 30.0)
        let jitter = Double.random(in: 0...0.5)
        return base + jitter
    }

    // MARK: - Auth-failure detection

    /// `true` when an error is a REST auth rejection (HTTP 401 or 403) — the
    /// signal that the device's pairing/token is no longer valid. (D3 RE-PAIR
    /// FLOW.)
    static func isAuthFailure(_ error: Error) -> Bool {
        if case let RestError.badStatus(code, _) = error {
            return code == 401 || code == 403
        }
        return false
    }

    /// The user-facing message returned to a configure caller when the token is
    /// rejected for auth — friendly, and pointing at the fix (scan a new code).
    static let reauthMessage =
        "This device's pairing was revoked. Scan a new pairing code to reconnect."

    // MARK: - Device-token auto-upgrade (W3A-A — silent rotation)

    /// Transparently swap a legacy SHARED token for a per-device token when the
    /// connected gateway advertises the W3a `devices` capability and this device
    /// does not yet hold a device token for `serverURL`.
    ///

    /// This is the migration bridge: the user's live phone is paired with the
    /// shared token today; after the server gains device routes, the FIRST
    /// connect silently issues a device token, persists it to the Keychain
    /// (overwriting the shared token IN THE KEYCHAIN ITEM for this server) and the
    /// non-secret `device_id` to UserDefaults, and re-points `currentToken` — all
    /// WITHOUT `configure()`/`disconnect()`/`connect()` (no socket rebuild, no
    /// capability reset). The swap is transparent because the server accepts BOTH
    /// tokens; the live WS keeps running on the (still-valid) old token until the
    /// next request naturally uses the new one.
    ///

    /// Gating (ALL must hold, else this is a no-op):
    ///  - `devices == .available` (stock server / flaky probe ⇒ keep shared token,
    ///  never issue);
    ///  - no `device_id` already recorded for this server (already upgraded, or a
    ///  v2 QR handed us a device token — don't re-issue);
    ///  - we are still configured against `serverURL` with a live token.
    ///

    /// FAILURE IS SILENT (binding): if `issueDevice` throws (500 persist failure,
    /// 401, transport), the app KEEPS the shared token (no regression) and the
    /// next connect retries (this method is re-invoked from `recoverActiveSession`
    /// after a reconnect). The shared token never stops working.
    ///

    /// SECRETS HYGIENE (binding): the issued token goes straight to the Keychain
    /// + `currentToken` (in-memory, non-observable) and is NEVER logged,
    /// telemetered, written to UserDefaults, or held in a `@Snapshotable`
    /// accessor. Only the non-secret `device_id` is persisted to UserDefaults.
    func autoUpgradeToDeviceTokenIfNeeded(serverURL: String) async {
        // The server must advertise the capability — never issue against a stock
        // gateway (it has no route) or on an unsettled/flaky probe.
        guard capabilities.devices == .available else { return }
        // Already holding a device token for this server (prior upgrade or a v2
        // QR) → nothing to do.
        guard DefaultsKeys.deviceId(server: serverURL) == nil else { return }
        // Must still be the active configuration with a live token + REST client.
        guard serverURLString == serverURL, let rest else { return }

        let issued: IssuedDevice
        do {
            issued = try await rest.issueDevice(name: Self.deviceNameHint)
        } catch {
            // Keep the shared token silently (no regression). A later connect
            // retries. Never log the error path with a token — `issueDevice`
            // surfaces only a status/transport error, never the token itself.
            return
        }

        // The connection may have changed (disconnect / re-configure to another
        // server) while the issue round-trip was in flight; only swap if we are
        // STILL configured against the same server with the same shared token we
        // started from. (A v2 QR re-pair mid-flight would have recorded a
        // device_id, caught by the guard re-check below.)
        guard serverURLString == serverURL,
              DefaultsKeys.deviceId(server: serverURL) == nil else { return }

        // Persist the device token to the Keychain (overwrites the shared token in
        // the per-server item) and re-point the in-memory token. No reconfigure:
        // the server accepts both, so the live socket is undisturbed.
        do {
            try KeychainService.saveToken(issued.token, server: serverURL)
        } catch {
            // Keychain write failed — keep the shared token (still valid). Do NOT
            // record the device_id, so a later connect retries cleanly.
            return
        }
        currentToken = issued.token
        DefaultsKeys.setDeviceId(issued.deviceId, server: serverURL)
    }

    #if DEBUG
    /// DEBUG-only, NON-SECRET observability for the W3a integration gate: the
    /// recorded `device_id` for the current server (the proof the app
    /// auto-upgraded to a per-device token), or `nil` if it still holds the shared
    /// token. NEVER the token value — `device_id` is the opaque, non-secret handle
    /// (safe to list/log per the spec). Surfaced via the hand-maintained
    /// StateAccessor, mirroring the `fsCapability` pattern. Absent in Release.
    var recordedDeviceIdForCurrentServer: String? {
        DefaultsKeys.deviceId(server: serverURLString)
    }
    /// DEBUG-only observability: whether the Settings Devices section would render
    /// for the current connection (`devices == .available`). The integration
    /// gate's stock-degradation step asserts this is `false` on a stock server.
    var devicesSectionVisible: Bool {
        capabilities.devices == .available
    }
    #endif

    /// The best client-side device-name hint available without a new entitlement.
    /// `UIDevice.current.name` returns a generic model name (e.g. "iPhone") on
    /// iOS 16+ without the user-assigned-device-name entitlement — acceptable per
    /// the spec (the name is a hint; a rename endpoint is a later follow-up).
    /// Falls back to "iPhone" off-UIKit (tests / extensions).
    static var deviceNameHint: String {
        #if canImport(UIKit)
        let name = UIDevice.current.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "iPhone" : name
        #else
        return "iPhone"
        #endif
    }

    /// After a (re)connect, re-resume the active session so its runtime id is
    /// valid on the new connection, then backfill the transcript over REST.
    private func recoverActiveSession() async {
        // Re-probe capabilities after a reconnect — FORCED: this path
        // only runs after the socket genuinely dropped, and a restart on the
        // same URL may have swapped a stock↔patched gateway; the same-URL
        // cache short-circuit would pin stale feature gates for the whole app
        // version (features hidden, or shown against 404ing routes, device
        // auto-upgrade never firing).
        //

        // FIRE-AND-FORGET (build-30 freeze fix): spawned, NOT awaited inline.
        // probe() performs ~8 @Observable mutations on `capabilities` through
        // `resolvedPathStyle`, which `rest`/`control` read — so awaiting it
        // here serialized that invalidation thrash onto the reconnect-critical
        // path and saturated the main actor while the always-mounted drawer was
        // interactive (the W3 regression that froze the UI on reconnect →
        // drawer-open, and starved the transcript seed → empty render).
        // Hydration below must NOT wait on it: the session-list + transcript
        // endpoints are absolute and path-style-independent, and the
        // mobile-group affordances are UI-gated on the capability state the
        // probe still settles asynchronously (plus the background flows'
        // alternate-family 404 self-heal). Matches the proven initial-connect
        // contract in configure().
        if let rest {
            Task { [weak self] in
                guard let self else { return }
                await self.capabilities.probe(
                    serverURL: self.serverURLString, rest: rest, force: true
                )
                // Capability-dependent settles run BEHIND the probe but OFF the
                // reconnect-critical path (same ordering as configure()).
                // W3A-A: retry the device-token auto-upgrade — covers a server
                // that gained device routes while offline, or a prior failed
                // issue. No-op once a device token is held.
                await self.autoUpgradeToDeviceTokenIfNeeded(serverURL: self.serverURLString)
                // F4b: re-load the switcher profile list now the capability is
                // re-affirmed (clears the cache on a stock gateway).
                await self.sessionStore.loadProfiles()
            }
        }
        // Re-resolve the running model — it may have changed while we were
        // offline (another client switched it) (F0).
        await refreshActiveModel()
        if sessionStore.activeStoredId != nil {
            await sessionStore.resumeActiveAfterReconnect()
            await chatStore.backfill()
            // Flush the offline outbox now the transcript is current — but only
            // with a live runtime session, or the queue would burn through with
            // a "No active session" error (see QueueStore drain notes).
            if sessionStore.activeRuntimeId != nil {
                await queueStore?.drain(chat: chatStore)
            }
        }
        await sessionStore.refresh()
        // CACHE-FIRST coverage (WhatsApp bar): re-warm the recent transcripts now
        // the list is current again — covers sessions that moved while offline.
        sessionStore.prefetchRecentTranscripts()
        // Recover any approval/clarify prompt whose live WS broadcast we missed
        // while suspended (the catch-up that makes a background-suspend a
        // non-event for pending approvals).
        catchUpPendingPrompts()
    }

    /// Fire-and-forget catch-up of server-side pending approvals/clarifies into
    /// the inbox. Runs on initial connect, every reconnect, and on foreground —
    /// the same hooks as transcript `backfill()` — so a prompt the app missed
    /// while iOS had it suspended (a dropped WS broadcast) is still recovered.
    ///
    /// Non-throwing by construction: ``RestClient/pendingPrompts()`` maps every
    /// non-200 (incl. 401/403) to an empty batch, so a transient failure shows
    /// nothing rather than an error — the live broadcast stays the primary path
    /// and the gateway GCs stale records after their ttl.
    private func catchUpPendingPrompts() {
        guard let rest, let inboxStore else { return }
        Task { inboxStore.catchUp(await rest.pendingPrompts()) }
    }

    // MARK: - Scene phase

    /// React to app lifecycle changes.
    ///

    /// `.active`: if the socket is dead (iOS killed it in the background) OR a
    /// reconnect loop is mid-backoff, cancel the pending wait and kick an
    /// IMMEDIATE reconnect attempt — the client must not sit in a multi-second
    /// backoff window while the user is staring at the screen. Then always
    /// backfill the transcript over REST to re-sync with other clients.
    /// `.background`/`.inactive`: cancel the paced transcript prefetch (WhatsApp
    /// bar) so it doesn't run against a socket iOS is about to kill; otherwise a
    /// no-op — the socket may be killed and we recover on the next foreground.
    func handleScenePhase(_ scenePhase: ScenePhase) {
        guard scenePhase == .active else {
            // Leaving the foreground: stop any in-flight prefetch sweep.
            sessionStore.cancelPrefetch()
            return
        }
        guard hasConnected else { return }

        Task { [weak self] in
            guard let self else { return }
            let socketState = await self.client.state
            let dead: Bool
            switch socketState {
            case .closed, .failed: dead = true
            default: dead = false
            }

            if dead {
                // iOS killed the socket in the background. If we already have a
                // reconnect loop running (possibly mid-backoff), RESET it so the
                // next attempt fires immediately rather than waiting out whatever
                // backoff interval was in progress. The user just foregrounded —
                // they expect instant reconnection. Cancelling the existing task
                // also cancels any pending `Task.sleep` inside it, so
                // `startReconnectLoop` can begin at attempt 0 with zero delay.
                if self.reconnectTask != nil {
                    self.reconnectTask?.cancel()
                    self.reconnectTask = nil
                }
                // iOS killed the socket in the background and the state observer
                // may not have seen the transition — finalize any in-flight stream
                // before reconnecting so the recovery backfill isn't no-op'd
                //.
                self.chatStore.handleConnectionDrop()
                self.startReconnectLoop()
            } else if case .connected = self.phase {
                await self.chatStore.backfill()
                // Re-pull pending approvals on foreground: a prompt may have been
                // raised (or another client may have left one) while the app was
                // backgrounded on a still-live socket — recover it into the inbox.
                self.catchUpPendingPrompts()
                // refresh the session list on foreground so the
                // drawer reflects changes made on other clients while the app
                // was backgrounded. Uses the shared coalesced seam so a
                // simultaneous streaming trigger and a foreground collapse to one
                // fetch. The reconnect path already ends with `recoverActiveSession`
                // → `sessionStore.refresh()`, so this only runs on a live socket.
                self.scheduleSessionRefresh()
            }
        }
    }

    // MARK: - Running model (F0 / Amendment B)

    /// Fetch the gateway's currently-configured main model and publish its short
    /// display name into ``activeModelName``.
    ///

    /// Called on connect, after a reconnect, and after a model switch (the
    /// `ModelPickerView` `onModelChanged` hook → this). No-op when no control
    /// surface is configured. Best-effort: a probe failure leaves the prior
    /// value untouched rather than blanking the chip on a transient error.
    func refreshActiveModel() async {
        guard let control else { return }
        guard let info = try? await control.modelInfo() else { return }
        activeModelName = Self.shortModelName(provider: info.provider, model: info.model)
    }

    /// Reduce a wire model id to a compact chip label: drop a leading
    /// `provider/` (or `provider:`) prefix and any trailing 6–8 digit date stamp
    /// (e.g. `-20250514`, `-2024-08-06`). Returns `nil` when the model is absent
    /// or empties out — the chip stays hidden rather than showing a stray token.
    ///

    /// Examples:
    /// - `anthropic/claude-opus-4-20250514` → `claude-opus-4`
    /// - `claude-3-5-sonnet-20241022` → `claude-3-5-sonnet`
    /// - `gpt-4o-2024-08-06` → `gpt-4o`
    static func shortModelName(provider: String?, model: String?) -> String? {
        guard var name = model?.trimmingCharacters(in: .whitespacesAndNewlines),
              !name.isEmpty else { return nil }

        // Strip a leading provider qualifier ("anthropic/…", "openai:…").
        if let slashIdx = name.firstIndex(where: { $0 == "/" || $0 == ":" }) {
            name = String(name[name.index(after: slashIdx)...])
        }

        // Strip a trailing date stamp without eating a version number. Two
        // recognised shapes (and only these), so `claude-opus-4` keeps its `4`
        // while `claude-opus-4-20250514` loses the date:
        //  (a) one trailing segment of ≥ 6 digits — `…-20250514`
        //  (b) a trailing `YYYY-MM-DD` triple — `…-2024-08-06`
        var segments = name.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
        func isDigits(_ s: String, _ n: Int) -> Bool { s.count == n && s.allSatisfy(\.isNumber) }
        func isLongDigits(_ s: String) -> Bool { s.count >= 6 && s.allSatisfy(\.isNumber) }

        if segments.count >= 4,
           isDigits(segments[segments.count - 1], 2),
           isDigits(segments[segments.count - 2], 2),
           isDigits(segments[segments.count - 3], 4) {
            // (b) YYYY-MM-DD — drop the trailing three segments.
            segments.removeLast(3)
        } else if segments.count >= 2, let last = segments.last, isLongDigits(last) {
            // (a) single compact date stamp — drop the trailing segment.
            segments.removeLast()
        }
        name = segments.joined(separator: "-")

        let trimmed = name.trimmingCharacters(in: CharacterSet(charactersIn: "-").union(.whitespaces))
        return trimmed.isEmpty ? nil : trimmed
    }
}
