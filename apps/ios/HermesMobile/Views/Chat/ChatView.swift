import SwiftUI

/// The conversation surface: a scrolling transcript with auto-scroll, banners
/// for approvals / clarifications / errors pinned above a bottom composer.
///

/// Reads its stores from the environment (injected by `HermesMobileApp`).
struct ChatView: View {
    @Environment(ChatStore.self) private var chatStore
    @Environment(ConnectionStore.self) private var connectionStore
    @Environment(SessionStore.self) private var sessionStore
    @Environment(AttachmentStore.self) private var attachmentStore
    @Environment(InboxStore.self) private var inboxStore
    @Environment(ThemeStore.self) private var themeStore
    @Environment(\.hermesTheme) private var theme
    /// Drives the compact-vs-regular chrome split. Both widths now use the SAME
    /// system `.toolbar` (UI Batch I / I1 — full native): on iOS 26 the system
    /// renders the toolbar items as floating Liquid Glass automatically; on
    /// 17-25 it renders the classic nav bar — both correct, zero custom drawing.
    /// The only remaining split is the nav-bar BACKGROUND: regular (iPad) keeps
    /// its themed opaque bar; compact lets the system default the background so
    /// the full-bleed chat card (geometry fix) shows through beneath the chrome.
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    /// Folded into each `MessageBubble`'s `Equatable` value (A1) so a theme or
    /// Dynamic-Type change re-renders every bubble even though `.equatable()`
    /// short-circuits content-equal updates — `MessageBubble` reads the theme via
    /// `@Environment`, which the static `==` cannot see, so it travels as a value.
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    /// Paired with the theme id in each bubble's `Equatable` value (A1): catches an
    /// adaptive theme's light↔dark flip, where the theme name is unchanged.
    @Environment(\.colorScheme) private var colorScheme
    /// In-app UI locale (re-applied at every themed root). Threaded into the
    /// draft greeting so its `String(localized:)` phrase follows the in-app
    /// language switch — `String(localized:)` reads `Locale.current`, NOT the
    /// SwiftUI `\.locale`, so the resolved locale is passed explicitly.
    @Environment(\.locale) private var locale

    /// Optional hook invoked when the user chooses "Speak" on an assistant
    /// message. Wiring to the speech player happens during integration; nil
    /// (default) hides the Speak action.
    var onSpeak: ((ChatMessage) -> Void)?

    // MARK: - Drawer-nav seams (Batch B)
    //

    // These are injectable so this file compiles standalone and the integrator
    // wires the B1/B3 surfaces in without restructuring ChatView. Each has a
    // behaviour-preserving default (nil / false / store fallback), so the chat
    // surface behaves exactly as before until the drawer shell supplies them.

    /// Toggle the leading drawer (B1's `DrawerState.isOpen.toggle()`). When `nil`
    /// the leading drawer button is hidden (e.g. on iPad where the split view's
    /// own sidebar handles navigation).
    var onToggleDrawer: (() -> Void)?

    /// Start a fresh chat from the trailing pencil. The integrator passes
    /// `sessionStore.startDraft()` (B3). When `nil`, falls back to
    /// `SessionStore.startDraft()` so the button is never dead (interactive
    /// new-chat uses the draft path; `createSessionNow()` is programmatic-only).
    var onNewChat: (() -> Void)?

    /// Whether the session store is currently in draft (empty) mode (B3's
    /// `SessionStore.isDraft`). Drives the centred greeting instead of an empty
    /// transcript. Defaults to `false` → no behaviour change.
    var isDraft: Bool = false

    /// The active session's model short-name for the title chip, when the caller
    /// can supply it (the stores do not track it in v1 — see `activeModelName`).
    /// Tapping the chip presents the model picker.
    var modelName: String?

    /// STRIKE P0 fix: when `true`, this surface is hosted WITHOUT a wrapping
    /// `NavigationStack` (the compact card hosts `ChatView` directly in a ZStack —
    /// see `CompactLayout.chatStack`). The chat then renders its chrome as a
    /// FLOATING GLASS HEADER overlay (`compactFloatingHeader`) instead of a
    /// system `.toolbar`, and suppresses `.navigationTitle` / `.toolbar` (which
    /// require a stack ancestor and, critically, made that stack reserve its
    /// bar/safe-area inset region — the pixel-proven cause of the transcript
    /// staying inset top+bottom despite `.ignoresSafeArea`). On regular (iPad) the
    /// chat keeps its system `.toolbar` inside the split view's stack, so this is
    /// `false` there and nothing about the iPad arrangement changes.
    var compactStandaloneChrome: Bool = false

    /// STRIKE P0: the top safe-area inset (status-bar height) captured by
    /// `CompactLayout` BEFORE its card stack ignored the safe area. Because the
    /// stack now runs full-bleed (`.ignoresSafeArea()`), descendants here see a
    /// ZERO safe area, so `.safeAreaPadding(.top)` would collapse the floating
    /// header into the status bar. The header pads its top by this value instead.
    /// Only meaningful when `compactStandaloneChrome == true`.
    var compactTopInset: CGFloat = 0

    /// Whether the transcript is pinned to the bottom (drives the scroll-to-bottom
    /// pill visibility + the streaming auto-stick gate). SCROLL P0 rebuild: this is
    /// now derived from a MEASURED distance-from-bottom (the bottom-spacer's frame
    /// in the scroll coordinate space, `onScrollGeometryChange` style) rather than a
    /// lazy 1pt anchor's appear/disappear — the lazy anchor mis-fired (it is only
    /// laid out when near the tail), which both mis-drove the pill and let the old
    /// imperative scroll overshoot into a white void. A measured threshold is
    /// settle-correct: it reflects the REAL content geometry, not lazy-row luck.
    @State private var atBottom = true
    /// The MEASURED height of the floating composer card (the `bottomStack`),
    /// replacing the fixed `composerFloatInset` estimate as the resting clearance
    /// (desktop `--composer-measured-height` analog). Floors at `composerFloatInset`
    /// so the UX1 gate (≥120) holds and a pre-measurement frame never under-clears.
    @State private var composerHeight: CGFloat = ChatView.composerFloatInset
    /// The live software-keyboard height (0 at rest), observed explicitly via
    /// `KeyboardHeightReader`. Added to the transcript's bottom clearance so the
    /// content rises WITH the keyboard by construction — not by SwiftUI inferring a
    /// keyboard inset across the composer-overlay boundary (which it does NOT do
    /// deterministically, the device-confirmed "last message behind keyboard" bug).
    @State private var keyboardHeight: CGFloat = 0
    /// SMOOTHNESS R39 (Defect 2) — how many of the NEWEST messages the transcript
    /// renders EAGERLY (plain `VStack`, no lazy estimation). The tail window starts
    /// at `Self.transcriptWindow` and grows by `Self.transcriptWindow` each time the
    /// "Load earlier messages" chip is tapped. Messages beyond the window stay in
    /// `ChatStore` (full memory) — only VIEW construction is windowed, so the
    /// bottom-anchored `ScrollView` resolves "bottom" against EXACT (not estimated)
    /// row heights and never parks against a bad estimate. Reset to the base window
    /// on every per-session remount (the `.id` swap re-inits `@State`).
    @State private var windowSize: Int = ChatView.transcriptWindow
    /// The error currently shown in the toast, if any.
    @State private var toastError: String?
    /// Cancels the in-flight toast auto-dismiss when a new error arrives.
    @State private var toastDismissTask: Task<Void, Never>?

    // Dynamic-Type-scaled sizes (base values preserve the default-size layout;
    // grow with Larger Text). `@ScaledMetric` must be stored on the View struct.
    /// Inline nav-title text (non-empty transcript).
    @ScaledMetric(relativeTo: .subheadline) private var navTitleFontSize: CGFloat = 15
    /// Scroll-to-bottom pill ↓ glyph (both the iOS 26 glass + pre-26 fallback).
    @ScaledMetric(relativeTo: .subheadline) private var scrollPillGlyphSize: CGFloat = 15

    /// The user message currently being edited (drives the edit sheet), or nil.
    @State private var editingMessage: ChatMessage?
    /// Working text for the edit sheet.
    @State private var editDraft = ""

    /// Drives the subagent-tree sheet on iPhone (F4A-A2). The iPad presents the
    /// tree as an inspector tab in `RootView` instead. Toggled from the chat
    /// overflow menu; gated on subagent activity + the passive capability.
    @State private var showingSubagentTree = false

    /// Drives the working-directory picker sheet (F4A-A1 ``WorkingDirPicker``,
    /// wired here per the ownership boundary — A2 owns the mount + the
    /// `session.cwd.set` call). Reached from the chat overflow menu; gated on
    /// `capabilities.fs != .unavailable` (the patched gateway that serves the
    /// file endpoints) AND an active runtime session.
    @State private var showingWorkingDirPicker = false

    /// A fetched markdown export awaiting the share sheet (— the store's
    /// `exportMarkdown` was fully implemented + tested with no UI entry point).
    /// `Identifiable` so `.sheet(item:)` presents exactly when a fetch lands.
    private struct ExportedTranscript: Identifiable {
        let id = UUID()
        let title: String
        let text: String
    }
    @State private var exportedTranscript: ExportedTranscript?

    /// The live biometric backend injected into the secure prompt (F4A-A2). A
    /// stateless `LAContextAuthenticator` (the F2 seam); falls back to the device
    /// passcode when biometrics are unavailable so the user is never locked out.
    private let secureAuthenticator: BiometricAuthenticating = LAContextAuthenticator()

    private let bottomAnchor = "hermes.chat.bottom"

    /// Whether this surface is in the compact (iPhone) layout. The chat chrome is
    /// now a SYSTEM `.toolbar` on both widths (I1); `isCompact` only selects the
    /// nav-bar BACKGROUND (system-default on compact so the full-bleed card shows
    /// through; themed-opaque on regular/iPad) and the scroll-to-bottom pill.
    private var isCompact: Bool { horizontalSizeClass == .compact }

    /// Approximate height reserved at the bottom of the transcript so the last
    /// message is never hidden under the floating composer. The composer card is
    /// ~100-130pt tall; an extra ~20pt breathing room reads well. This is a
    /// conservative estimate — `GeometryReader` would be more precise but adds
    /// layout complexity for a one-off safe-area seam. The value is kept here
    /// so it can be adjusted from one place if the composer height changes.
    // Internal (not private) so `UX1PolishTests` can gate on it via @testable import.
    // SCROLL P0 rebuild: this is now the FLOOR / fallback for the measured composer
    // height (`composerHeight`), not the only source — the resting clearance tracks
    // the MEASURED composer (desktop `--composer-measured-height`) but never drops
    // below this so the UX1 gate (≥120) holds and a pre-measurement first frame
    // never under-clears the last message.
    static let composerFloatInset: CGFloat = 140

    /// The breathing room between the last message and the top of the floating
    /// composer (resting). Pure constant so the clearance composition is testable.
    static let composerBreathingGap: CGFloat = 16

    /// The TOTAL bottom clearance reserved below the last message, COMPOSED from the
    /// measured composer height, the live keyboard height, and a breathing gap —
    /// the deterministic replacement for the fixed `composerFloatInset` spacer
    /// (SCROLL P0). Pure + static so the keyboard-rise composition is unit-testable
    /// without a live view.
    ///

    ///  • At rest (`keyboardHeight == 0`): `composerHeight + breathingGap`, floored
    ///  at `composerFloatInset` — i.e. the measured composer plus breathing room,
    ///  never less than the proven 140 floor. Identical full-bleed feel to today.
    ///  • Keyboard up: ADD the keyboard region above the home-indicator baseline the
    ///  composer already reserves (`controlBottomBaseline`), so the last message
    ///  clears BOTH the risen composer AND the keyboard. Because the transcript is
    ///  bottom-anchored (`defaultScrollAnchor(.bottom)`), growing this spacer
    ///  pushes the content up by exactly the keyboard height → the transcript
    ///  rises WITH the composer, deterministically.
    static func composerClearance(
        composerHeight: CGFloat,
        keyboardHeight: CGFloat,
        baseline: CGFloat = HermesLayoutConstants.controlBottomBaseline
    ) -> CGFloat {
        let resting = max(composerFloatInset, composerHeight + composerBreathingGap)
        let keyboardClearance = max(0, keyboardHeight - baseline)
        return resting + keyboardClearance
    }

    /// Distance (pts) from the content's true bottom within which the transcript is
    /// considered "at bottom" — drives the streaming auto-stick gate and the
    /// scroll-to-bottom pill. A measured threshold (desktop `stickyBottom` analog)
    /// rather than a lazy 1pt anchor's appear/disappear, so it reflects the REAL
    /// geometry: small enough that a reader who scrolled up a screen disarms it,
    /// large enough to absorb sub-row jitter at the tail.
    static let atBottomThreshold: CGFloat = 80

    /// SMOOTHNESS R39 (Defect 2) — the EAGER transcript-tail window size. The plain
    /// `VStack` renders the last `transcriptWindow` messages with NO lazy height
    /// estimation, so the bottom anchor resolves against EXACT content geometry and
    /// the open lands precisely on the newest row (the lazy-estimation strander is
    /// removed by construction). Older messages are reachable via the "Load earlier
    /// messages" chip, which grows the window by this same step. 150 covers the vast
    /// majority of real sessions in a single window while keeping eager construction
    /// cheap (RenderCache memoizes segmentation + prose, so an off-screen tail row
    /// costs little). Pinned by `UX1PolishTests` so the value is a deliberate choice.
    static let transcriptWindow = 150

    // MARK: - Header-clearance top inset (FIX 2)

    /// Height of the floating header's pill row, measured from the bottom of the
    /// status-bar inset down to the bottom edge of the drawer/new-chat pills. The
    /// `compactHeaderControls` row is a 38pt pill `.frame` + `.padding(.top, 4)`,
    /// stacked in an 8pt `VStack` inside `compactFloatingHeader`; ≈46 pt covers the
    /// pills with a hair of slack. Kept as a constant so the resting-clearance inset
    /// moves with the header if the pill metrics change.
    static let floatingHeaderHeight: CGFloat = 46

    /// Extra breathing room between the floating header's bottom edge and the first
    /// resting message, so a top-of-conversation message is not jammed under the
    /// header. Smaller than `interTurnGap` — this is a one-time top clearance, not
    /// an inter-turn rhythm value.
    static let headerRestingGap: CGFloat = 12

    /// The transcript's TOP fade-band height (`EdgeFadeMask.topFade`), mirrored here
    /// so the resting inset can be reconciled with it. The first resting message
    /// must clear this band: content within it is dissolved toward ≈0 so the header
    /// pills stay legible over scrolled-under text — a message RESTING inside it
    /// would read as muted/jammed under the header. The inset floors at this band +
    /// a gap so the first message rests in the CLEAR (full-opacity) zone just below
    /// the fade, while still sliding UP into the fade when scrolled. Pinned by
    /// `UX1PolishTests` against `EdgeFadeMask` so the two can never silently drift.
    static let transcriptTopFadeBand: CGFloat = 135

    /// The TOP content inset applied to the transcript so the first element RESTS
    /// in the clear band BELOW the floating header (FIX 2) while still sliding UNDER
    /// it (into the fade) when scrolled. This is the header-CLEARANCE inset —
    /// distinct from Batch D's per-row `topGap` (the inter-turn rhythm).
    ///

    /// Composed as the MAX of two clearances so it satisfies BOTH on every device:
    ///  1. The chrome geometry: status-bar inset (`compactTopInset`; the card stack
    ///  zeroed the ambient safe area, so it is threaded in) + the header pill
    ///  height + a breathing gap — clears the physical pills.
    ///  2. The fade band: `transcriptTopFadeBand` + the breathing gap — lands the
    ///  first message in the CLEAR zone below the dissolve, so it rests fully
    ///  legible rather than muted inside the fade (the device-confirmed
    ///  "jammed/faded under header" symptom when the inset was only (1) ≈117 pt,
    ///  below the 135 pt fade band).
    ///

    /// On the nominal iPhone 17 Pro (safeTop ≈ 59) clause (2) wins (135 + 12 = 147 >
    /// 59 + 46 + 12 = 117); on a hypothetical very-tall status bar clause (1) takes
    /// over so the pills are still cleared. Pure + static so the chosen value is
    /// unit-testable without a live view.
    static func transcriptTopInset(compactTopInset: CGFloat) -> CGFloat {
        let chromeClearance = compactTopInset + floatingHeaderHeight + headerRestingGap
        let fadeClearance = transcriptTopFadeBand + headerRestingGap
        return max(chromeClearance, fadeClearance)
    }

    // MARK: - Turn-aware spacing (Batch D / §3.4)

    /// Tight gap WITHIN a turn — an assistant row following its own turn's
    /// user/assistant rows (desktop `--conversation-turn-gap = 0.375rem ≈ 6pt`).
    static let intraTurnGap: CGFloat = 6
    /// Larger gap BETWEEN turns — the top of a new user row opens a fresh turn.
    static let interTurnGap: CGFloat = 18
    /// Extra breathing room around dimmed system / collapsed scaffolding rows so
    /// cron/system entries sit OUTSIDE the conversational rhythm (so they stop
    /// reading as evenly-spaced clutter, §3.4).
    static let scaffoldingGap: CGFloat = 22

    /// The top gap a row contributes, from its role transition with the row above
    /// it. Pure + static so the turn-grouping rhythm is unit-testable without a
    /// live View. `previous == nil` is the first row (no gap — the container's
    /// `.padding(.top)` already clears the header).
    ///

    /// Rules (desktop `buildGroups` semantics expressed as spacing):
    ///  - First row: 0 (container handles the top inset).
    ///  - Either row is scaffolding (system role or `.collapsed`): the larger
    ///  `scaffoldingGap`, so machine rows are visually set apart from turns.
    ///  - A `user` row after any conversational row: `interTurnGap` — a new turn.
    ///  - Otherwise (assistant/tool following within the turn, or the very first
    ///  assistant after its user): `intraTurnGap` — the tight intra-turn rhythm.
    static func topGap(above message: ChatMessage, after previous: ChatMessage?) -> CGFloat {
        guard let previous else { return 0 }
        if isScaffolding(message) || isScaffolding(previous) { return scaffoldingGap }
        if message.role == .user { return interTurnGap }
        return intraTurnGap
    }

    /// A row that lives OUTSIDE the turn rhythm: a system row, or any row the seed
    /// producer marked `.collapsed` (cron preambles, system prompts, raw dumps).
    static func isScaffolding(_ message: ChatMessage) -> Bool {
        if case .collapsed = message.presentation { return true }
        return message.role == .system
    }

    var body: some View {
        ScrollViewReader { proxy in
            transcript(proxy: proxy)
                // FULL-BLEED + KEYBOARD-AWARE (SCROLL P0 REBUILD): the transcript
                // scroll surface draws to the absolute screen edges — under the
                // status bar at the top and to the very bottom edge — so content
                // flows behind the floating chrome on both sides. The top chrome
                // pills are anchored by the floating header overlay; the floating
                // composer overlay rises with the keyboard (RootView keeps `.keyboard`
                // live at the CompactLayout level for that).
                //

                // The transcript ignores `.container` (status bar + home indicator —
                // full-bleed at rest) AND `.keyboard` here. Ignoring `.keyboard` is
                // the DETERMINISTIC keyboard fix: the prior design left the transcript
                // to SwiftUI's automatic keyboard avoidance, but the focused field
                // lives in a SIBLING `.overlay` (the composer), not inside this
                // ScrollView — so SwiftUI raised the composer but did NOT reliably
                // inset the transcript content (the device-confirmed "last message
                // behind keyboard" bug). Rather than depend on that cross-overlay
                // inference, the transcript OWNS its keyboard clearance explicitly:
                // it ignores the keyboard region entirely (zero SwiftUI keyboard
                // inset — no partial/ambiguous avoidance, no double-count) and the
                // composer-clearance spacer grows by the MEASURED keyboard height
                // (`composerClearance`, fed by `KeyboardHeightReader`). Because the
                // ScrollView is bottom-anchored (`defaultScrollAnchor(.bottom)`),
                // growing that spacer rises the content with the composer by exactly
                // the keyboard height. At rest the keyboard height is 0, so the
                // clearance is the measured composer + breathing room — identical
                // full-bleed feel, no home-indicator strip.
                .ignoresSafeArea(.container, edges: [.top, .bottom])
                .ignoresSafeArea(.keyboard, edges: .bottom)
                .scrollDismissesKeyboard(.interactively)
                // Top + bottom edge dissolve. The custom `EdgeFadeMask` owns the
                // legibility band on ALL OS versions (eased, ~120/150 pt, content
                // muted to ≈0 at the edges so the header pills + composer stay
                // legible); on iOS 26 the genuine native `.scrollEdgeEffectStyle(.soft)`
                // is composited on top for real Liquid Glass refraction. See
                // `TranscriptEdgeEffect` for the verified native-vs-custom rationale.
                .modifier(TranscriptEdgeEffect())
                // The composer floats as a bottom overlay:
                // the ScrollView extends edge-to-edge so the transcript scrolls
                // under the top chrome and under the floating composer. The
                // bottomStack rides as an .overlay(alignment:.bottom) so it
                // sits above the transcript without inset-shrinking the scroll area.
                .overlay(alignment: .bottom) {
                    // Full-bleed round 2: the overlay CONTENT still inherits the
                    // container safe-area inset (home indicator), which stacked
                    // under `controlBottomBaseline` and left a dead band below
                    // the composer. Ignore the CONTAINER inset only — the
                    // `.keyboard` region stays respected so the composer still
                    // rises with the keyboard.
                    bottomStack(proxy: proxy)
                        .ignoresSafeArea(.container, edges: .bottom)
                }
                // Chrome. Two mutually-exclusive paths:
                //

                //  • compactStandaloneChrome == true (iPhone, STRIKE P0): there is
                //  NO wrapping NavigationStack, so a system `.toolbar` has no
                //  host. Render a FLOATING GLASS HEADER overlay instead (same
                //  controls + a11y ids). This is what frees the transcript from
                //  the stack's reserved content inset — the scroll surface is now
                //  the direct child of the card ZStack and its
                //  `.ignoresSafeArea(.all, edges:[.top,.bottom])` actually reaches
                //  the physical screen edges.
                //

                //  • else (iPad regular width): the chat lives inside the split
                //  view's NavigationStack, so keep the I1 system `.toolbar`
                //  arrangement exactly as before — untouched.
                .applyingSystemChatChrome(
                    enabled: !compactStandaloneChrome,
                    isCompact: isCompact,
                    toolbarBg: theme.toolbarBg,
                    navigationTitle: navigationTitle
                ) { toolbarContent }
                .overlay(alignment: .top) {
                    if compactStandaloneChrome {
                        compactFloatingHeader
                    }
                }
                .onChange(of: chatStore.lastError) { _, newError in
                    presentToast(newError)
                }
                .onAppear { presentToast(chatStore.lastError) }
                .sheet(item: $editingMessage) { message in
                    EditMessageSheet(
                        original: message,
                        text: $editDraft,
                        onSave: { newText in
                            editingMessage = nil
                            Task { await chatStore.editAndResend(messageId: message.id, newText: newText) }
                        },
                        onCancel: { editingMessage = nil }
                    )
                    .hermesThemed(themeStore)
                }
                // Secure prompt (F4A-A2): sudo / secret. Driven directly by the
                // store's transient pending prompt — `.sheet(item:)` so a new
                // request replaces an in-flight one cleanly. The value never
                // leaves SecurePromptView; the store reply method takes it,
                // forwards it, and drops it.
                .sheet(item: securePromptBinding) { prompt in
                    SecurePromptView(
                        prompt: prompt,
                        authenticator: secureAuthenticator,
                        onSubmit: { value in await chatStore.respondSecurePrompt(value: value) },
                        onCancel: { Task { await chatStore.respondSecurePrompt(value: nil) } }
                    )
                    .hermesThemed(themeStore)
                }
                // Subagent tree (F4A-A2): iPhone sheet. The iPad presents it as an
                // inspector tab in RootView instead.
                .sheet(isPresented: $showingSubagentTree) {
                    NavigationStack {
                        SubagentTreeView(chatStore: chatStore)
                    }
                    .hermesThemed(themeStore)
                }
                // Markdown export share sheet: a fetched export
                // presents a preview with a system ShareLink.
                .sheet(item: $exportedTranscript) { export in
                    NavigationStack {
                        ScrollView {
                            Text(export.text)
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding()
                        }
                        .navigationTitle(export.title)
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                ShareLink(item: export.text)
                            }
                            ToolbarItem(placement: .cancellationAction) {
                                Button("Done") { exportedTranscript = nil }
                            }
                        }
                    }
                    .hermesThemed(themeStore)
                }
                // Working-directory picker (F4A-A1 view, A2-mounted). A1's
                // WorkingDirPicker returns the chosen folder's RELATIVE path; the
                // `onPick` joins it to the absolute cwd and drives
                // `session.cwd.set` (4009/4016/4017 mapped to native errors), then
                // re-lists so the browser/composer @-file cwd reflect the new root.
                .sheet(isPresented: $showingWorkingDirPicker) {
                    if let control = connectionStore.control,
                       let sessionId = sessionStore.activeRuntimeId, !sessionId.isEmpty {
                        WorkingDirPicker(
                            rest: control,
                            sessionId: sessionId,
                            onPick: { relativePath in
                                handleWorkingDirPick(relativePath, rest: control, sessionId: sessionId)
                            }
                        )
                        .hermesThemed(themeStore)
                    } else {
                        ContentUnavailableView(
                            "No Active Session",
                            systemImage: "folder.badge.gearshape",
                            description: Text("Open a chat to change its working directory.")
                        )
                    }
                }
        }
    }

    /// Resolve the picker's RELATIVE path to an absolute cwd and call
    /// `session.cwd.set`. Per A1's `onPick` contract the picker hands back a path
    /// relative to the file-browser root, so we fetch the root once via `fsList`
    /// (the cheap, side-effect-free list of the cwd root) and join. On success the
    /// gateway sets the cwd, persists `explicit_cwd`, and emits a `session.info`
    /// event; both the file browser and the composer @-file picker resolve their
    /// cwd by `session_id` on every call, so the next listing/completion reflects
    /// the new root automatically (no client-side cache to invalidate). Errors land
    /// in `chatStore.lastError` (rendered as the chat toast).
    private func handleWorkingDirPick(_ relativePath: String, rest: RestClient, sessionId: String) {
        Task {
            // Resolve the absolute cwd root the browser was showing. fsList with no
            // path lists the root and returns its absolute `root` — the join base.
            let root: String
            do {
                root = try await rest.fsList(sessionId: sessionId, path: nil).root
            } catch {
                chatStore.lastError = WorkingDirectory.mapSetError(error).message
                return
            }
            await chatStore.setWorkingDirectory(root: root, relativePath: relativePath)
        }
    }

    /// Binding that surfaces the store's `pendingSecurePrompt` to `.sheet(item:)`
    /// and clears it (via a skip reply) when the sheet is dismissed by the system
    /// without an explicit action.
    private var securePromptBinding: Binding<PendingSecurePrompt?> {
        Binding(
            get: { chatStore.pendingSecurePrompt },
            set: { newValue in
                // A nil write here means the sheet was dismissed (swipe / system).
                // Treat it as a skip so the gateway's pending request is released
                // with the empty reply rather than left hanging.
                if newValue == nil, chatStore.pendingSecurePrompt != nil {
                    Task { await chatStore.respondSecurePrompt(value: nil) }
                }
            }
        )
    }

    /// The floating bottom stack: now an `.overlay(alignment:.bottom)`
    /// on the transcript. The stack holds banners (above the readability fade),
    /// the optional scroll-to-bottom pill, the optional streaming activity bar, and
    /// the floating glass composer. The opaque toolbarBg strip is removed from
    /// ComposerView's outer container (see `ComposerView.body`); only the glass
    /// card surface (`ComposerCardSurface`) reads. A `theme.bg` readability
    /// backing is painted BEHIND the composer on ALL OS versions so the composer
    /// floats over a clean substrate while the transcript's `EdgeFadeMask`
    /// dissolves the scrolling text above it (see `TranscriptEdgeEffect`).
    @ViewBuilder
    private func bottomStack(proxy: ScrollViewProxy) -> some View {
        VStack(spacing: 8) {
            banners
            if isCompact && !atBottom {
                scrollToBottomPill(proxy: proxy)
            }
            if chatStore.isStreaming {
                TurnActivityBar(chatStore: chatStore)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            ComposerView(
                chatStore: chatStore,
                attachmentStore: attachmentStore,
                isConnected: isConnected
            )
            // Measure the composer card height so the transcript's bottom clearance
            // tracks the MEASURED composer (desktop `--composer-measured-height`)
            // instead of the fixed 140 estimate. Add the shared bottom baseline so
            // the clearance accounts for the composer's gap above the screen edge
            // too. `composerClearance` floors at `composerFloatInset`, so a tall
            // multi-line composer reserves more, and a short one never under-clears.
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.height
            } action: { height in
                let measured = height + HermesLayoutConstants.controlBottomBaseline
                if abs(measured - composerHeight) > 0.5 { composerHeight = measured }
            }
        }
        .animation(.easeInOut(duration: 0.2), value: chatStore.isStreaming)
        .animation(.easeInOut(duration: 0.2), value: atBottom)
        // Readability backing behind the bottom stack on ALL OS versions. The
        // transcript's `EdgeFadeMask` already dissolves scrolling content to ≈0
        // toward the bottom edge, but this `theme.bg` gradient gives the floating
        // composer a clean, fully-opaque substrate so any residual muted content
        // never bleeds through behind the composer card. (Previously gated to
        // iOS 17-25 on the assumption the native effect handled it; the mask is
        // now the source of the fade on every version, so the backing is too.)
        .background(alignment: .bottom) {
            LinearGradient(
                stops: [
                    .init(color: theme.bg.opacity(0), location: 0),
                    .init(color: theme.bg.opacity(0.85), location: 0.45),
                    .init(color: theme.bg, location: 1)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .allowsHitTesting(false)
        }
        // Position the bottom stack the shared baseline distance above the
        // absolute screen bottom edge (full-bleed layout — the scroll surface
        // now extends to the screen edge, so we must supply the safe-area
        // clearance ourselves). `controlBottomBaseline` is shared with
        // DrawerView's New-chat capsule so both controls sit on the same
        // horizontal baseline when the drawer slides over the chat.
        .padding(.bottom, HermesLayoutConstants.controlBottomBaseline)
    }

    // MARK: - Transcript

    private func transcript(proxy: ScrollViewProxy) -> some View {
        ScrollView {
            if isDraft && chatStore.messages.isEmpty {
                // Fresh draft chat — the time-aware greeting is rendered as a
                // CENTRED OVERLAY on the scroll viewport (see `.overlay` below),
                // not in the scroll flow, so it sits at the true vertical centre.
                // (`containerRelativeFrame` inside the scroll resolved to the
                // intrinsic height and pinned it to the top.) Keep the in-flow
                // branch empty.
                Color.clear.frame(height: 0)
            } else if chatStore.messages.isEmpty && chatStore.transcriptGeneration == 0 {
                if let loadError = chatStore.lastBackfillError {
                    // The seed/backfill failed — a recoverable error beats an
                    // infinite spinner. Retry re-runs the REST
                    // backfill; on success the seed bumps
                    // `transcriptGeneration` and this state exits on its own.
                    ContentUnavailableView {
                        Label("Couldn't load conversation", systemImage: "wifi.exclamationmark")
                    } description: {
                        Text(loadError)
                    } actions: {
                        Button("Try Again") {
                            Task { await chatStore.backfill() }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .padding(.top, 40)
                } else {
                    // CACHE-MISS open (WhatsApp bar — never white): the transcript
                    // is seeding from the network after an instant open with no
                    // cached content. Render a theme-consistent skeleton (the same
                    // static muted-bar design language as the drawer's
                    // `sessionSkeletonRows`) instead of a bare spinner over a white
                    // void — so a cache-miss open reads as "content arriving", not
                    // a blank screen. A cache HIT never reaches here: the cached
                    // transcript painted as the first frame.
                    TranscriptSkeletonView(theme: theme)
                        .padding(.top, 12)
                        .accessibilityLabel("Loading conversation")
                }
            }
            // TURN-AWARE SPACING:
            // the transcript is no longer a flat `spacing: 14` rhythm. The
            // LazyVStack runs at `spacing: 0` and EACH row supplies its own top
            // gap via `Self.topGap(above:after:)`, computed from the role
            // transition with the previous row: a tight gap WITHIN a turn (an
            // assistant row following its user/assistant turn-mate), a larger gap
            // BETWEEN turns (a new user row), and extra breathing room around the
            // dimmed system/collapsed scaffolding rows so cron/system entries stop
            // reading as evenly-spaced clutter. The first row gets no top gap (the
            // container's `.padding(.top, 12)` already clears the header baseline).
            //

            // CANVAS-SAFE: this only changes the inter-row spacing mechanism. The
            // ForEach identity (`.id(element.id)`), the bottom anchor, the
            // horizontal/top/bottom container padding, the full-bleed background,
            // and every scroll handler below are untouched — none of the
            // full-bleed / EdgeFadeMask / header / composer-baseline code is in
            // this region.
            // SMOOTHNESS R39 (Defect 2) — EAGER WINDOWED VStack (was `LazyVStack`).
            // The lazy stack estimated the heights of unrealized rows above the
            // bottom-anchored viewport; markdown/code rows estimate badly, so the
            // anchor resolved "bottom" against a WRONG contentSize and parked the
            // open mid/blank — then realizing the rows on scroll corrected the offset
            // (the user's "scroll-up-then-snap"). A plain `VStack` over a BOUNDED
            // tail window removes estimation from the window entirely: every rendered
            // row is fully laid out, so the bottom anchor resolves against EXACT
            // geometry and the open lands precisely on newest. Older messages stay in
            // `ChatStore` (full memory); only VIEW construction is windowed, and
            // `RenderCache` keeps eager construction cheap.
            VStack(alignment: .leading, spacing: 0) {
                // ARCH37 STEP 1 — capture the enumerated snapshot ONCE so the
                // previous-row lookup indexes the SAME array the `ForEach` iterates,
                // never the live `@Observable` `chatStore.messages`. The old
                // `chatStore.messages[index - 1]` re-indexed the live array with an
                // `index` from the captured snapshot; when `messages` shrinks between
                // the snapshot and a body re-eval (e.g. the per-session `.id` remount
                // racing a `reset()` on a session switch — the switchlong repro), that
                // re-index was out of range and crashed. Reading `previous` from the
                // captured `rows` array is index-consistent by construction.
                //

                // R39: the snapshot is the WINDOWED tail — the last `windowSize`
                // messages. `windowStart` is the index of the first windowed row in
                // the full transcript; the `previous`-row lookup uses it so the FIRST
                // windowed row still gets the correct turn-aware `topGap` relative to
                // the (possibly off-window) message just above it.
                let allRows = Array(chatStore.messages.enumerated())
                let windowStart = max(0, allRows.count - windowSize)
                let rows = Array(allRows[windowStart...])
                // "Load earlier messages" chip — only when the window does not
                // already cover the whole transcript. Tapping grows the window by
                // another `transcriptWindow`. The grow is anchored to the previously
                // first-visible row id via `ScrollViewReader` so the content above
                // appears WITHOUT yanking the reader's current position.
                if windowStart > 0, let firstId = rows.first?.element.id {
                    loadEarlierChip(anchorTo: firstId, proxy: proxy)
                        .id("hermes.chat.loadEarlier")
                }
                ForEach(rows, id: \.element.id) { index, message in
                    // `index` here is the ABSOLUTE index into the full transcript
                    // (preserved by `enumerated()` before the slice), so the previous
                    // row is `allRows[index - 1]` — correct even for the first
                    // windowed row, which looks back at the off-window message above.
                    let previous = index > 0 ? allRows[index - 1].element : nil
                    MessageBubble(
                        message: message,
                        onEdit: editHandler,
                        onRetry: retryHandler,
                        onSpeak: onSpeak,
                        onRestoreCheckpoint: restoreCheckpointHandler,
                        onBranch: branchHandler,
                        menuActionsEnabled: menuActionsEnabled,
                        appearance: BubbleAppearance(themeID: theme.id, colorScheme: colorScheme, typeSize: dynamicTypeSize)
                    )
                    // A1 (scarf): settled bubbles short-circuit their body — only the
                    // streaming bubble (whose `message` changed) re-evaluates. Drops the
                    // per-flush cost from O(window) bodies to O(1). The `==` compares
                    // `message` + menu-action gating + the `appearance` token; a theme /
                    // Dynamic-Type switch flips `appearance` so it never strands stale.
                    .equatable()
                    .padding(.top, Self.topGap(above: message, after: previous))
                    .id(message.id)
                }
                // Inline approval card — rendered as ADDITIVE transcript
                // content after the last message when there is a pending approval
                // for the current session. This is pure additive content: it does
                // not touch any scroll/anchor/keyboard machinery. The existing
                // re-pin-on-settle (BottomEdgeScroll / pendingLandOnNewest /
                // scrollToBottomIfNeeded) naturally keeps this card visible when
                // it appears at the tail, exactly like a new message row.
                // The card disappears when pendingApproval is cleared (respondApproval
                // sets it nil, expireTurnScopedPrompts sets it nil on turn end /
                // session switch) — no manual lifecycle needed.
                if let approval = chatStore.pendingApproval {
                    ApprovalCard(approval: approval, chatStore: chatStore)
                        .padding(.top, Self.intraTurnGap)
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                        .id("inline-approval-\(approval.id)")
                }
                // SCROLL P0 #2 (contract Batch E §3.6) — composer-clearance spacer.
                //

                // The full-bleed transcript must reserve space below the last
                // message so it is never hidden under the FLOATING composer (an
                // overlay that does NOT inset the scroll bounds). The clearance is a
                // spacer element ABOVE the anchor, INSIDE the stack — so `bottomAnchor`
                // is the TRUE content end (natural max-scroll). Scrolling to it lands
                // the content at its real bottom, where the last message clears the
                // composer by exactly this spacer height — never into an inset void
                // below the anchor (the old white-void overscroll bug).
                //

                // SCROLL P0 REBUILD — the height is now COMPOSED + DETERMINISTIC
                // (`Self.composerClearance`): the MEASURED composer height + the live
                // KEYBOARD height + a breathing gap, replacing the fixed 140 estimate.
                // At rest it equals the measured composer + breathing (≥140 floor —
                // identical full-bleed feel). When the keyboard opens it GROWS by the
                // keyboard region; because the ScrollView is bottom-anchored
                // (`defaultScrollAnchor(.bottom)`), growing this spacer pushes the
                // content up by exactly the keyboard height, so the transcript rises
                // WITH the composer and the last message stays visible — by
                // construction, not by SwiftUI inferring a cross-overlay keyboard
                // inset (which it does not do reliably; the device-confirmed bug).
                Color.clear
                    .frame(height: Self.composerClearance(
                        composerHeight: composerHeight,
                        keyboardHeight: keyboardHeight))
                    .accessibilityHidden(true)
                // True content-end anchor (1pt) — search-jump target.
                Color.clear
                    .frame(height: 1)
                    .id(bottomAnchor)
            }
            .padding(.horizontal, 16)
            // TOP CLEARANCE (FIX 2): the first element must REST below the floating
            // header (not jammed under it) while still sliding UNDER the header when
            // scrolled (the EdgeFadeMask top band handles the under-header look).
            //

            //  • compactStandaloneChrome (iPhone): the chrome is the
            //  `compactFloatingHeader` OVERLAY — it reserves NO layout inset, so
            //  the transcript content would rest at the physical top edge with
            //  only Batch D's first-row gap (which is 0 for `after: nil`). Apply
            //  the header-clearance inset = status-bar inset + header pill height
            //  + a breathing gap (`transcriptTopInset`). This is the SCROLL
            //  CONTENT top inset, applied once to the whole LazyVStack — NOT a
            //  per-turn `topGap`, so it does NOT double the inter-turn spacing of
            //  later rows (Batch D's `topGap(after: nil) == 0` for the first row,
            //  so there is no overlap to reconcile; every later row keeps its own
            //  inter/intra/scaffolding gap unchanged).
            //  • else (iPad regular): the system toolbar reserves its own bar inset
            //  via the NavigationStack, so only the small uniform 12pt keeps the
            //  first turn off the title baseline (unchanged).
            .padding(.top, compactStandaloneChrome
                     ? Self.transcriptTopInset(compactTopInset: compactTopInset)
                     : 12)
            // Bottom inset: the floating composer is an overlay,
            // not a safeAreaInset, so the ScrollView's content must itself reserve
            // space below the last message or it will scroll under the glass card.
            // `composerFloatInset` (≈140pt) clears the composer height + home
            // indicator + breathing room. It is now contributed by the
            // composer-clearance SPACER element ABOVE the `bottomAnchor` (inside the
            // LazyVStack) rather than a `.padding(.bottom)` BELOW the anchor — so the
            // `bottomAnchor` is the true content end (SCROLL P0 #2, see the spacer
            // above). The total reserved height is unchanged (still
            // `composerFloatInset`), so the at-rest full-bleed layout is identical;
            // only the anchor's position relative to the inset moved.
        }
        // Stock scroll anchor: open-at-bottom, follow streaming growth while parked
        // at bottom, release on user scroll-up, re-anchor on late content. Short
        // chats bottom-align (iMessage/WhatsApp behaviour — accepted by design).
        // DEBUG: optionally hide the iOS-26 gradient-stroked indicator.
        .perfScrollIndicators()
        .defaultScrollAnchor(.bottom)
        .scrollContentBackground(.hidden)
        // R1 atBottom tracker (iOS 18+): feeds the pill + queue banner. Degrades
        // gracefully on iOS 17 — atBottom defaults true (no pill machinery for 17,
        // fleet is iOS 26).
        .modifier(ScrollAtBottomTracker(threshold: Self.atBottomThreshold) { nowAtBottom in
            if nowAtBottom != atBottom { atBottom = nowAtBottom }
        })
        // Full-bleed background (no viewport-capture GeometryReader needed).
        // For the `nous` palette this paints the desktop-style backdrop (warm
        // glow + faint texture) over `theme.bg`; every other palette renders the
        // flat `theme.bg` unchanged. See ``HermesSurfaceBackground``.
        .background { HermesSurfaceBackground(theme: theme).ignoresSafeArea() }
        // Draft greeting, centred on the viewport. As an overlay (not scroll
        // flow) it uses the ScrollView's real rendered size, so it lands at the
        // true vertical centre rather than the top.
        .overlay {
            if isDraft && chatStore.messages.isEmpty {
                draftGreeting
                    .allowsHitTesting(false)
            }
        }
        // KEYBOARD: observe height, feed into clearance spacer.
        .modifier(KeyboardHeightReader(height: $keyboardHeight))
        // FIX 3: re-park atBottom on user's own outgoing turn so the streaming
        // reply is followed from the first token.
        .onChange(of: chatStore.messages.count) { oldCount, newCount in
            if newCount > oldCount, chatStore.localTurnInFlight { atBottom = true }
        }
        // STREAM-FOLLOW: `.defaultScrollAnchor(.bottom)` only sets the INITIAL
        // offset; it does NOT track growth from an in-place mutation of the last
        // row's text (the streaming reply grows via `parts`, not a new row, so
        // `messages.count` stays flat after the first token). Follow that growth
        // here: when parked at the tail (`atBottom`), re-pin to the true content
        // end on every flush. Gated by `atBottom`, so a reader who scrolled up
        // mid-stream is never yanked (the §3.6 rule). The subtree
        // `.transaction { animation = nil }` makes this an INSTANT edge re-pin —
        // continuous smooth growth, no per-flush spring fighting the 40ms cadence.
        .onChange(of: chatStore.messages.last?.text) { _, _ in
            guard atBottom else { return }
            proxy.scrollTo(bottomAnchor, anchor: .bottom)
        }
        // Jump-to-search-match on transcriptGeneration bump (search open).
        .onChange(of: chatStore.transcriptGeneration) { _, _ in
            if sessionStore.pendingSearchScroll != nil, !chatStore.messages.isEmpty {
                jumpToSearchMatchIfNeeded(proxy)
            }
        }
        .onAppear {
            // On remount (per-session identity swap) atBottom resets to true so the
            // pill stays hidden and the native anchor owns the open landing.
            atBottom = true
        }
        // R39 (Defect 2): reset the eager-tail window to its base size when the
        // session changes. `ChatView`'s `@State` outlives the per-session ScrollView
        // `.id` remount (the id is on the inner ScrollView, not ChatView), so a
        // window grown by "Load earlier" in session A would otherwise carry into
        // session B. Snapping back to `transcriptWindow` keeps every open landing on
        // the exact-geometry tail window.
        .onChange(of: chatStore.activeStoredSessionId) { _, _ in
            windowSize = Self.transcriptWindow
        }
        // PER-SESSION SCROLLVIEW IDENTITY: each session open mounts a fresh ScrollView.
        // `.defaultScrollAnchor(.bottom)` resolves at first layout → native open-on-newest.
        // The `.transaction { $0.animation = nil }` on the subtree blocks any
        // ambient spring (e.g. the drawer-close spring) from riding the id swap,
        // eliminating the cross-fade "morph" on drawer-select.
        .transaction { $0.animation = nil }
        .id(chatStore.activeStoredSessionId ?? "hermes.chat.draft")
    }

    /// iOS 18+ `atBottom` tracker: reads the real scroll geometry (contentOffset,
    /// contentSize, containerSize) via `onScrollGeometryChange`, so the distance from
    /// the TRUE content bottom is exact and unaffected by lazy-row unloading. Factored
    /// into a version-gated modifier so the iOS-17 floor never names the iOS-18 API.
    private struct ScrollAtBottomTracker: ViewModifier {
        let threshold: CGFloat
        let onChange: (Bool) -> Void

        func body(content: Content) -> some View {
            if #available(iOS 18.0, *) {
                content.onScrollGeometryChange(for: Bool.self) { geo in
                    // Distance from the true bottom = total content below the visible
                    // bottom edge. Within threshold ⇒ parked at the tail.
                    let distance = geo.contentSize.height
                        - (geo.contentOffset.y + geo.containerSize.height)
                    return distance <= threshold
                } action: { _, nowAtBottom in
                    onChange(nowAtBottom)
                }
            } else {
                content  // iOS 17: atBottom stays default true; pill always available.
            }
        }
    }

    /// Search jump-to-match: when the session was opened from a search result
    /// (`SessionStore.pendingSearchScroll` holds the query), scroll the
    /// transcript to the FIRST message whose prose contains the query instead of
    /// landing on the newest message. Consumes the request either way. A query
    /// that only matched non-prose content (a Code/tool hit) finds no prose
    /// message → no-op (native anchor already rested at bottom).
    private func jumpToSearchMatchIfNeeded(_ proxy: ScrollViewProxy) {
        guard let query = sessionStore.pendingSearchScroll,
              !query.isEmpty,
              !chatStore.messages.isEmpty else { return }
        let needle = query.lowercased()
        sessionStore.pendingSearchScroll = nil
        if let match = chatStore.messages.first(where: {
            $0.text.lowercased().contains(needle)
        }) {
            withAnimation(.easeInOut(duration: 0.25)) {
                proxy.scrollTo(match.id, anchor: .center)
            }
        }
    }

    // MARK: - Load-earlier chip (R39 / Defect 2)

    /// "Load earlier messages" affordance shown above the eager tail window when the
    /// window does not cover the whole transcript. Tapping grows the window by one
    /// `transcriptWindow` step. The grow is anchored to the previously-first windowed
    /// row (`anchorTo`) via `ScrollViewReader`: after the older rows are constructed
    /// above, the view re-pins that same row to `.top` so the reader's position is
    /// preserved (no visible jump). Wrapped in `withAnimation(nil)` so the grow is an
    /// instant content swap, not an animated reflow fighting the anchor.
    private func loadEarlierChip(anchorTo firstId: ChatMessage.ID, proxy: ScrollViewProxy) -> some View {
        Button {
            withAnimation(nil) {
                windowSize += Self.transcriptWindow
            }
            // Re-pin the previously-first row to the top after the older rows lay
            // out above it, so the reader stays put. A runloop hop lets the grown
            // window construct before the scroll resolves.
            DispatchQueue.main.async {
                proxy.scrollTo(firstId, anchor: .top)
            }
        } label: {
            Text("Load earlier messages")
                .font(.footnote.weight(.medium))
                .foregroundStyle(theme.mutedFg)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .chromePill(theme, in: Capsule())
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        .accessibilityLabel("Load earlier messages")
        .accessibilityIdentifier("loadEarlierMessages")
    }

    // MARK: - Draft empty state

    /// Centred time-aware greeting shown when the session store is in draft mode
    /// and the transcript is empty (F3): the theme glyph above a serif greeting
    /// "Morning/Afternoon/Evening, <name>" (display name from the Settings field,
    /// F2). With no name set the greeting is the bare time word with a trailing
    /// period ("Morning." / "Evening.") — Amendment E.
    private var draftGreeting: some View {
        VStack(spacing: 16) {
            Image(systemName: "sparkles")
                .font(.largeTitle)
                .foregroundStyle(greetingGlyphColor)
                .accessibilityHidden(true)
            greetingTextView
                .font(.system(.title, design: .serif).weight(.regular))
                .foregroundStyle(theme.fg)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 24)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(greetingText)
    }

    /// Tint for the draft greeting glyph. nous *dark* paints a blue glyph
    /// (`midground` #0053FD) on a blue canvas (`bg` #0D2F86) — it disappears —
    /// so it uses white there. nous *light* keeps the blue (it reads fine on the
    /// near-white canvas), and every other theme keeps its brand-colored glyph.
    private var greetingGlyphColor: Color {
        if theme.name == "nous" && colorScheme == .dark { return .white }
        return theme.midground
    }

    /// The time-aware greeting string shown on the draft canvas. Kept (String)
    /// for the accessibility label + unit tests.
    private var greetingText: String {
        Self.greeting(phrase: Self.timeOfDayPhrase(locale: locale), name: DefaultsKeys.displayNameValue())
    }

    /// The greeting as a `Text` so the time-of-day phrase resolves as a
    /// `LocalizedStringKey` against `Bundle.main` — which the in-app language
    /// switch reclasses — exactly like every other localized string in the app.
    /// `String(localized:locale:)` (used by ``greetingText``) does NOT follow the
    /// runtime bundle swap, so it must not drive the VISIBLE greeting.
    private var greetingTextView: Text {
        let phrase = Text(Self.timeOfDayKey())
        if let name = DefaultsKeys.displayNameValue() {
            return phrase + Text(verbatim: ", \(name)")
        }
        return phrase + Text(verbatim: ".")
    }

    /// `LocalizedStringKey` for the current time-of-day phrase, resolved by
    /// ``Text`` against the (reclassed) main bundle.
    static func timeOfDayKey(_ date: Date = Date(), calendar: Calendar = .current) -> LocalizedStringKey {
        let hour = calendar.component(.hour, from: date)
        switch hour {
        case 5..<12: return "greeting.morning"
        case 12..<17: return "greeting.afternoon"
        default: return "greeting.evening"
        }
    }

    /// "Morning" / "Afternoon" / "Evening" from the current hour. Pure + static
    /// so the greeting is testable.
    static func timeOfDayPhrase(_ date: Date = Date(), calendar: Calendar = .current, locale: Locale = .current) -> String {
        let hour = calendar.component(.hour, from: date)
        switch hour {
        case 5..<12: return String(localized: "greeting.morning", defaultValue: "Morning", locale: locale)
        case 12..<17: return String(localized: "greeting.afternoon", defaultValue: "Afternoon", locale: locale)
        default: return String(localized: "greeting.evening", defaultValue: "Evening", locale: locale)
        }
    }

    /// Compose the greeting from a time phrase and an optional display name. With
    /// a name: "Evening, Sam". Without one: the bare phrase plus a period —
    /// "Evening." (Amendment E — the explicit fallback the test gates on). Pure +
    /// static so the period fallback is unit-testable.
    static func greeting(phrase: String, name: String?) -> String {
        if let name, !name.isEmpty {
            return "\(phrase), \(name)"
        }
        return "\(phrase)."
    }

    // MARK: - Banners

    @ViewBuilder
    private var banners: some View {
        // approval requests are now rendered INLINE in the transcript
        // (ApprovalCard, injected after the last message row in the LazyVStack).
        // The ApprovalBanner slot is intentionally absent here so the floating
        // overlay no longer duplicates the inline card. ClarifyBanner and the
        // error toast are unaffected — they remain in this floating stack.
        VStack(spacing: 8) {
            // a pending approval/clarification in a DIFFERENT session than
            // the one open here. The open session's prompt is handled inline
            // (ApprovalCard) / by ClarifyBanner below — this surfaces the
            // cross-session case so a blocking prompt elsewhere isn't stranded.
            if let item = crossSessionItems.first {
                CrossSessionBanner(
                    item: item,
                    sessionTitle: sessionTitle(for: item),
                    extraCount: crossSessionItems.count - 1,
                    onReview: { reviewCrossSession(item) },
                    onApprove: { Task { await inboxStore.respondApproval(item, approve: true, all: false) } },
                    onDeny: { Task { await inboxStore.respondApproval(item, approve: false, all: false) } },
                    onOpenInbox: { inboxStore.requestPresentation() }
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            if let clarification = chatStore.pendingClarification {
                ClarifyBanner(clarification: clarification, chatStore: chatStore)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            if let toastError {
                errorToast(toastError)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .padding(.horizontal, 12)
        .animation(.spring(response: 0.35, dampingFraction: 0.85),
                   value: chatStore.pendingClarification)
        // Animate on the banner's PRESENCE, not the volatile first-item id: an
        // optimistic respond removes-then-(on failure)-rearms the item, which
        // would thrash an id-keyed animation. Presence-keyed transitions stay
        // smooth across that cycle and across item-to-item swaps.
        .animation(.spring(response: 0.35, dampingFraction: 0.85),
                   value: crossSessionItems.isEmpty)
        .animation(.easeInOut(duration: 0.25), value: toastError)
    }

    /// Pending inbox items belonging to a session OTHER than the one open here
    /// The open session's own approval/clarification is excluded so it
    /// never double-shows alongside the inline ``ApprovalCard`` / ``ClarifyBanner``
    /// (the inbox accumulates ALL sessions' prompts, including the active one).
    /// Compared on the RUNTIME id, which is what both `Item.sessionId` and
    /// `SessionStore.activeRuntimeId` carry.
    private var crossSessionItems: [InboxStore.Item] {
        let activeRuntime = sessionStore.activeRuntimeId ?? ""
        // Also exclude — by id — whatever approval is showing inline RIGHT NOW
        // (ApprovalCard). This is belt-and-suspenders over the runtime filter: it
        // closes the draft / session-switch transition window where
        // `activeRuntimeId` is briefly nil or mid-update but `pendingApproval` is
        // still set, which could otherwise let the same approval show twice.
        let inlineApprovalId = chatStore.pendingApproval?.id
        return inboxStore.pendingItems.filter {
            $0.sessionId != activeRuntime && $0.id != inlineApprovalId
        }
    }

    /// Resolve a human session title for a cross-session inbox item: prefer the
    /// stored id, fall back to the runtime id, matched against the loaded session
    /// list; otherwise a short id stub. Mirrors `InboxView.sessionTitle(for:)`.
    private func sessionTitle(for item: InboxStore.Item) -> String {
        for id in [item.storedSessionId, item.sessionId].compactMap({ $0 }) {
            if let match = sessionStore.sessions.first(where: { $0.id == id }) {
                return match.displayTitle
            }
        }
        let id = item.storedSessionId ?? item.sessionId
        return "Session " + String(id.prefix(8))
    }

    /// Jump to the session a cross-session prompt belongs to so the user can
    /// respond with full context (the inline card / clarify banner then handles
    /// the actual response). If the session isn't in the loaded list, surface the
    /// full Inbox instead so the prompt is still reachable.
    private func reviewCrossSession(_ item: InboxStore.Item) {
        let targetId = item.storedSessionId ?? item.sessionId
        if let summary = sessionStore.sessions.first(where: { $0.id == targetId }) {
            sessionStore.open(summary)
        } else {
            inboxStore.requestPresentation()
        }
    }

    private func errorToast(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(theme.statusWarn)
            Text(message)
                .font(.callout)
                .foregroundStyle(theme.fg)
                .lineLimit(3)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.popover, in: RoundedRectangle(cornerRadius: 12))
    }

    /// Show a transient error toast and schedule its auto-dismiss after 4s.
    private func presentToast(_ message: String?) {
        toastDismissTask?.cancel()
        guard let message, !message.isEmpty else {
            toastError = nil
            return
        }
        toastError = message
        toastDismissTask = Task {
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            toastError = nil
        }
    }

    // MARK: - Toolbar / title

    /// The chat chrome, as a single SYSTEM `.toolbar` used on BOTH widths (I1).
    /// Leading = drawer toggle (`drawerToggle`); principal = humanized session
    /// title; trailing = new-chat (`newChatButton`) + an overflow "…" session
    /// menu (`chatOverflowMenu`). On iOS 26 the system floats these as Liquid
    /// Glass automatically; on 17-25 they render in the classic bar — no custom
    /// pill drawing in either case. The glyph foregrounds use `theme.navBarTint`
    /// so the Hermes tint carries identity over neutral system chrome.
    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        // Leading: drawer toggle. Hidden when no toggle is injected (iPad split
        // view supplies its own sidebar).
        if let onToggleDrawer {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    onToggleDrawer()
                } label: {
                    Image(systemName: "line.3.horizontal")
                        .foregroundStyle(theme.navBarTint)
                }
                .accessibilityLabel("Open menu")
                .accessibilityIdentifier("drawerToggle")
            }
        }

        // Principal: the humanized session title (single line per F3).
        ToolbarItem(placement: .principal) {
            principalTitle
        }

        // Trailing: new-chat pencil → start a fresh draft. Kept as a DIRECT
        // button (outside the overflow menu — Amendment E) so `newChatButton` is
        // a first-class tap target.
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                startNewChat()
            } label: {
                Image(systemName: "square.and.pencil")
                    .foregroundStyle(theme.navBarTint)
            }
            .accessibilityLabel("New chat")
            .accessibilityIdentifier("newChatButton")
        }

        // Trailing: overflow "…" menu of session actions (pin / copy / delete).
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                sessionActionsMenu
            } label: {
                Image(systemName: "ellipsis")
                    .foregroundStyle(theme.navBarTint)
            }
            .accessibilityLabel("Conversation options")
            .accessibilityIdentifier("chatOverflowMenu")
        }
    }

    /// The principal toolbar title. On a fresh draft (`isDraft == true` and no
    /// messages yet) the title band is suppressed — the centred greeting serves
    /// as the identity surface and a title above it creates redundant chrome.
    /// `.navigationTitle` is still set so the system can render a back-button
    /// label and accessibility has a meaningful window title. On existing sessions
    /// the single-line humanized title is shown as before (F3 spec).
    @ViewBuilder
    private var principalTitle: some View {
        if chatStore.messages.isEmpty {
            // EMPTY chat = NO title, ever (Level 02B). Drafts, fresh landings,
            // and empty resumed sessions all fall back to model-id noise
            // ("gpt-5.5"/"claude-opus-4-8") through one path or another —
            // an empty transcript renders a bare glass toolbar instead.
            // NOT EmptyView: an empty principal item makes the system fall
            // back to rendering `.navigationTitle` in its place (the bug that
            // survived the first two gate attempts). A non-empty invisible
            // view occupies the slot so nothing is drawn.
            Color.clear.frame(width: 1, height: 1)
        } else {
            Text(navigationTitle)
                .font(.system(size: navTitleFontSize, weight: .semibold))
                .foregroundStyle(theme.fg)
                .lineLimit(1)
        }
    }

    // MARK: - Compact floating header (STRIKE P0)

    /// The floating glass chrome for the compact standalone path — the visual
    /// equivalent of the I1 system toolbar, but rendered as an `.overlay` so the
    /// chat needs NO NavigationStack (which is what was reserving the transcript's
    /// top/bottom content inset). Cleared below the status bar via the explicit
    /// `compactTopInset` (the card stack ignores the safe area, so the ambient
    /// inset is zero) while the transcript still scrolls full-bleed beneath it.
    ///

    /// Layout mirrors the toolbar: leading drawer toggle, centred title (with the
    /// empty-chat suppression preserved — `principalTitle`), trailing new-chat +
    /// overflow. Every a11y identifier is preserved verbatim (`drawerToggle`,
    /// `newChatButton`, `chatOverflowMenu`) so UI tests and the QA bridge keep
    /// hitting the same targets. Each control floats on its own glass pill
    /// (`chromePill`) — glass on iOS 26, the solid `theme.card` fallback below —
    /// matching the GLASS-FOR-CHROME principle the rest of the app uses.
    private var compactFloatingHeader: some View {
        VStack(spacing: 8) {
            compactHeaderControls
            // Connection banner (B1) lives INSIDE the floating header on compact
            // now — moved off the old external `.safeAreaInset(.top)` because that
            // inset re-established a top safe-area region that defeated the
            // transcript's full-bleed `.ignoresSafeArea`. As an overlay child it
            // floats over the transcript without insetting the scroll surface.
            // EmptyView when `.connected`, so it adds nothing in the nominal case.
            ConnectionStatusBanner()
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .padding(.horizontal, 12)
                .animation(.easeInOut(duration: 0.2), value: connectionStore.phase)
        }
        // Clear the status bar using the EXPLICIT inset threaded down from
        // CompactLayout (the card stack ignores the safe area, so the ambient
        // safe area here is zero — `.safeAreaPadding(.top)` would collapse the
        // header onto the clock/battery). The transcript scroll surface beneath
        // runs to the physical top edge, so content scrolls under these pills.
        .padding(.top, compactTopInset)
        .frame(maxWidth: .infinity, alignment: .top)
    }

    /// The pills row of the compact floating header (drawer / title / new-chat /
    /// overflow). Split out so the header can stack the connection banner beneath.
    private var compactHeaderControls: some View {
        HStack(spacing: 8) {
            if let onToggleDrawer {
                Button {
                    onToggleDrawer()
                } label: {
                    Image(systemName: "line.3.horizontal")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(theme.navBarTint)
                        .frame(width: 38, height: 38)
                        .contentShape(Circle())
                        .chromePill(theme, in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Open menu")
                .accessibilityIdentifier("drawerToggle")
            }

            Spacer(minLength: 8)

            // Centred title — same empty-chat suppression as the toolbar's
            // principal item. When suppressed, `principalTitle` renders a 1pt
            // clear view so no title band is drawn over the greeting.
            principalTitle
                .layoutPriority(1)

            Spacer(minLength: 8)

            Button {
                startNewChat()
            } label: {
                Image(systemName: "square.and.pencil")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(theme.navBarTint)
                    .frame(width: 38, height: 38)
                    .contentShape(Circle())
                    .chromePill(theme, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("New chat")
            .accessibilityIdentifier("newChatButton")

            Menu {
                sessionActionsMenu
            } label: {
                Image(systemName: "ellipsis")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(theme.navBarTint)
                    .frame(width: 38, height: 38)
                    .contentShape(Circle())
                    .chromePill(theme, in: Circle())
            }
            .accessibilityLabel("Conversation options")
            .accessibilityIdentifier("chatOverflowMenu")
        }
        .padding(.horizontal, 12)
        .padding(.top, 4)
        .frame(maxWidth: .infinity)
    }

    // MARK: - Session actions overflow menu (I1 — system toolbar)

    /// Session actions for the toolbar overflow "…" menu: pin / copy / delete map
    /// onto the existing store affordances. Kept inside the Menu so the direct
    /// `newChatButton` toolbar item stays outside it (Amendment E).
    /// Whether the subagent-tree affordance should appear: the gateway emitted at
    /// least one `subagent.*` frame (passive capability) AND the active turn has
    /// recorded subagent activity. A stock gateway shows nothing.
    private var showSubagentAffordance: Bool {
        connectionStore.capabilities.subagentEvents == .available
            && chatStore.hasSubagentActivity
    }

    /// Whether the working-directory affordance should appear: the patched gateway
    /// serves the fs endpoints (`fs != .unavailable`, the same gate as the file
    /// browser / @-mentions) AND there is an active runtime session whose cwd we
    /// can change. A stock gateway shows nothing.
    private var showWorkingDirAffordance: Bool {
        connectionStore.capabilities.fs != .unavailable
            && (sessionStore.activeRuntimeId?.isEmpty == false)
    }

    @ViewBuilder
    private var sessionActionsMenu: some View {
        if showSubagentAffordance {
            Button {
                showingSubagentTree = true
            } label: {
                Label("Subagents", systemImage: "point.3.connected.trianglepath.dotted")
            }
            Divider()
        }
        if showWorkingDirAffordance {
            Button {
                showingWorkingDirPicker = true
            } label: {
                Label("Working Directory", systemImage: "folder.badge.gearshape")
            }
            .accessibilityIdentifier("workingDirMenuItem")
            Divider()
        }
        if let summary = activeSummary {
            Button {
                sessionStore.togglePin(summary)
            } label: {
                Label(sessionStore.pinnedSessions.contains(where: { $0.id == summary.id }) ? "Unpin" : "Pin",
                      systemImage: "pin")
            }
            Button {
                copyTranscript()
            } label: {
                Label("Copy transcript", systemImage: "doc.on.doc")
            }
            // exportMarkdown was REST-wired + unit-tested with zero UI
            // callers. Fetch, then hand off to the share sheet via the
            // `.sheet(item:)` below.
            Button {
                Task {
                    if let markdown = await sessionStore.exportMarkdown(summary) {
                        exportedTranscript = ExportedTranscript(
                            title: summary.displayTitle,
                            text: markdown
                        )
                    }
                }
            } label: {
                Label("Export as Markdown", systemImage: "square.and.arrow.up")
            }
            Divider()
            Button(role: .destructive) {
                Task { await sessionStore.delete(summary) }
            } label: {
                Label("Delete", systemImage: "trash")
            }
        } else {
            Button {
                copyTranscript()
            } label: {
                Label("Copy transcript", systemImage: "doc.on.doc")
            }
            .disabled(chatStore.messages.isEmpty)
        }
    }

    /// The active session summary, if one is open (for the overflow menu).
    private var activeSummary: SessionSummary? {
        guard let id = sessionStore.activeStoredId ?? sessionStore.activeRuntimeId else { return nil }
        return sessionStore.sessions.first { $0.id == id }
    }

    /// Copy the whole transcript to the pasteboard (export affordance).
    private func copyTranscript() {
        let text = chatStore.messages
            .map { $0.text }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
        UIPasteboard.general.string = text
    }

    // MARK: - Scroll-to-bottom pill (compact — F3)

    /// A circular ↓ pill centred above the composer, shown when scrolled up
    /// (`!atBottom`). Lives in the bottom safe-area inset so it renders ABOVE the
    /// bottom scroll-edge effect. Tapping returns to the newest message.
    ///

    /// I1: on iOS 26 it is a system `Button` with `.buttonStyle(.glass)` (verified
    /// against the 26.5 SDK) so it gets the platform Liquid Glass circle for free;
    /// on 17-25 it keeps the `chromePill(in: Circle())` solid fallback. The glyph
    /// carries identity via `theme.navBarTint`, leaving the glass neutral.
    @ViewBuilder
    private func scrollToBottomPill(proxy: ScrollViewProxy) -> some View {
        HStack {
            Spacer(minLength: 0)
            if #available(iOS 26.0, *) {
                Button {
                    withAnimation(.snappy(duration: 0.28, extraBounce: 0)) {
                        proxy.scrollTo(bottomAnchor, anchor: .bottom)
                    }
                } label: {
                    Image(systemName: "arrow.down")
                        .font(.system(size: scrollPillGlyphSize, weight: .semibold))
                        .foregroundStyle(theme.navBarTint)
                        .frame(width: 36, height: 36)
                        .contentShape(Circle())
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .accessibilityLabel("Scroll to bottom")
                .accessibilityAddTraits(.isButton)
                .accessibilityIdentifier("scrollToBottom")
            } else {
                Button {
                    withAnimation(.snappy(duration: 0.28, extraBounce: 0)) {
                        proxy.scrollTo(bottomAnchor, anchor: .bottom)
                    }
                } label: {
                    Image(systemName: "arrow.down")
                        .font(.system(size: scrollPillGlyphSize, weight: .semibold))
                        .foregroundStyle(theme.navBarTint)
                        .frame(width: 36, height: 36)
                        .chromePill(theme, in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Scroll to bottom")
                .accessibilityAddTraits(.isButton)
                .accessibilityIdentifier("scrollToBottom")
            }
            Spacer(minLength: 0)
        }
        .transition(.scale.combined(with: .opacity))
    }

    private var navigationTitle: String {
        if let id = sessionStore.activeStoredId ?? sessionStore.activeRuntimeId,
           let summary = sessionStore.sessions.first(where: { $0.id == id }) {
            // Shared humanization (design audit C3) — see
            // `SessionSummary.displayHumanTitle`, also used by `DrawerSessionRow`.
            return summary.displayHumanTitle
        }
        return activeModelName ?? "Hermes"
    }

    /// Model name surfaced for the title chip. Prefers the caller-supplied
    /// `modelName` (RootView feeds `ConnectionStore.activeModelName` down this
    /// path); falls back to reading the store directly so the chip still renders
    /// if a call site omits the prop (F0 / Amendment B). `nil` → chip hidden.
    private var activeModelName: String? {
        if let model = modelName, !model.isEmpty { return model }
        if let stored = connectionStore.activeModelName, !stored.isEmpty { return stored }
        return nil
    }

    /// Start a fresh chat — the injected draft hook when present, otherwise fall
    /// back to `startDraft()` so the button is never a no-op (interactive new-chat
    /// uses the draft path; the eager `createSessionNow()` is for programmatic
    /// flows only).
    private func startNewChat() {
        if let onNewChat {
            onNewChat()
        } else {
            sessionStore.startDraft()
        }
    }

    // MARK: - Connection

    private var isConnected: Bool {
        guard case .connected = connectionStore.phase else { return false }
        // A fresh draft (chat-as-home) has no runtime yet — `ChatStore.send`
        // creates the gateway session lazily on the first prompt — so the
        // composer must be enabled the moment the gateway is connected.
        if sessionStore.isDraft { return true }
        // For a resumed/active session, sending also needs the runtime, which
        // resumes in the background after an instant open — the composer stays
        // disabled (transcript already visible) until it lands.
        return sessionStore.activeRuntimeId != nil
    }

    /// True whenever the gateway WebSocket is connected, regardless of whether the
    /// session runtime has landed yet. Used to SHOW (not execute) context-menu
    /// actions on existing sessions so that a resumed session doesn't strip the
    /// menu down to just "Copy" during the resume window. Actions are shown but
    /// disabled (via `menuActionsEnabled`) until the runtime is live and the store
    /// is ready to accept them.
    private var isGatewayConnected: Bool {
        if case .connected = connectionStore.phase { return true }
        return false
    }

    // MARK: - Edit & retry

    /// Whether mutable context-menu actions (Edit / Retry / Restore / Branch) are
    /// currently executable. Requires:
    ///  1. A live runtime session (`isConnected` — covers draft path too).
    ///  2. No local turn in flight (`!chatStore.localTurnInFlight`).
    ///

    /// This is the gate passed as `MessageBubble.menuActionsEnabled` — when false
    /// the buttons are SHOWN but disabled rather than hidden, so a resumed session
    /// that hasn't yet received its runtime id still surfaces the actions (meeting
    /// the/03E requirement). The store's own `localTurnInFlight` guard is an
    /// independent execution-time safety net (belt-and-suspenders: even if a caller
    /// forgets `menuActionsEnabled`, the store rejects a busy edit/checkpoint).
    ///

    /// Why NOT gating on `!isStreaming` (old predicate):
    ///  `isStreaming` can be true for a *foreign* turn that we are mirroring —
    ///  blocking our own actions on a foreign stream is unnecessary. The store's
    ///  `localTurnInFlight` token is the correct ownership predicate (
    ///  Batch C). `!chatStore.isStreaming` is a looser proxy; keeping only
    ///  `!chatStore.localTurnInFlight` is both more correct and more permissive.
    static func menuActionsGate(isConnected: Bool, localTurnInFlight: Bool) -> Bool {
        isConnected && !localTurnInFlight
    }

    private var menuActionsEnabled: Bool {
        Self.menuActionsGate(isConnected: isConnected, localTurnInFlight: chatStore.localTurnInFlight)
    }

    /// Edit handler passed to user bubbles — non-nil whenever the gateway is
    /// connected (action SHOWN). `menuActionsEnabled` controls whether it is
    /// enabled or disabled at tap time.
    private var editHandler: ((ChatMessage) -> Void)? {
        guard isGatewayConnected else { return nil }
        return { message in
            guard menuActionsEnabled else { return }
            editDraft = message.text
            editingMessage = message
        }
    }

    /// Retry handler passed to assistant bubbles — non-nil whenever the gateway is
    /// connected. `menuActionsEnabled` gates execution.
    private var retryHandler: ((ChatMessage) -> Void)? {
        guard isGatewayConnected else { return nil }
        return { message in
            guard menuActionsEnabled else { return }
            Task { await chatStore.retry(fromAssistantId: message.id) }
        }
    }

    /// Restore-checkpoint handler passed to user bubbles (F4A-A2) — non-nil
    /// whenever the gateway is connected. `menuActionsEnabled` gates execution.
    private var restoreCheckpointHandler: ((ChatMessage) -> Void)? {
        guard isGatewayConnected else { return nil }
        return { message in
            guard menuActionsEnabled else { return }
            Task { await chatStore.restoreCheckpoint(toUserMessageId: message.id) }
        }
    }

    /// Branch-from-here handler (F4A-A2) — opens a NEW chat seeded with history up
    /// to the chosen message. Non-nil whenever the gateway is connected (branch does
    /// not interrupt an in-flight turn, so it is less restrictive than edit/retry).
    /// `menuActionsEnabled` gates execution for consistency (branch requires an
    /// active runtime to supply the cwd).
    private var branchHandler: ((ChatMessage) -> Void)? {
        guard isGatewayConnected else { return nil }
        return { message in
            guard menuActionsEnabled else { return }
            let seed = chatStore.branchSeed(upToMessageId: message.id)
            guard !seed.isEmpty else { return }
            Task {
                do {
                    // Branch in the active session's cwd so the new chat starts in
                    // the same workspace.
                    let cwd = activeSummary?.cwd
                    let ids = try await sessionStore.branchSession(seed: seed, cwd: cwd)
                    sessionStore.land(storedId: ids.storedId, runtimeId: ids.runtimeId)
                } catch {
                    // The store already surfaced `lastError`; nothing more to do.
                }
            }
        }
    }
}

// MARK: - Edit sheet

/// A minimal sheet to edit a user message before resending. Save is disabled
/// while the text is empty; Cancel discards.
private struct EditMessageSheet: View {
    let original: ChatMessage
    @Binding var text: String
    let onSave: (String) -> Void
    let onCancel: () -> Void

    @Environment(\.hermesTheme) private var theme
    @FocusState private var focused: Bool

    private var trimmed: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                TextField("Edit message…", text: $text, axis: .vertical)
                    .focused($focused)
                    .lineLimit(3...12)
                    .padding(12)
                    .background(theme.input, in: RoundedRectangle(cornerRadius: 12))
                    .padding(16)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(theme.bg)
            .navigationTitle("Edit message")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { onCancel() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save & Send") { onSave(trimmed) }
                        .disabled(trimmed.isEmpty)
                        .fontWeight(.semibold)
                }
            }
            .onAppear { focused = true }
        }
        .presentationDetents([.medium, .large])
    }
}

// MARK: - Transcript scroll-edge effect (I1)

/// The transcript's top + bottom edge treatment.
///

/// HONEST native-vs-custom note (verified against iPhoneSimulator 26.x
/// SDK — `ScrollEdgeEffectStyle.soft`/`.hard`, `scrollEdgeEffectHidden` — AND
/// pixel-tested on-sim, iPhone 17 Pro / iOS 26.3):
///

/// - The native `scrollEdgeEffectStyle(.soft, for:)` IS a real iOS 26 primitive
///  and renders without an opaque nav-bar platter (the platter was a separate
///  UINavigationBar concern, killed by `.toolbarBackground(.hidden)`). BUT it
///  is **inset-sized and non-tunable**: its dissolve spans only ≈the safe-area
///  inset, its alpha curve is fixed, and there is no API to widen it to the
///  ~135 pt top / ~150 pt bottom legibility bands this screen needs. `.hard`
///  draws a divider line — the opposite of the gradual look. So native alone
///  CANNOT make the header pills + status icons legible over a muted band.
///

/// - I also pixel-tested COMPOSITING native `.soft` on TOP of the mask. It did
///  not just under-deliver — it actively HURT the gradient: the native edge
///  treatment re-introduced FULL-darkness transcript text into the header band
///  (darkest-3% luminance dropped to ≈23 at y≈10% — i.e. crisp black text
///  right where the pills sit), defeating the mute and giving a harder, less
///  monotonic ramp than the mask alone (mask-only stepped a clean 145→127→118
///  →104; the composite jumped 23↔248). The user's directive is a GRADUAL,
///  increasing-strength fade with a LEGIBLE header, so the composite is the
///  wrong tool here.
///

/// - SHIPPED DECISION: the **custom `EdgeFadeMask` is the sole source of the
///  look on ALL OS versions, including iOS 26.** It owns the band height and the
///  eased (gradual, increasing-strength) alpha curve the user asked for, and it
///  produces a clean monotonic dissolve that keeps the header pills + status
///  icons legible over heavily-muted content. The native `.soft` path is left
///  here behind a debug-only env gate (`HERMES_NATIVE_EDGE_ON`) purely so the
///  comparison can be re-run; it is OFF by default and ships off.
///

/// (`DrawerBottomFade` still uses native `.soft` for its simpler bottom-only,
/// capsule-covering case where the inset-sized native dissolve is sufficient —
/// the chat transcript's 135/150 pt readability bands are a stronger requirement
/// that only the mask can meet.)
private struct TranscriptEdgeEffect: ViewModifier {
    func body(content: Content) -> some View {
        // Custom mask is the SHIPPED look on every OS version — it is the only
        // path that delivers the tunable 135/150 pt eased band with a legible
        // header (see the type doc for the pixel-verified native rejection).
        //

        // DEBUG experiment (round-2 scroll forensics): HERMES_EXP_NO_EDGEMASK=1
        // disables the full-transcript `.mask` to measure how much the mask's
        // per-frame offscreen re-rasterization of the scrolling content costs.
        #if DEBUG
        let maskEnabled = ProcessInfo.processInfo.environment["HERMES_EXP_NO_EDGEMASK"] != "1"
        #else
        let maskEnabled = true
        #endif
        let masked = content.modifier(EdgeFadeMask(enabled: maskEnabled))
        // Debug-only: opt IN to compositing native `.soft` for A/B re-testing.
        // Ships OFF; the mask alone is the production path.
        let nativeOn = ProcessInfo.processInfo.environment["HERMES_NATIVE_EDGE_ON"] == "1"
        if #available(iOS 26.0, *), nativeOn {
            return AnyView(masked.scrollEdgeEffectStyle(.soft, for: [.top, .bottom]))
        } else {
            return AnyView(masked)
        }
    }
}

/// Fades the scroll content at the top and bottom via a vertical alpha gradient
/// `mask` — the SOLE source of the readability bands on ALL OS versions including
/// iOS 26 (the native `.soft` effect is inset-sized/non-tunable and, when
/// composited, leaked full-darkness text into the header band — pixel-verified
/// and rejected; see `TranscriptEdgeEffect`).
///

/// The mask applies ONLY to the scrolling transcript — the scroll-to-bottom
/// pill, toast, and composer live in overlays / safe-area insets layered OUTSIDE
/// the masked view, so they stay fully opaque ABOVE the mask.
///

/// USER DIRECTIVE: the clear/full-content region must begin right UNDER
/// the floating header and right ABOVE the composer, and the fade must be GRADUAL
/// and increasing in strength so the edge is muted ENOUGH that the header pills +
/// status icons are LEGIBLE over the dissolving content. The previous 0.35/0.40
/// edge alphas left content ~35-40% visible — far too legible (it competed with
/// the chrome). The edge now dissolves to ≈0 (heavily muted, near background) and
/// ramps up via an eased multi-stop curve (ease-in: barely-present at the very
/// edge, accelerating to full opacity at the clear band) rather than a flat line.
private struct EdgeFadeMask: ViewModifier {
    let enabled: Bool
    @Environment(\.colorScheme) private var colorScheme

    /// Height of each fade band, in points.
    /// Top: spans the status bar + the floating header pills so content is fully
    /// dissolved at the screen edge and reaches FULL opacity right below the
    /// header. safeTop (~59 on iPhone 17 Pro) + header pills (~46) + breathing
    /// room ⇒ ~135 pt, so the clear band starts clearly UNDER the pills (the
    /// whole status-bar + pill zone stays heavily muted, not just the top half).
    /// Bottom: spans the floating composer region (composer height + the
    /// `controlBottomBaseline` + home indicator) so content dissolves starting
    /// at the composer's top edge downward — clear band ends right above it.
    ///

    /// Sourced from `ChatView.transcriptTopFadeBand` (the single source of truth)
    /// so the resting-message TOP inset (FIX 2, `ChatView.transcriptTopInset`)
    /// stays reconciled with the fade band: the first message must rest in the
    /// CLEAR zone just below this band, never inside the dissolve.
    private let topFade: CGFloat = ChatView.transcriptTopFadeBand
    // User tweak: a smaller bottom band so the CLEAR region extends lower — the
    // dissolve starts closer to the composer's top edge (was 150).
    private let bottomFade: CGFloat = 110

    /// Eased multi-stop ramp for ONE edge, expressed as fractional positions
    /// within that edge's band (0 = the very screen edge, 1 = the clear band)
    /// paired with the content alpha there. Ease-in shape: alpha is held at ≈0
    /// across the FIRST HALF of the band (the status-bar + header-pill zone stays
    /// deeply muted so the chrome's dark glyphs always win), then accelerates to
    /// full opacity over the back half — a gradual, increasing-in-strength
    /// dissolve, not a flat/linear one and not a hard step. The long near-zero
    /// shoulder is what makes the header legible over muted content.
    private static let easeStops: [(frac: CGFloat, alpha: Double)] = [
        (0.00, 0.00),
        (0.30, 0.00),
        (0.48, 0.03),
        (0.62, 0.10),
        (0.74, 0.26),
        (0.85, 0.52),
        (0.94, 0.82),
        (1.00, 1.00)
    ]

    /// In dark mode, an ultra-low shoulder (near 0 alpha for a long portion of
    /// the top band) reads like a persistent dark blur above the transcript.
    /// Keep the same geometry, but soften the curve so content remains subtly
    /// present near the edge while still fading under the floating header.
    private static let darkEaseStops: [(frac: CGFloat, alpha: Double)] = [
        (0.00, 0.14),
        (0.28, 0.18),
        (0.46, 0.30),
        (0.62, 0.46),
        (0.76, 0.66),
        (0.88, 0.84),
        (0.96, 0.94),
        (1.00, 1.00)
    ]

    func body(content: Content) -> some View {
        if enabled {
            content.mask(alignment: .top) {
                GeometryReader { proxy in
                    let h = max(proxy.size.height, 1)
                    let topBand = min(0.5, topFade / h)
                    let bottomBand = min(0.5, bottomFade / h)
                    let stops = colorScheme == .dark ? Self.darkEaseStops : Self.easeStops
                    LinearGradient(
                        stops: Self.maskStops(topBand: topBand, bottomBand: bottomBand, easeStops: stops),
                        startPoint: .top,
                        endPoint: .bottom
                    )
                }
            }
        } else {
            content
        }
    }

    /// Build the full gradient: eased ramp UP across the top band, solid black
    /// (full content) through the clear middle, eased ramp DOWN across the bottom
    /// band. Locations are absolute (0...1) over the transcript height.
    private static func maskStops(
        topBand: CGFloat,
        bottomBand: CGFloat,
        easeStops: [(frac: CGFloat, alpha: Double)]
    ) -> [Gradient.Stop] {
        var stops: [Gradient.Stop] = []
        // Top edge: edge (frac 0) → clear band (frac 1), mapped into [0, topBand].
        for s in easeStops {
            stops.append(.init(color: .black.opacity(s.alpha), location: s.frac * topBand))
        }
        // Clear middle band — full content opacity.
        stops.append(.init(color: .black, location: topBand))
        stops.append(.init(color: .black, location: 1 - bottomBand))
        // Bottom edge: clear band (frac 1) → edge (frac 0), mapped into
        // [1 - bottomBand, 1] in REVERSE so the curve mirrors the top.
        for s in easeStops.reversed() {
            let loc = (1 - bottomBand) + (1 - s.frac) * bottomBand
            stops.append(.init(color: .black.opacity(s.alpha), location: loc))
        }
        return stops
    }
}

// MARK: - Chat toolbar background (I1)

private extension View {
    /// STRIKE P0: apply the I1 system-toolbar chrome (background + title + items)
    /// ONLY when a NavigationStack hosts this surface (`enabled` — the iPad split
    /// path). On the compact standalone path (`enabled == false`) this is a no-op,
    /// because there is no stack to host a `.toolbar` and the chat draws its own
    /// `compactFloatingHeader` overlay instead. Keeping all three system-chrome
    /// modifiers behind one gate means the compact card NEVER touches the system
    /// nav bar, so nothing reserves a content inset.
    @ViewBuilder
    func applyingSystemChatChrome<T: ToolbarContent>(
        enabled: Bool,
        isCompact: Bool,
        toolbarBg: Color,
        navigationTitle: String,
        @ToolbarContentBuilder _ toolbar: () -> T
    ) -> some View {
        if enabled {
            self
                .applyingChatToolbarBackground(isCompact: isCompact, toolbarBg: toolbarBg)
                .navigationTitle(navigationTitle)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar(content: toolbar)
        } else {
            self
        }
    }

    /// Applies the chat nav-bar BACKGROUND. The toolbar ITEMS render on both
    /// widths now (I1 — system `.toolbar`); only the bar background differs:
    ///

    /// - **Compact (iPhone):** let the system default the nav-bar background. On
    ///  iOS 26 that means the items float as Liquid Glass over the transparent
    ///  bar and the full-bleed chat card (`chatCardSurface`, the geometry fix)
    ///  shows through beneath the chrome — NO opaque band reintroduced. On 17-25
    ///  the system supplies its standard scroll-edge bar appearance.
    /// - **Regular (iPad):** keep the existing themed opaque nav bar (design
    ///  audit C3) so the split-view detail chrome is untouched.
    @ViewBuilder
    func applyingChatToolbarBackground(isCompact: Bool, toolbarBg: Color) -> some View {
        if isCompact {
            // Full-bleed round 3 (user reference spec): the transcript canvas
            // owns every pixel — the system must NEVER paint a bar background
            // (on iOS 26 the default hard scroll-edge appearance becomes an
            // opaque band once content scrolls under the title). Items float
            // as glass; readability comes from EdgeFadeMask's top fade only.
            self
                .toolbarBackground(.hidden, for: .navigationBar)
        } else {
            self
                .toolbarBackground(toolbarBg, for: .navigationBar)
                .toolbarBackground(.visible, for: .navigationBar)
        }
    }
}

// MARK: - Turn activity bar

/// A thin status strip shown above the composer while a turn streams: a spinner,
/// the currently-running tool's name (if any), and the elapsed time since
/// `turnStartedAt`.
///

/// The stop (interrupt) affordance lives ONLY on the composer's morph button now
/// (H4 / single-stop-affordance principle): while streaming, the composer's
/// docked action becomes the "Interrupt" glyph, so a duplicate stop button on
/// this bar would be a second, competing affordance. The bar is therefore a
/// pure read-only status strip with no interactive controls — which is also why
/// `ChatFlowUITests` asserts no "Stop turn" button is ever present.
private struct TurnActivityBar: View {
    let chatStore: ChatStore

    @Environment(\.hermesTheme) private var theme

    /// Drives a ~1Hz re-render so the elapsed label ticks. Local timeline state;
    /// the source of truth for "is a turn running" remains `chatStore`.
    @State private var now = Date()
    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.mini)
            Text(statusText)
                .font(.caption)
                .foregroundStyle(theme.mutedFg)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity)
        .background(theme.card, in: Capsule())
        .padding(.horizontal, 12)
        .onReceive(tick) { now = $0 }
    }

    private var statusText: String {
        var parts: [String] = []
        if let name = chatStore.activeToolName, !name.isEmpty {
            parts.append(name)
        } else {
            parts.append("Working")
        }
        parts.append(elapsedText)
        return parts.joined(separator: " · ")
    }

    private var elapsedText: String {
        guard let started = chatStore.turnStartedAt else { return "0s" }
        let elapsed = now.timeIntervalSince(started)
        let seconds = max(0, Int(elapsed))
        if seconds < 60 { return "\(seconds)s" }
        return elapsed.mmss
    }
}
