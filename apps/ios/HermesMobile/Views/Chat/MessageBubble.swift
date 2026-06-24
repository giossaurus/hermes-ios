import SwiftUI

/// A single transcript entry.
///

/// - User: a trailing-aligned bronze bubble, capped at 78% width.
/// - Assistant: a leading-aligned, bubble-less "document" — optional thinking,
///  a tool timeline, then markdown-rendered text with a streaming cursor.
/// - System / tool: small, centered, secondary captions.
struct MessageBubble: View {
    @Environment(\.hermesTheme) private var theme

    /// The message to render.
    let message: ChatMessage

    // MARK: - CC-01: Streaming cursor pulse animation state
    /// Opacity driven by a repeating breathe animation while the turn streams.
    @State private var cursorPulseOpacity: Double = 1.0

    // MARK: - CC-02: Copy confirmation state (assistant message copy)
    /// Whether the assistant-message copy just fired — drives checkmark + haptic.
    @State private var didCopyMessage = false
    /// Trigger sentinel for `.sensoryFeedback` — toggled on every copy.
    @State private var copyHapticTrigger = false

    // A1: action closures are `let` (immutable inputs). They are NOT read by the
    // `nonisolated ==` (closures aren't Sendable); only their nil-ness affects what
    // renders, and that is stable per call site (ChatView passes the same handlers
    // every render), so omitting them from `==` never strands a real update.
    /// Invoked when the user chooses "Edit" on their own bubble. The host
    /// (`ChatView`) presents an edit sheet and calls `ChatStore.editAndResend`.
    /// `nil` (default) hides the Edit action — used in previews / pre-wiring.
    let onEdit: ((ChatMessage) -> Void)?
    /// Invoked when the user chooses "Retry" on an assistant message. The host
    /// calls `ChatStore.retry(fromAssistantId:)`. `nil` hides the action.
    let onRetry: ((ChatMessage) -> Void)?
    /// Invoked when the user chooses "Speak" on an assistant message. Wiring to
    /// the speech player happens later; `nil` hides the action.
    let onSpeak: ((ChatMessage) -> Void)?
    /// Invoked when the user chooses "Restore checkpoint" on their own bubble
    /// (F4A-A2): re-run the conversation from this user message, dropping later
    /// turns. The host calls `ChatStore.restoreCheckpoint(toUserMessageId:)`.
    /// `nil` hides the action.
    let onRestoreCheckpoint: ((ChatMessage) -> Void)?
    /// Invoked when the user chooses "Branch from here" on any message (F4A-A2):
    /// open a NEW chat seeded with history up to this message. The host calls
    /// `ChatStore.branchSeed(upToMessageId:)` + `SessionStore.branchSession`.
    /// `nil` hides the action.
    let onBranch: ((ChatMessage) -> Void)?
    /// Whether mutable context-menu actions (Edit, Restore checkpoint, Branch from
    /// here, Retry) are currently executable. When `false` the actions are SHOWN
    /// but disabled. Read by `==` (a Sendable `let`), so a change re-renders.
    let menuActionsEnabled: Bool

    /// Appearance identity (theme + Dynamic Type), folded into `Equatable` (A1) so
    /// a theme/type-size switch re-renders the bubble even though `.equatable()`
    /// short-circuits content-equal updates. The bubble reads the theme via
    /// `@Environment`, which the static `==` cannot observe — so it travels here as
    /// a value, supplied by `ChatView`. Defaults keep previews / standalone call
    /// sites compiling unchanged.
    let appearance: BubbleAppearance

    /// Explicit memberwise init so every comparison input can be an immutable
    /// `Sendable` `let` (required for the `nonisolated ==` under Swift 6 strict
    /// concurrency — a `View` is main-actor-isolated, so `Equatable.==` may only
    /// read immutable Sendable storage) while keeping the prior call-site defaults.
    init(
        message: ChatMessage,
        onEdit: ((ChatMessage) -> Void)? = nil,
        onRetry: ((ChatMessage) -> Void)? = nil,
        onSpeak: ((ChatMessage) -> Void)? = nil,
        onRestoreCheckpoint: ((ChatMessage) -> Void)? = nil,
        onBranch: ((ChatMessage) -> Void)? = nil,
        menuActionsEnabled: Bool = true,
        appearance: BubbleAppearance = BubbleAppearance()
    ) {
        self.message = message
        self.onEdit = onEdit
        self.onRetry = onRetry
        self.onSpeak = onSpeak
        self.onRestoreCheckpoint = onRestoreCheckpoint
        self.onBranch = onBranch
        self.menuActionsEnabled = menuActionsEnabled
        self.appearance = appearance
    }

    var body: some View {
        if case .collapsed(let label) = message.presentation {
            collapsedRow(label: label)
        } else {
            switch message.role {
            case .user:
                userBubble
                    .contextMenu { userMenu }
            case .assistant:
                assistantBody
                    .contextMenu { assistantMenu }
            case .system, .tool:
                metaRow
            }
        }
    }

    // MARK: - Context menus

    @ViewBuilder
    private var userMenu: some View {
        if let onEdit {
            Button {
                onEdit(message)
            } label: {
                Label("Edit", systemImage: "pencil")
            }
            .disabled(!menuActionsEnabled)
        }
        Button {
            copyToPasteboard(message.text)
        } label: {
            Label("Copy", systemImage: "doc.on.doc")
        }
        if onRestoreCheckpoint != nil || onBranch != nil {
            Divider()
        }
        if let onRestoreCheckpoint {
            Button {
                onRestoreCheckpoint(message)
            } label: {
                Label("Restore checkpoint", systemImage: "clock.arrow.circlepath")
            }
            .disabled(!menuActionsEnabled)
        }
        if let onBranch {
            Button {
                onBranch(message)
            } label: {
                Label("Branch from here", systemImage: "arrow.triangle.branch")
            }
            .disabled(!menuActionsEnabled)
        }
    }

    @ViewBuilder
    private var assistantMenu: some View {
        if let onRetry {
            Button {
                onRetry(message)
            } label: {
                Label("Retry", systemImage: "arrow.clockwise")
            }
            .disabled(!menuActionsEnabled)
        }
        Button {
            copyAssistantMessage()
        } label: {
            Label("Copy", systemImage: "doc.on.doc")
        }
        if let onSpeak {
            Button {
                onSpeak(message)
            } label: {
                Label("Speak", systemImage: "speaker.wave.2")
            }
        }
        if let onBranch {
            Divider()
            Button {
                onBranch(message)
            } label: {
                Label("Branch from here", systemImage: "arrow.triangle.branch")
            }
            .disabled(!menuActionsEnabled)
        }
    }

    // MARK: - Pasteboard

    /// Copy to pasteboard with no visual feedback (user bubble context menu).
    private func copyToPasteboard(_ text: String) {
        UIPasteboard.general.string = text
    }

    /// Copy to pasteboard with checkmark confirmation + haptic (assistant action
    /// row and context menu — CC-02). Mirrors CodeBlockView.copy() exactly so
    /// every copy surface in the transcript behaves consistently.
    private func copyAssistantMessage() {
        UIPasteboard.general.string = message.text
        copyHapticTrigger.toggle()
        withAnimation(.snappy) { didCopyMessage = true }
        Task {
            try? await Task.sleep(for: .seconds(1.6))
            withAnimation(.snappy) { didCopyMessage = false }
        }
    }

    // MARK: - Collapsed scaffolding (cron preambles, tool dumps, system prompts)

    @State private var isExpanded = false

    private func collapsedRow(label: String) -> some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            ScrollView {
                Text(message.text)
                    .font(.caption2.monospaced())
                    .foregroundStyle(theme.mutedFg)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 260)
            .padding(8)
            .background(theme.muted, in: RoundedRectangle(cornerRadius: 8))
        } label: {
            Label(label, systemImage: iconForCollapsedRole)
                .font(.caption)
                .foregroundStyle(theme.mutedFg)
        }
        .tint(theme.mutedFg)
    }

    private var iconForCollapsedRole: String {
        switch message.role {
        case .tool: return "wrench.and.screwdriver"
        case .system: return "gearshape"
        default: return "clock.arrow.circlepath"
        }
    }

    // MARK: - User

    /// Whether the long user message is expanded (ephemeral, per-message-instance).
    @State private var userBubbleExpanded = false

    private var userBubble: some View {
        HStack {
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: 0) {
                Text(message.text)
                    .foregroundStyle(theme.userBubble.contrastingForeground)
                    .lineLimit(userBubbleExpanded ? nil : Self.userBubbleCollapsedLines)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .textSelection(.enabled)
                if shouldShowReadMore {
                    Button {
                        userBubbleExpanded.toggle()
                    } label: {
                        Text(userBubbleExpanded ? "Show less" : "Read more")
                            .font(.caption)
                            .foregroundStyle(theme.userBubble.contrastingForeground.opacity(0.75))
                            .padding(.horizontal, 14)
                            .padding(.bottom, 9)
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Double-tap to \(userBubbleExpanded ? "collapse message" : "expand message")")
                }
            }
            .modifier(PerfUserBubbleChrome())
            .frame(maxWidth: maxBubbleWidth, alignment: .trailing)
        }
    }

    /// Whether the "Read more" / "Show less" toggle should appear for this message.
    /// Long enough means above the collapse threshold (approximately 8 lines of
    /// prose). We estimate using character count to avoid a layout pass.
    var shouldShowReadMore: Bool {
        Self.isLongUserMessage(message.text)
    }

    /// Returns true when the message text is long enough to warrant the collapse
    /// toggle. Extracted as a static testable function so unit tests can cover the
    /// threshold logic without a live View.
    static func isLongUserMessage(_ text: String) -> Bool {
        // ~8 lines at ~45 chars per line on a compact device = ~360 chars.
        // We also count newlines directly: 8+ newlines means multi-paragraph.
        let lineBreaks = text.filter { $0.isNewline }.count
        return text.count > Self.userBubbleCollapsedCharThreshold || lineBreaks >= Self.userBubbleCollapsedLines
    }

    /// Character-count threshold above which a user bubble gets the Read More
    /// toggle. ~8 lines × ~45 characters per line on a 375pt wide device.
    static let userBubbleCollapsedCharThreshold = 360
    /// Maximum number of lines shown in collapsed state; also the newline-count
    /// threshold for the `isLongUserMessage` heuristic.
    static let userBubbleCollapsedLines = 8

    /// Cap user bubbles at 78% of the screen width while letting short messages
    /// hug their content.
    private var maxBubbleWidth: CGFloat {
        UIScreen.main.bounds.width * 0.78
    }

    // MARK: - Assistant

    private var assistantBody: some View {
        // `parts` is the sole content source of truth — render it
        // directly in wire order, no `assistantRenderParts` indirection.
        let parts = message.parts
        let lastTextPartID = parts.lastTextPartID
        // A freshly-created streaming bubble has no `.text` part yet; show a
        // standalone cursor so the turn reads as in-progress (the prior model
        // injected an empty streaming text placeholder for this).
        let needsStandaloneCursor = message.isStreaming && lastTextPartID == nil

        // CC-05/CC-07: bump part spacing from 8 → 10 for consistent vertical
        // rhythm that matches the user bubble's ~9pt vertical breathing room.
        return VStack(alignment: .leading, spacing: 10) {
            ForEach(parts) { part in
                assistantPart(part, showsCursor: message.isStreaming && part.id == lastTextPartID)
            }
            if needsStandaloneCursor {
                // CC-01: standalone cursor inherits the pulse animation.
                cursorView
                    .font(.body)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            // Action row under each COMPLETED assistant turn (F3): thin line
            // icons, no backgrounds. Hidden while streaming and on empty turns so
            // a tool-only / in-progress turn shows no dangling actions.
            //

            // §3.5 (D10): visibility keys on RENDERED TEXT PRESENCE — a non-empty
            // `.text` PART — via the derived `hasRenderedText`, not any legacy
            // scalar. Because Copy/Share read `message.text` (the ordered concat of
            // the same `.text` parts, Batch A) the copied string is exactly the
            // displayed prose; on a parts-only turn the row is therefore present
            // and correct by construction.
            if !message.isStreaming && hasRenderedText {
                assistantActionRow
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // CC-02: haptic fires once per copy trigger toggle (success feel).
        .sensoryFeedback(.success, trigger: copyHapticTrigger)
    }

    /// True iff this turn has at least one non-empty `.text` part — the rendered
    /// prose presence the action row keys on (§3.5). Equivalent to
    /// `!message.text.isEmpty` since the derived `text` is the concat of these
    /// parts, but stated against `parts` to make the part-keyed contract explicit.
    private var hasRenderedText: Bool {
        message.parts.contains { part in
            if case .text(_, let t) = part { return !t.isEmpty }
            return false
        }
    }

    @ViewBuilder
    private func assistantPart(_ part: ChatMessagePart, showsCursor: Bool) -> some View {
        switch part {
        case .reasoning(_, let text):
            if !text.isEmpty {
                // Wire-position thinking (§3.3): the accordion renders exactly
                // where this `.reasoning` part sits in `parts` (never hoisted to
                // the top) and auto-opens while the turn streams, collapsing when
                // it settles. `message.isStreaming` drives that default.
                ThinkingView(thinking: text, streaming: message.isStreaming)
            }
        case .tools(_, let tools, let collapsed, let turnElapsed):
            if !tools.isEmpty {
                ToolClusterView(
                    tools: tools,
                    collapsed: collapsed,
                    turnElapsed: turnElapsed
                )
            }
        case .text(_, let text):
            if !text.isEmpty || showsCursor {
                assistantText(text, showsCursor: showsCursor)
            }
        case .warning(_, let text):
            if !text.isEmpty {
                Label(text, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .foregroundStyle(theme.statusWarn)
            }
        case .usage(_, let stats):
            usageFooter(stats)
        }
    }

    /// Render the assistant text as ordered prose / code segments (E3 segmenter):
    /// prose runs become inline-markdown `Text`, fenced code becomes a
    /// `CodeBlockView`. The streaming cursor rides the last prose segment — or
    /// stands alone when the streaming tail is a code block, so the code card
    /// never gets a stray glyph.
    private func assistantText(_ text: String, showsCursor: Bool) -> some View {
        // Memoized segmentation (RenderCache): a flick-scroll re-realizes this
        // row without changing `text`, so the segment scan is an O(1) cache hit
        // instead of an O(n) re-scan of the whole body. A streaming flush extends
        // `text` → new key → fresh scan only for the genuinely-new content.
        let segments = RenderCache.segments(text)

        return VStack(alignment: .leading, spacing: Self.segmentSpacing) {
            // POSITIONAL identity (release audit P1): keying on `\.element.id`
            // (a content hash) gave every streaming delta a NEW id — ForEach
            // tore down and rebuilt the prose Text on every flush, breaking
            // in-progress text selection. Segments are append-only during a
            // stream, so the offset is the stable identity and SwiftUI diffs
            // the text in place.
            ForEach(Array(segments.enumerated()), id: \.offset) { index, segment in
                switch segment {
                case .prose(let body):
                    // Serif applies ONLY to prose segments (F3 / Amendment E) —
                    // never code (`CodeBlockView`, mono) nor the streaming cursor
                    // (its own `Text` keeps the system face).
                    //

                    // CC-01 / round-2 ROOT D: the streaming cursor is NO LONGER an
                    // animated `.opacity` on this prose `Text`. Previously the
                    // riding-cursor case wrapped the (large, growing) prose block in
                    // `.opacity(0.65 + cursorPulseOpacity*0.35)` driven by a 0.6s
                    // `.repeatForever` animation — forcing SwiftUI to re-composite
                    // the entire prose Text on every pulse frame AND on every flush.
                    // The pulse is now lifted onto a SEPARATE standalone cursor
                    // sibling (`cursorView`, appended after the segment stack
                    // below), so this prose `Text` is static: it renders at full
                    // opacity, carries no animation, and its `RenderCache`-memoized
                    // AttributedString is composited once per text value.
                    (Text(RenderCache.prose(body)).font(Self.proseFont))
                        .foregroundStyle(theme.fg)
                        .lineSpacing(Self.proseLineSpacing)
                        .perfTextSelection()
                        .frame(maxWidth: .infinity, alignment: .leading)
                case .code(let language, let body):
                    CodeBlockView(language: language, code: body)
                }
            }
            // CC-01 / round-2: the breathing streaming cursor is a single
            // standalone sibling for ALL cases (rides prose, tail-is-code, or
            // no-prose-yet). Keeping it OFF the prose `Text` means the pulse
            // animation never re-composites the (large) prose block — only this
            // tiny glyph view animates. It sits just after the segment stack,
            // reading as the live tail of the turn.
            if showsCursor {
                cursorView
                    .font(.body)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Spacing between prose / code segments (UI-C C1 paragraph spacing).
    private static let segmentSpacing: CGFloat = 12
    /// Extra leading between wrapped prose lines (UI-C C1).
    private static let proseLineSpacing: CGFloat = 3.5
    /// The assistant prose face: serif at body size (F3 / Amendment E — observed
    /// reference: "Assistant text is full-width serif"). Code + cursor keep the
    /// system face.
    private static let proseFont: Font = .system(.body, design: .serif)

    // MARK: - CC-01: Streaming cursor

    /// A standalone animated cursor view — the single breathing cursor glyph for
    /// the streaming tail (round-2 ROOT D: lifted off the prose `Text` so the
    /// pulse never re-composites the prose block). Starts/stops the pulse
    /// animation in sync with `message.isStreaming`.
    private var cursorView: some View {
        Text(" ▌")
            .foregroundColor(theme.midground)
            .opacity(message.isStreaming ? cursorPulseOpacity : 1.0)
            .onAppear {
                guard message.isStreaming else { return }
                startCursorPulse()
            }
            .onChange(of: message.isStreaming) { _, streaming in
                if streaming {
                    startCursorPulse()
                } else {
                    // Turn complete: snap back to full opacity.
                    withAnimation(.easeOut(duration: 0.15)) {
                        cursorPulseOpacity = 1.0
                    }
                }
            }
    }

    /// Kick off the repeating breathe animation for the streaming cursor.
    private func startCursorPulse() {
        withAnimation(
            .easeInOut(duration: 0.6)
            .repeatForever(autoreverses: true)
        ) {
            cursorPulseOpacity = 0.25
        }
    }

    private func usageFooter(_ usage: UsageStats) -> some View {
        Text(Self.usageLine(usage))
            .font(.caption2)
            .foregroundStyle(theme.mutedFg)
            .padding(.top, 2)
    }

    // MARK: - Assistant action row (F3)

    /// Thin line-icon action row under a completed assistant turn: copy, share,
    /// speak (existing `onSpeak`), retry (existing `onRetry`). 16pt glyphs,
    /// `theme.mutedFg`, 20pt spacing, no backgrounds (observed reference). Speak
    /// and retry render only when their hook is supplied (mirrors the context
    /// menu's existing gating); copy + share are always available.
    ///

    /// CC-02: copy button shows a checkmark confirmation (+ haptic) matching
    /// CodeBlockView's copy UX so every copy surface in the transcript is consistent.
    /// CC-07: top padding raised from 4 → 8 for better separation from prose.
    private var assistantActionRow: some View {
        HStack(spacing: 20) {
            // CC-02: confirm copy with checkmark + color change (mirrors CodeBlockView).
            Button {
                copyAssistantMessage()
            } label: {
                Image(systemName: didCopyMessage ? "checkmark" : "doc.on.doc")
                    .font(.body)
                    .foregroundStyle(didCopyMessage ? theme.statusOK : theme.mutedFg)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(didCopyMessage ? "Copied to clipboard" : "Copy")

            ShareLink(item: message.text) {
                Image(systemName: "square.and.arrow.up")
                    .font(.body)
                    .foregroundStyle(theme.mutedFg)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Share")
            if let onSpeak {
                actionIcon("speaker.wave.2", label: "Speak") {
                    onSpeak(message)
                }
            }
            if let onRetry {
                actionIcon("arrow.counterclockwise", label: "Retry") {
                    onRetry(message)
                }
            }
            Spacer(minLength: 0)
        }
        // CC-07: 8pt top gap gives the action row clear breathing room from prose.
        .padding(.top, 8)
    }

    /// One thin line-icon action button (no background).
    private func actionIcon(_ systemName: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.body)
                .foregroundStyle(theme.mutedFg)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    // MARK: - System / tool

    private var metaRow: some View {
        Text(message.text)
            .font(.caption2)
            .foregroundStyle(theme.mutedFg)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity, alignment: .center)
    }

    // MARK: - Formatting

    /// Render markdown inline, preserving whitespace, falling back to plain text.
    static func attributed(_ text: String) -> AttributedString {
        (try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(text)
    }

    // MARK: - Prose list rendering (UI-C C1)

    /// Hanging indent applied to detected list lines: the first line starts at
    /// the margin (the marker sits at 0) and wrapped continuation lines indent
    /// so they align under the text after the marker.
    private static let listFirstLineHeadIndent: CGFloat = 0
    private static let listHeadIndent: CGFloat = 18

    /// Build the prose attributed string for a segment, detecting markdown
    /// ordered/unordered list lines and giving them a hanging indent so wrapped
    /// continuations align under the item text. Ordinals are monospaced-digit so
    /// numbered lists stay column-aligned. Non-list prose keeps the existing
    /// inline-markdown rendering verbatim.
    static func prose(_ text: String) -> AttributedString {
        let lines = text.components(separatedBy: "\n")
        guard lines.contains(where: { listMarker($0) != nil }) else {
            return attributed(text)
        }

        var result = AttributedString()
        for (index, line) in lines.enumerated() {
            var lineAttr = attributed(line)
            if let marker = listMarker(line) {
                let paragraph = NSMutableParagraphStyle()
                paragraph.firstLineHeadIndent = listFirstLineHeadIndent
                paragraph.headIndent = listHeadIndent
                // Swift 6 warns here ("NSParagraphStyle: Sendable unavailable")
                // because AttributedString is Sendable and NSParagraphStyle is
                // not. The style is built and consumed locally (it never crosses
                // an isolation boundary), and the only alternative — bridging via
                // NSAttributedString — drops the markdown inline intents
                // (bold/italic), so this is left as an accepted framework limit.
                lineAttr.paragraphStyle = paragraph
                if marker == .ordered {
                    // Keep numbered ordinals column-aligned across items, in the
                    // serif prose face (F3) so list text matches surrounding prose.
                    lineAttr.font = .system(.body, design: .serif).monospacedDigit()
                }
            }
            result += lineAttr
            if index != lines.count - 1 {
                result += AttributedString("\n")
            }
        }
        return result
    }

    private enum ListMarker { case ordered, unordered }

    /// Classify a line as an ordered (`1.` / `1)`) or unordered (`- ` / `* ` /
    /// `+ `) list item, ignoring up to a few leading spaces. `nil` otherwise.
    private static func listMarker(_ line: String) -> ListMarker? {
        var scalars = Substring(line)
        // Allow modest leading indentation (nested lists / soft wraps).
        var leading = 0
        while let first = scalars.first, first == " ", leading < 6 {
            scalars = scalars.dropFirst()
            leading += 1
        }
        guard let first = scalars.first else { return nil }
        if first == "-" || first == "*" || first == "+" {
            let rest = scalars.dropFirst()
            if rest.first == " " { return .unordered }
            return nil
        }
        if first.isNumber {
            var digits = scalars
            while let d = digits.first, d.isNumber { digits = digits.dropFirst() }
            // A delimiter (. or)) followed by a space marks an ordered item.
            if let delim = digits.first, delim == "." || delim == ")" {
                let after = digits.dropFirst()
                if after.first == " " { return .ordered }
            }
        }
        return nil
    }

    /// "1,234 tokens · $0.0123 · ctx 142K" — omits the cost when absent and the
    /// "ctx N" clause when the turn's usage carried no context occupancy (H1).
    static func usageLine(_ usage: UsageStats) -> String {
        var parts: [String] = []
        if let total = usage.total ?? combinedTokens(usage) {
            parts.append("\(total) tokens")
        }
        if let cost = usage.costUsd {
            parts.append(String(format: "$%.4f", cost))
        }
        if let ctx = usage.contextUsed {
            parts.append("ctx \(UsageStats.formatK(ctx))")
        }
        return parts.joined(separator: " · ")
    }

    private static func combinedTokens(_ usage: UsageStats) -> Int? {
        guard usage.input != nil || usage.output != nil else { return nil }
        return (usage.input ?? 0) + (usage.output ?? 0)
    }
}

private extension Array where Element == ChatMessagePart {
    var lastTextPartID: String? {
        for part in reversed() {
            if case .text(let id, _) = part { return id }
        }
        return nil
    }
}

/// The user-bubble background + border chrome. Factored into a modifier so the
/// DEBUG conic-stroke hunt can strip it (`HERMES_EXP_NO_BUBBLE_BG`) and attribute
/// the per-frame angular-gradient render cost. Production = bg fill + stroke.
private struct PerfUserBubbleChrome: ViewModifier {
    @Environment(\.hermesTheme) private var theme

    func body(content: Content) -> some View {
        #if DEBUG
        if RenderCache.expNoBubbleBg {
            return AnyView(content)
        }
        #endif
        return AnyView(content
            .background(theme.userBubble, in: RoundedRectangle(cornerRadius: 18))
            .overlay(
                RoundedRectangle(cornerRadius: 18)
                    .strokeBorder(theme.userBubbleBorder, lineWidth: 1)
            ))
    }
}

// MARK: - A1: Equatable short-circuit (scarf RichMessageBubble pattern)

/// Appearance inputs that affect a bubble's render but reach `MessageBubble` via
/// `@Environment` (theme, color scheme, Dynamic Type). They are carried as a value
/// so the static `==` can compare them — otherwise `.equatable()` could skip the
/// body on a theme/scheme/type-size change and strand stale styling. `ChatView`
/// builds this from `\.hermesTheme.id` + `\.colorScheme` + `\.dynamicTypeSize`.
/// `themeID` catches theme switches; `colorScheme` catches an adaptive theme's
/// light↔dark flip (where the name is unchanged); `typeSize` catches Dynamic Type.
struct BubbleAppearance: Equatable, Sendable {
    var themeID: String = ""
    var colorScheme: ColorScheme = .dark
    var typeSize: DynamicTypeSize = .large
}

extension MessageBubble: Equatable {
    /// Two bubbles render identically iff their content (`message`), the menu-action
    /// gating, and the appearance token match. `nonisolated` is required under
    /// Swift 6 strict concurrency: `Equatable.==` is a nonisolated requirement but a
    /// `View` is main-actor-isolated, so the witness may only read immutable
    /// `Sendable` storage — all three reads below are `let`s of `Sendable` type.
    /// The action closures are intentionally excluded (not `Sendable`; their nil-ness
    /// is stable per call site), so they cannot strand a real update.
    nonisolated static func == (lhs: MessageBubble, rhs: MessageBubble) -> Bool {
        lhs.message == rhs.message
            && lhs.menuActionsEnabled == rhs.menuActionsEnabled
            && lhs.appearance == rhs.appearance
    }
}
