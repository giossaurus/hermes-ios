import Foundation

// Codable mirrors of the hermes gateway wire types
// (tui_gateway/server.py + the desktop app).
// All decode via JSONDecoder with .convertFromSnakeCase
// (see JSONValue.decoded(as:)).

// MARK: - Sessions

/// One row in `session.list` → `result.sessions[]`, or a (richer) row from
/// REST `GET /api/sessions` — extra REST keys are simply ignored.
struct SessionSummary: Decodable, Identifiable, Sendable, Equatable {
    let id: String
    let title: String?
    let preview: String?
    let startedAt: Double?
    let messageCount: Int?
    let source: String?
    /// Most recent activity (REST rows only; nil on the WS RPC shape).
    /// `var` so `SessionStore.noteActivity` can optimistically bump it to NOW on
    /// a live frame — re-sorting the row to the top immediately, before
    /// the server's lastActive (which only advances on message.complete) round-trips.
    var lastActive: Double?
    /// Working directory the session was started in (REST rows carry it; the WS
    /// `session.list` RPC shape omits it, so it decodes `nil` there). Drives the
    /// drawer's "Group by workspace" sectioning (UI Batch H2). The trimmed value
    /// is the group key; its basename is the section label. See
    /// ``workspaceKey`` / ``workspaceLabel``.
    let cwd: String?

    /// Owning profile name (multi-profile, F4b). Tagged onto each row ONLY by the
    /// `GET /api/profiles/sessions` aggregate handler (wire key `profile`, a plain
    /// single-word key that `.convertFromSnakeCase` leaves unchanged — NOT
    /// `profile_name`, which is the distinct ``SessionRuntimeInfo/profileName``
    /// create/resume `info` key). The stock `GET /api/sessions` row and the WS
    /// `session.list` shape both omit it, so it decodes `nil` there — the dormant
    /// single-profile path stays byte-for-byte unchanged. Declared LAST with a
    /// default so the synthesized memberwise init keeps it as a trailing optional
    /// parameter: the three positional callers (`asSessionSummary`, `rename`'s
    /// rebuild, the test fixture helper) compile without passing it.
    var profile: String? = nil

    /// Stable group key for workspace grouping: the trimmed ``cwd``, or the
    /// sentinel `"__no_workspace__"` when blank/absent — replicating the
    /// desktop sidebar's `workspaceGroupsFor` (the desktop app).
    var workspaceKey: String {
        let path = cwd?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return path.isEmpty ? Self.noWorkspaceKey : path
    }

    /// Human-readable section label for workspace grouping: the basename of
    /// ``cwd`` (last non-empty path component, after stripping trailing
    /// separators), falling back to the full trimmed path, then to
    /// "No workspace". Mirrors the desktop `baseName(path) || path || 'No workspace'`.
    var workspaceLabel: String {
        let path = cwd?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !path.isEmpty else { return Self.noWorkspaceLabel }
        return Self.basename(of: path) ?? path
    }

    /// Sentinel group key for sessions with no workspace (matches desktop).
    static let noWorkspaceKey = "__no_workspace__"
    /// Label shown for the no-workspace bucket.
    static let noWorkspaceLabel = "No workspace"

    /// Last non-empty path component of a `/`- or `\`-separated path, after
    /// stripping trailing separators. `nil` when nothing remains (e.g. "/" or "").
    /// Foundation-only mirror of the desktop `baseName` helper.
    static func basename(of path: String) -> String? {
        let components = path.split(whereSeparator: { $0 == "/" || $0 == "\\" })
        return components.last.map(String.init)
    }

    var displayTitle: String {
        if let title, !title.isEmpty { return title }
        if let preview, !preview.isEmpty { return String(preview.prefix(64)) }
        return "Untitled session"
    }

    var startedDate: Date? {
        guard let startedAt else { return nil }
        return Date(timeIntervalSince1970: startedAt)
    }

    /// Timestamp shown in the list: last activity when known, else creation.
    var displayDate: Date? {
        if let lastActive { return Date(timeIntervalSince1970: lastActive) }
        return startedDate
    }

    /// Human-readable title for display surfaces (drawer rows + chat header).
    ///

    /// Cron / automation sessions echo their raw system prompt
    /// ("[IMPORTANT: You are running as a sc…") into `title`, which truncates
    /// uselessly in a list or nav bar (design audit C3). Collapse those to
    /// "Automation · <job>"; everything else uses ``displayTitle`` verbatim.
    ///

    /// Shared by `DrawerSessionRow` and `ChatView` so both surfaces humanize
    /// identically.
    var displayHumanTitle: String {
        let raw = displayTitle
        let isAutomation = source == "cron" || raw.hasPrefix("[IMPORTANT:")
        guard isAutomation else { return raw }
        return "Automation · \(automationJobName)"
    }

    /// Best-effort short job name for an automation session: the real (non-prompt)
    /// title when present, else a generic "Scheduled" label.
    private var automationJobName: String {
        if let title, !title.isEmpty, !title.hasPrefix("[IMPORTANT:") {
            return String(title.prefix(40))
        }
        return "Scheduled"
    }
}

// MARK: - Profiles (F4b — multi-profile switcher, feature-detected)

/// One entry from `GET /api/profiles` → `result.profiles[]` (the switcher's data
/// and its existence probe). The server's `_profile_to_dict`
/// (`web_server.py`) emits a much richer dict (path, model, provider,
/// has_env, skill_count, gateway_running, distribution_name, version, source,
/// has_alias, …); the switcher needs only the identity fields, so we decode the
/// minimal subset and let plain `Decodable` ignore every other key.
///

/// Decoded via `.convertFromSnakeCase`, so the wire key `is_default` maps to
/// ``isDefault``. The DEFAULT profile is the single row where `name == "default"`
/// AND `is_default == true` (`profiles.py:604-628`); named profiles always carry
/// `is_default == false`.
struct ProfileSummary: Decodable, Identifiable, Sendable, Equatable {
    /// Profile name — the stable identity and the value threaded as the `profile`
    /// scope on rail/session calls. Doubles as ``id`` (names are unique).
    let name: String
    /// `true` only for the launch/default profile (the `default` row).
    let isDefault: Bool
    /// Optional human description for a switcher subtitle; absent ⇒ `nil`.
    let description: String?

    var id: String { name }
}

/// Wrapper for `GET /api/profiles/sessions` (`web_server.py`) — the
/// cross-profile aggregate rail used ONLY when the active scope is "All profiles"
/// AND multi-profile is available. Single-profile / default scope keeps using the
/// existing `GET /api/sessions`, so the dormant path is byte-for-byte unchanged.
///

/// Decoded via `.convertFromSnakeCase`: `profile_totals` → ``profileTotals``. Each
/// `sessions` row is a ``SessionSummary`` carrying the handler's `profile` tag
/// (`web_server.py`) in ``SessionSummary/profile``. Profiles whose
/// `state.db` failed to open surface in ``errors`` (read-only; never throws).
struct ProfilesSessionsResult: Decodable, Sendable, Equatable {
    /// The page window (`merged[offset:offset+limit]`) of session rows, each
    /// tagged with its owning ``SessionSummary/profile``.
    let sessions: [SessionSummary]
    /// Sum of per-profile session counts across the aggregate.
    let total: Int
    /// Per-profile session counts, keyed by profile name.
    let profileTotals: [String: Int]
    /// Echo of the requested page size.
    let limit: Int
    /// Echo of the requested page offset.
    let offset: Int
    /// Per-profile load errors (a profile whose `state.db` failed to open).
    let errors: [ProfileLoadError]

    /// One `errors[]` entry: the profile that failed and why.
    struct ProfileLoadError: Decodable, Sendable, Equatable {
        let profile: String
        let error: String
    }
}

/// Result of `session.create` / `session.resume`.
struct SessionOpenResult: Decodable, Sendable {
    let sessionId: String
    let storedSessionId: String?
    let messageCount: Int?
    let info: SessionRuntimeInfo?

    // NOTE: the RPC decode path uses `.convertFromSnakeCase`
    // (`JSONValue.decoded(as:)`), so wire keys arrive already camelCased —
    // these CodingKeys MUST be camelCase, never the snake_case wire form.
    private enum CodingKeys: String, CodingKey {
        case sessionId
        case storedSessionId
        case resumed
        case messageCount
        case info
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.sessionId = try c.decode(String.self, forKey: .sessionId)
        // The resume RPC returns the stored/target id under `resumed`
        // (tui_gateway/server.py `"resumed": target`); session.create
        // uses `stored_session_id`. Prefer the explicit stored key, fall back
        // to `resumed` so a resumed session still gets its stored id (drives
        // the compression-chain projection + transcript seeding).
        self.storedSessionId = try c.decodeIfPresent(String.self, forKey: .storedSessionId)
            ?? c.decodeIfPresent(String.self, forKey: .resumed)
        self.messageCount = try c.decodeIfPresent(Int.self, forKey: .messageCount)
        self.info = try c.decodeIfPresent(SessionRuntimeInfo.self, forKey: .info)
    }
}

/// `info` block returned by session.create/resume and session.status.
struct SessionRuntimeInfo: Decodable, Sendable {
    let model: String?
    let provider: String?
    let running: Bool?
    let cwd: String?
    let lazy: Bool?
    let profileName: String?
    /// Reasoning effort level for this session ("minimal"/"low"/"medium"/"high"/"xhigh"/"none"/"").
    /// Maps to `hermes_constants.VALID_REASONING_EFFORTS` on the gateway side.
    let reasoningEffort: String?
    /// True when the session's service_tier is "priority" (fast mode on).
    let fast: Bool?
    /// Service tier string ("priority" / "").
    let serviceTier: String?
}

/// Result of `session.status`.
struct SessionStatusResult: Decodable, Sendable {
    let running: Bool?
    let model: String?
    let provider: String?
    let usage: UsageStats?
}

/// A stored transcript message (REST `/api/sessions/{id}/messages` and the
/// `messages` array on session.create/resume). `content` is heterogeneous
/// on the wire (string or structured blocks) so it stays a JSONValue.
struct StoredMessage: Sendable {
    let role: String
    let content: JSONValue
    let timestamp: Double?

    /// ARCH37 STEP 4 — STABLE WIRE IDENTITY. A server-assigned monotonic ordinal
    /// (`id` on the wire), stable across fetches because the gateway's row order is
    /// authoritative (`_history_to_messages`). When present, the seed producer keys
    /// row identity on this (`deterministicID(wireKey:)`) instead of the positional
    /// `{ts}-{index}-{role}` key — so a cache->network reconcile is in-place across
    /// count drift (no tail remount). ADDITIVE: `nil` on stock/old gateways that do
    /// not emit it, where the producer falls back to the positional key (unchanged).
    let wireId: Int?

    // MARK: - Batch B (§2.3) — fields the seed producer reconstructs from
    //

    // The live REST payload (`/api/sessions/{id}/messages`, re-verified against
    // session `cron_example_session`) carries the FULL union of
    // keys on every row, with `null`/`""` where the field is absent for that
    // role. These are exactly the fields `toChatMessages` (§2.4) needs to rebuild
    // ordered interleaved `parts[]` — without them the seed mapper has nothing to
    // reconstruct, so this widening is a hard precondition for Batch B.

    /// `tool_calls[]` on a role:assistant row. Each carries `call_id`/`id` and a
    /// nested `function:{name, arguments(JSON string)}`. Verified shape on the
    /// live tool-heavy session: keys `[call_id, function, id, response_item_id,
    /// type]`, function keys `[name, arguments]`, `call_id == id`.
    let toolCalls: [WireToolCall]?
    /// `tool_call_id` — present on role:tool rows, correlating the result to the
    /// assistant's pending tool-call by id.
    let toolCallId: String?
    /// `tool_name` — present on role:tool rows (the fallback correlation key when
    /// no `tool_call_id` matches).
    let toolName: String?
    /// `reasoning` — the settled thinking text for an assistant row. The wire also
    /// carries `reasoning_content`/`reasoning_details`; first non-empty wins
    /// (desktop chat-messages.ts:739-742).
    let reasoning: String?
    /// `finish_reason` — `"tool_calls"` / `"stop"` etc. Retained for parity /
    /// future use; not load-bearing for the body structure.
    let finishReason: String?

    init?(json: JSONValue) {
        guard let role = json["role"]?.stringValue else { return nil }
        self.role = role
        self.content = json["content"] ?? .null
        self.timestamp = json["timestamp"]?.doubleValue
        // ARCH37 STEP 4 — stable per-row wire id (additive; nil on stock gateways).
        self.wireId = json["id"]?.intValue

        // tool_calls[]: keep only well-formed calls; an empty/absent array → nil.
        let calls = (json["tool_calls"]?.arrayValue ?? []).compactMap(WireToolCall.init(json:))
        self.toolCalls = calls.isEmpty ? nil : calls

        self.toolCallId = Self.nonEmpty(json["tool_call_id"]?.stringValue)
        self.toolName = Self.nonEmpty(json["tool_name"]?.stringValue)
        // First non-empty of reasoning / reasoning_content / reasoning_details
        // (the latter is a string when populated on this wire).
        self.reasoning = Self.nonEmpty(json["reasoning"]?.stringValue)
            ?? Self.nonEmpty(json["reasoning_content"]?.stringValue)
            ?? Self.nonEmpty(json["reasoning_details"]?.stringValue)
        self.finishReason = Self.nonEmpty(json["finish_reason"]?.stringValue)
    }

    /// Memberwise init for synthesizing fixtures/tests without a JSON envelope.
    init(
        role: String,
        content: JSONValue,
        timestamp: Double? = nil,
        wireId: Int? = nil,
        toolCalls: [WireToolCall]? = nil,
        toolCallId: String? = nil,
        toolName: String? = nil,
        reasoning: String? = nil,
        finishReason: String? = nil
    ) {
        self.role = role
        self.content = content
        self.timestamp = timestamp
        self.wireId = wireId
        self.toolCalls = toolCalls
        self.toolCallId = toolCallId
        self.toolName = toolName
        self.reasoning = reasoning
        self.finishReason = finishReason
    }

    /// Trim, treat empty as absent. The wire sends `""` (not `null`) for several
    /// of these on rows where the field does not apply.
    private static func nonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : value
    }

    /// Flatten wire content into displayable text.
    var text: String {
        if let text = content.stringValue { return text }
        // Structured content: [{type: "text", text: "..."},...]
        if let blocks = content.arrayValue {
            return blocks
                .compactMap { $0["text"]?.stringValue }
                .joined(separator: "\n")
        }
        return content.isNull ? "" : content.compactDescription
    }
}

/// One entry of a stored assistant row's `tool_calls[]`. Shape on the live wire:
/// `{call_id, id, type, response_item_id, function:{name, arguments}}` where
/// `arguments` is a JSON *string*. `call_id` is the stable correlation id the
/// tool-result rows reference via `tool_call_id`; it falls back to `id`.
struct WireToolCall: Sendable, Equatable {
    let callId: String
    let name: String
    /// Raw `function.arguments` (a JSON string). Used to build the activity's
    /// `argsSummary` exactly as the streaming `tool.start` path does.
    let arguments: String

    init?(json: JSONValue) {
        let id = json["call_id"]?.stringValue ?? json["id"]?.stringValue
        guard let callId = id, !callId.isEmpty else { return nil }
        self.callId = callId
        let function = json["function"]
        self.name = function?["name"]?.stringValue ?? json["name"]?.stringValue ?? "tool"
        self.arguments = function?["arguments"]?.stringValue
            ?? json["arguments"]?.stringValue
            ?? ""
    }

    init(callId: String, name: String, arguments: String = "") {
        self.callId = callId
        self.name = name
        self.arguments = arguments
    }
}

// MARK: - Streaming payloads

struct UsageStats: Decodable, Sendable, Equatable {
    let input: Int?
    let output: Int?
    let total: Int?
    let calls: Int?
    let costUsd: Double?

    // MARK: Context-window occupancy (H1)
    //

    // The gateway's `_get_usage` (tui_gateway/server.py) attaches the
    // context-window occupancy of the *last API prompt* to every `usage` dict —
    // on `message.complete` and on `session.status`. These describe per-turn
    // occupancy (how full the prompt that produced this turn was), NOT a
    // per-streamed-token running total, and the app had been dropping them.
    // snake_case → camelCase decode is automatic (JSONValue.decoded / RestClient
    // strategy), so `context_used` etc. map straight onto these names.
    /// Tokens occupying the context window for the last API prompt.
    let contextUsed: Int?
    /// The context window's capacity in tokens.
    let contextMax: Int?
    /// `round(contextUsed / contextMax * 100)`, clamped 0…100 by the server.
    let contextPercent: Int?
    /// Number of history compressions the session has performed so far.
    let compressions: Int?

    /// Compact token count for the context meter: `142_000 → "142K"`,
    /// `1_000_000 → "1M"`, sub-thousand values verbatim. Whole-thousand /
    /// whole-million values drop the decimal (no "142.0K"); otherwise one
    /// fractional digit is kept ("1.5M"). Distinct from `PanelFormat.compact`
    /// (two-digit precision) — the meter wants the terse "142K / 1M" reading the
    /// contract specifies.
    static func formatK(_ value: Int) -> String {
        switch abs(value) {
        case 1_000_000...:
            return trimmedDecimal(Double(value) / 1_000_000) + "M"
        case 1_000...:
            return trimmedDecimal(Double(value) / 1_000) + "K"
        default:
            return String(value)
        }
    }

    private static func trimmedDecimal(_ value: Double) -> String {
        let rounded = (value * 10).rounded() / 10
        if rounded == rounded.rounded() { return String(Int(rounded)) }
        return String(format: "%.1f", rounded)
    }
}

/// Payload of `message.complete`.
struct MessageCompletePayload: Decodable, Sendable {
    let text: String?
    let status: String?
    let usage: UsageStats?
    let reasoning: String?
    let warning: String?
}

/// Payload of `tool.start`.
///

/// Wire contract: the gateway emits the stable id under `tool_id`
/// (`tui_gateway/server.py` `_on_tool_start`, payload key `tool_id`).
/// `tool_call_id` is accepted as a legacy fallback only — the live gateway
/// never sends it.
struct ToolStartPayload: Sendable {
    let toolCallId: String
    let name: String
    let args: JSONValue

    init?(payload: JSONValue) {
        guard let id = payload["tool_id"]?.stringValue
                ?? payload["tool_call_id"]?.stringValue,
              let name = payload["name"]?.stringValue else { return nil }
        self.toolCallId = id
        self.name = name
        self.args = payload["args"] ?? .null
    }
}

/// Payload of `tool.progress`.
///

/// The gateway does not currently emit `tool.progress` (only
/// `tool.start`/`tool.complete`/`tool.generating`); this decoder is
/// forward-compat and follows the same `tool_id`-primary convention.
struct ToolProgressPayload: Sendable {
    let toolCallId: String?
    let text: String?

    init(payload: JSONValue) {
        self.toolCallId = payload["tool_id"]?.stringValue
            ?? payload["tool_call_id"]?.stringValue
        self.text = payload["text"]?.stringValue
    }
}

/// Payload of `tool.complete`.
///

/// Wire contract: `tool_id` + `duration_s` (seconds, Double) — see
/// `tui_gateway/server.py` `_on_tool_complete` (`payload["duration_s"]`).
/// The internal unit stays milliseconds because `ToolActivity.durationMs`
/// and its "Done in %.1fs" rendering (`ChatModels.swift`) divide by 1000.
/// `tool_call_id`/`duration_ms` are legacy fallbacks only.
struct ToolCompletePayload: Sendable {
    let toolCallId: String?
    let name: String?
    let result: JSONValue
    let durationMs: Double?
    /// Structured todo array, mirrored to the TOP level of the `tool.complete`
    /// payload for the `todo` tool (`tui_gateway/server.py` _on_tool_complete,
    /// `payload["todos"]`). The same list is also inside `result.todos`. Held
    /// verbatim (untruncated) for the TodoCardView.
    let todos: [JSONValue]?

    init(payload: JSONValue) {
        self.toolCallId = payload["tool_id"]?.stringValue
            ?? payload["tool_call_id"]?.stringValue
        self.name = payload["name"]?.stringValue
        self.result = payload["result"] ?? .null
        if let seconds = payload["duration_s"]?.doubleValue {
            self.durationMs = seconds * 1000
        } else {
            self.durationMs = payload["duration_ms"]?.doubleValue
        }
        self.todos = payload["todos"]?.arrayValue
    }
}

// MARK: - Approvals / clarifications

/// Payload of `approval.request`.
///

/// Wire shape: the gateway relays the raw approval dict from
/// `tools/approval.py` (`register_gateway_notify(key, lambda data:
/// _emit("approval.request", sid, data))`), which carries `command`,
/// `pattern_key`, and `description` — NOT a `title` key. The old decoder read
/// the never-present `title`, so every approval rendered as the generic
/// "Approval required" with the actual command hidden. We now surface
/// `command` and derive the title from the real fields (preferring an explicit
/// `title`/`approval_title` when a future emitter supplies one, else the
/// command, else a generic fallback).
struct ApprovalRequestPayload: Sendable, Identifiable, Equatable {
    let id: String
    let title: String
    let descriptionText: String?
    let action: String?
    let target: String?
    /// The actual command/operation awaiting approval (`command` on the wire).
    let command: String?
    /// The dangerous-command pattern that gated this approval (`pattern_key`).
    let patternKey: String?

    init(payload: JSONValue) {
        self.id = payload["id"]?.stringValue ?? UUID().uuidString
        let command = payload["command"]?.stringValue
        self.command = (command?.isEmpty == false) ? command : nil
        self.patternKey = payload["pattern_key"]?.stringValue
        self.descriptionText = payload["description"]?.stringValue
        self.action = payload["action"]?.stringValue
        self.target = payload["target"]?.stringValue
        // Real content first: an explicit title (rare), then the F2-enrichment
        // `approval_title`, then the command itself, then a generic fallback.
        self.title = payload["title"]?.stringValue
            ?? payload["approval_title"]?.stringValue
            ?? self.command
            ?? payload["target"]?.stringValue
            ?? "Approval required"
    }
}

/// Payload of `clarify.request`.
struct ClarifyRequestPayload: Sendable, Equatable {
    let question: String
    let choices: [String]
    /// The id `clarify.respond` MUST echo back. The gateway's blocking-prompt
    /// factory injects `request_id` into every clarify frame (`_block`,
    /// `tui_gateway/server.py`) and `clarify.respond` routes the answer by
    /// looking it up in `_pending[request_id]` (the generic `_respond`,
    /// server.py). Without it the reply 4009s ("no pending clarify
    /// request") and the agent hangs — so this is required for a working reply,
    /// even though the in-chat banner does not display it.
    let requestId: String?

    init(payload: JSONValue) {
        self.question = payload["question"]?.stringValue ?? "The agent needs input"
        self.choices = payload["choices"]?.arrayValue?.compactMap(\.stringValue) ?? []
        let rid = payload["request_id"]?.stringValue
        self.requestId = (rid?.isEmpty == false) ? rid : nil
    }
}

/// One record from `GET <prefix>/approvals/pending` — the full stored entry from
/// the server's pending store (`approvals_pending.jsonl`). This is the catch-up
/// surface: when the app misses a live `approval.request`/`clarify.request`
/// broadcast (iOS suspended it in the background), it re-fetches the pending set
/// on reconnect and merges it into the inbox.
///
/// Decoded TOLERANTLY from a raw `JSONValue` rather than via strict `Codable`:
/// only `kind`, `approval_id`, and `session_id` are required; every other field
/// is optional and unknown/extra keys (`op`, `origin_pid`, future additions) are
/// ignored. The field names line up with the WS payloads, so `payload` is the
/// raw record (with `id` injected = `approval_id`) fed straight through the
/// existing ``ApprovalRequestPayload``/``ClarifyRequestPayload`` parsers.
struct PendingPrompt: Sendable, Equatable, Identifiable {
    enum Kind: String, Sendable { case approval, clarify }

    /// `approval_id` — stable identity + dedup key against the live WS path.
    let id: String
    let kind: Kind
    /// Runtime session id — the `session_id` echoed back to respond.
    let sessionId: String
    let storedSessionId: String?
    let createdAt: Double?
    let ttl: Int?
    /// The raw record as an object, with `id` set to `approval_id`, ready for the
    /// shared payload parsers.
    let payload: JSONValue

    /// Parse one record. Returns `nil` when a required field is missing or `kind`
    /// is unrecognized, so a malformed/garbage line is skipped, not fatal.
    init?(record: JSONValue) {
        guard
            let kindRaw = record["kind"]?.stringValue,
            let kind = Kind(rawValue: kindRaw),
            let approvalId = record["approval_id"]?.stringValue, !approvalId.isEmpty,
            let sessionId = record["session_id"]?.stringValue, !sessionId.isEmpty
        else { return nil }
        self.id = approvalId
        self.kind = kind
        self.sessionId = sessionId
        let stored = record["stored_session_id"]?.stringValue
        self.storedSessionId = (stored?.isEmpty == false) ? stored : nil
        self.createdAt = record["created_at"]?.doubleValue
        self.ttl = record["ttl"]?.intValue
        // Inject `id` (= approval_id) so the approval parser keys identity off it
        // instead of synthesizing a UUID; harmless for clarify (keyed by session).
        var object = record.objectValue ?? [:]
        object["id"] = .string(approvalId)
        self.payload = .object(object)
    }
}

// MARK: - REST

/// `GET /api/status` response (subset the app cares about).
struct ServerStatus: Decodable, Sendable {
    let version: String?
    let hermesHome: String?
    let gatewayRunning: Bool?
    let activeSessions: Int?
    let authRequired: Bool?
}

/// `POST /api/upload` response (added on the hermes-mobile branch).
struct UploadResult: Decodable, Sendable {
    let path: String
}

// MARK: - Subagent delegation (F4A-A2)

/// Decoded payload of a `subagent.*` event (start / thinking / tool / progress /
/// complete). The gateway emits these from `_on_tool_progress`
/// (server.py); every key is optional on the wire (older emitters omit the
/// identity fields and fall back to flat rendering), so each field here is
/// optional and parsed defensively from the raw `JSONValue` payload — never a
/// hard `Decodable` that would fail the whole frame on a missing key.
struct SubagentEventPayload: Sendable, Equatable {
    // Identity / tree-correlation keys.
    /// Stable id of this subagent branch (`subagent_id`). Falls back to a
    /// synthesized key when absent so a flat (id-less) emitter still renders one
    /// row per `task_index`.
    let subagentId: String?
    /// Parent subagent id (`parent_id`); `nil` ⇒ a top-level branch off the
    /// main turn.
    let parentId: String?
    /// Tree depth (`depth`); `nil` ⇒ treat as 0.
    let depth: Int?
    /// 0-based position of this branch among its siblings (`task_index`).
    let taskIndex: Int?
    /// Total sibling count for the spawning batch (`task_count`).
    let taskCount: Int?

    // Descriptive keys.
    /// The branch's goal (`goal`); also surfaced as `preview` on start.
    let goal: String?
    /// Model the branch runs on (`model`).
    let model: String?
    /// Free-text preview line (`text`) — the running thought / tool preview.
    let text: String?
    /// Tool name on a `subagent.tool` frame (`tool_name`).
    let toolName: String?
    /// One-line tool preview on a `subagent.tool` frame (`tool_preview`).
    let toolPreview: String?

    // Completion rollups (only present on `subagent.complete`).
    /// Terminal status: `nil` while running; `"completed"` / `"timeout"` /
    /// `"error"` on completion.
    let status: String?
    /// Human summary on completion (`summary`, ≤500 chars).
    let summary: String?
    /// Wall-clock seconds the branch ran (`duration_seconds`).
    let durationSeconds: Double?
    let inputTokens: Int?
    let outputTokens: Int?
    let reasoningTokens: Int?
    let apiCalls: Int?
    let costUsd: Double?
    let filesRead: [String]?
    let filesWritten: [String]?

    init(payload: JSONValue) {
        subagentId = payload["subagent_id"]?.stringValue
        parentId = payload["parent_id"]?.stringValue
        depth = payload["depth"]?.intValue
        taskIndex = payload["task_index"]?.intValue
        taskCount = payload["task_count"]?.intValue
        goal = payload["goal"]?.stringValue
        model = payload["model"]?.stringValue
        text = payload["text"]?.stringValue
        toolName = payload["tool_name"]?.stringValue
        toolPreview = payload["tool_preview"]?.stringValue
        status = payload["status"]?.stringValue
        summary = payload["summary"]?.stringValue
        durationSeconds = payload["duration_seconds"]?.doubleValue
        inputTokens = payload["input_tokens"]?.intValue
        outputTokens = payload["output_tokens"]?.intValue
        reasoningTokens = payload["reasoning_tokens"]?.intValue
        apiCalls = payload["api_calls"]?.intValue
        costUsd = payload["cost_usd"]?.doubleValue
        filesRead = payload["files_read"]?.arrayValue?.compactMap(\.stringValue)
        filesWritten = payload["files_written"]?.arrayValue?.compactMap(\.stringValue)
    }
}

/// A node in the subagent delegation tree, assembled by `ChatStore` from the
/// stream of `subagent.*` events. One node per branch (keyed by `subagent_id`,
/// or by `parentId|taskIndex` for id-less emitters). Children are ordered by
/// `taskIndex`. Pure value type so the view renders it without touching the
/// store's mutable assembly state.
struct SubagentNode: Sendable, Equatable, Identifiable {
    enum Status: String, Sendable, Equatable {
        case running
        case completed
        case timeout
        case error

        /// Map a `subagent.complete` `status` string to a terminal state.
        /// `failed` and `interrupted` are non-success terminal outcomes and
        /// must surface as `.error`, not be silently shown as completed.
        init(completionStatus raw: String?) {
            switch raw {
            case "timeout": self = .timeout
            case "error", "failed", "interrupted", "cancelled", "canceled":
                self = .error
            default: self = .completed
            }
        }
    }

    /// Stable identity used both as the dictionary key and the SwiftUI id.
    let id: String
    /// Parent node id, or `nil` for a top-level branch.
    var parentId: String?
    var depth: Int
    var taskIndex: Int
    var taskCount: Int
    var goal: String
    var model: String?
    /// The latest activity line (running thought / tool preview).
    var activity: String
    var status: Status
    // Completion rollups (zeroed until `subagent.complete` lands).
    var summary: String?
    var durationSeconds: Double?
    var inputTokens: Int?
    var outputTokens: Int?
    var reasoningTokens: Int?
    var apiCalls: Int?
    var costUsd: Double?
    var filesRead: [String]
    var filesWritten: [String]
    /// Child node ids, kept ordered by `taskIndex` for stable rendering.
    var childIds: [String]
}

// MARK: - Secure prompts (F4A-A2)

/// Payload of a `sudo.request` event (server.py). The gateway emits an
/// empty dict plus an injected `request_id`; there is no prompt text, so the UI
/// supplies a fixed "enter your sudo password" label. `request_id` is the
/// 8-hex correlation key the `sudo.respond` reply must echo back.
struct SudoRequestPayload: Sendable, Equatable {
    let requestId: String

    /// Returns `nil` when the frame carries no `request_id` — a malformed sudo
    /// request that must not present a prompt (there would be nothing to reply
    /// to). Real gateway frames always inject one (`_block`, server.py).
    init?(payload: JSONValue) {
        guard let rid = payload["request_id"]?.stringValue, !rid.isEmpty else { return nil }
        self.requestId = rid
    }
}

/// Payload of a `secret.request` event (server.py). Carries the prompt
/// text, the target env-var name, the 8-hex `request_id`, and an OPTIONAL
/// opaque `metadata` dict the originating skill passed through. The gateway
/// forwards `metadata` verbatim (`if metadata:`) and guarantees NO specific
/// keys, so it is decoded best-effort as `[String: String]` display hints and
/// never depended upon.
///

/// SECRET HYGIENE: this struct decodes only the PROMPT side of the exchange
/// (what to ask for). It NEVER holds, logs, or persists the entered value —
/// that lives only in a transient `@State` in `SecurePromptView` and is cleared
/// the instant the reply is sent or the prompt is dismissed.
struct SecretRequestPayload: Sendable, Equatable {
    let requestId: String
    /// Human prompt shown above the field (e.g. "Enter your OpenAI API key").
    let prompt: String
    /// The env-var the value is stored as (e.g. `OPENAI_API_KEY`) — shown as a
    /// monospaced subtitle so the user knows what they are entering.
    let envVar: String?
    /// Opaque display hints from the skill. Treated as best-effort string→string;
    /// non-string metadata values are dropped. Never load-bearing.
    let metadata: [String: String]

    init?(payload: JSONValue) {
        guard let rid = payload["request_id"]?.stringValue, !rid.isEmpty else { return nil }
        self.requestId = rid
        self.prompt = payload["prompt"]?.stringValue ?? "Enter the requested secret"
        self.envVar = payload["env_var"]?.stringValue
        var hints: [String: String] = [:]
        if let object = payload["metadata"]?.objectValue {
            for (key, value) in object {
                if let string = value.stringValue { hints[key] = string }
            }
        }
        self.metadata = hints
    }
}

/// A transient secure prompt (sudo password / secret value) the user must
/// answer (F4A-A2). Carries ONLY the request side — what to ask, which
/// `request_id` to reply on, and which session it belongs to. It NEVER carries
/// the entered value: that lives solely in the `SecurePromptView` `@State` and
/// is cleared the instant the reply is sent or the prompt is dismissed.
///

/// Deliberately NOT `Snapshotable` and not routed to ``InboxStore`` — the debug
/// bridge may read the prompt KIND (to assert a prompt is active) but never a
/// value, and the prompt must not persist anywhere.
struct PendingSecurePrompt: Sendable, Equatable, Identifiable {
    enum Kind: String, Sendable, Equatable {
        case sudo
        case secret
    }

    /// Stable identity for SwiftUI `.sheet(item:)` — the request id is unique per
    /// pending request.
    var id: String { requestId }
    let kind: Kind
    /// The 8-hex `request_id` the `*.respond` reply must echo back.
    let requestId: String
    /// The runtime session the request came from (the reply targets this session
    /// implicitly via `request_id`; kept for completeness / future routing).
    let sessionId: String
    /// Human prompt shown above the masked field.
    let prompt: String
    /// For `secret`: the env-var the value is stored as (e.g. `OPENAI_API_KEY`),
    /// shown as a monospaced subtitle. `nil` for `sudo`.
    let envVar: String?
    /// Opaque best-effort display hints (see ``SecretRequestPayload``). Never
    /// load-bearing; empty for `sudo`.
    let metadata: [String: String]
}

// MARK: - Todo tool (F4A-A2)

/// One item in a `todo` tool's result list. The gateway's todo tool
/// (`tools/todo_tool.py`) returns `{"todos": [{id, content, status}], summary}`
/// as the `tool.complete` `result`; `status` is one of
/// `pending|in_progress|completed|cancelled` (`VALID_STATUSES`).
struct TodoItem: Sendable, Equatable, Identifiable {
    enum Status: String, Sendable, Equatable {
        case pending
        case inProgress = "in_progress"
        case completed
        case cancelled
        /// Anything the server adds later renders as a neutral pending-style row.
        case other

        init(raw: String) {
            self = Status(rawValue: raw) ?? .other
        }
    }

    let id: String
    let content: String
    let status: Status
}

/// Structured view over a `todo` tool's `tool.complete` result. Derived (not a
/// stored model field) from `ToolActivity.resultPreview` / the result JSON — no
/// new event and no new `ChatMessage` field, per the spec. Returns `nil`
/// for a non-todo tool or an unparseable result so the caller falls back to the
/// generic tool row.
struct TodoList: Sendable, Equatable {
    let items: [TodoItem]

    /// The exact wire name of the gateway's todo/checklist tool
    /// (`tools/todo_tool.py`, `server.py if name == "todo"`).
    static let toolName = "todo"

    /// Parse a todo result JSON string (the tool's `result`) into a list.
    /// Returns `nil` when the text is not the expected `{"todos": [...]}` shape.
    init?(resultJSON text: String) {
        guard text.hasPrefix("{"),
              let data = text.data(using: .utf8),
              let json = try? JSONDecoder().decode(JSONValue.self, from: data),
              let todos = json["todos"]?.arrayValue
        else { return nil }
        self.init(todosArray: todos)
    }

    /// Parse from an already-decoded `todos` array (used when the result is held
    /// as a structured `JSONValue` rather than a string).
    init?(todosArray: [JSONValue]) {
        let parsed: [TodoItem] = todosArray.compactMap { entry in
            guard let object = entry.objectValue else { return nil }
            let content = object["content"]?.stringValue ?? ""
            guard !content.isEmpty else { return nil }
            let id = object["id"]?.stringValue ?? content
            let status = TodoItem.Status(raw: object["status"]?.stringValue ?? "pending")
            return TodoItem(id: id, content: content, status: status)
        }
        guard !parsed.isEmpty else { return nil }
        self.items = parsed
    }
}
