import PhotosUI
import SwiftUI
import UIKit

/// The bottom input: a TWO-ROW rounded card (F3 composer — Claude-iOS anatomy).
///

/// The card (theme.card fill, theme.border 1pt, subtle shadow) holds:
///  - **Row 1**: the message `TextField` (axis vertical, 1–6 lines), or the
///  recording strip while a capture is live.
///  - **Row 2**: the attach ("+") button, the MODEL CHIP (relocated here from
///  the nav header — tap → model picker; renders only when the gateway's
///  running model is known), a spacer, then a single context-sensitive action:
///  - mic when there's nothing to send (TAP → tap-to-record strip;
///  LONG-PRESS ≥0.35s → hold-to-talk, slide away to cancel),
///  - send arrow (filled `theme.fg` circle) once there's text or a pending
///  attachment — morphing in via a `.replace` symbol transition,
///  - while the agent streams: a stop (interrupt) glyph, or a queue glyph
///  when there is queueable text (so the queue affordance survives).
/// A pending-attachment thumbnail strip and a "N queued" chip sit above the card
/// when present; the recording strip replaces Row 1 while a capture is live.
struct ComposerView: View {
    /// The chat store driving send / interrupt.
    let chatStore: ChatStore
    /// The store holding queued image attachments.
    let attachmentStore: AttachmentStore
    /// Whether the gateway connection is live. When false, send is disabled.
    let isConnected: Bool

    /// Voice dictation engine (mic → transcript).
    @Environment(VoiceRecorder.self) private var recorder
    /// Persistent prompt queue / offline outbox.
    @Environment(QueueStore.self) private var queueStore
    /// REST client (transcription endpoint); nil when unconfigured.
    @Environment(ConnectionStore.self) private var connection
    /// Session store — the active runtime session id threads into the @-file
    /// completion RPC so `complete.path` resolves against the session's cwd.
    @Environment(SessionStore.self) private var sessions
    /// Resolved theme palette for this surface.
    @Environment(\.hermesTheme) private var theme
    /// Theme store, re-applied at the queue-sheet presentation root.
    @Environment(ThemeStore.self) private var themeStore

    @State private var text = ""
    @FocusState private var isFocused: Bool

    /// Incremented each time a message is sent (or queued) to trigger
    /// `.sensoryFeedback` on the most-frequent action. Separate counters keep
    /// the send and queue feedbacks distinct without sharing a single trigger.
    @State private var sendFeedbackTrigger = 0
    @State private var queueFeedbackTrigger = 0

    /// The photo-library picker selection (loaded as Data, converted to JPEG).
    @State private var photoItem: PhotosPickerItem?
    /// Drives the Photos picker via a top-level `.photosPicker(isPresented:)`
    /// modifier. A `PhotosPicker` nested inside the attach `Menu` silently fails
    /// to present on device (the menu dismisses, no picker appears — build-29
    /// QA bug); the state-driven presentation matches camera/scanner/files.
    @State private var showPhotoPicker = false
    /// Surfaced when a picked photo fails to load (release audit P1 — was a
    /// silent `try?` and the image just vanished).
    @State private var photoLoadError: String?
    /// Whether the camera sheet is up.
    @State private var showCamera = false
    /// Whether the document scanner is up.
    @State private var showScanner = false
    /// Whether the file-browser sheet (F4A-A1 `FileBrowserView`) is up. Reached
    /// from the attach dialog's "Browse Files" entry, gated on `fs` support.
    @State private var showFileBrowser = false

    /// Whether the microphone-denied alert is showing.
    @State private var showMicDeniedAlert = false
    /// Whether the queue-management sheet is up.
    @State private var showQueueSheet = false
    /// Whether the model-picker sheet (tapped from the Row-2 model chip) is up.
    /// The chip + this sheet are the F3 relocation of the old nav-header chip.
    @State private var showModelPicker = false

    /// True once a hold-to-talk long-press has fired and a capture is live. Drives
    /// the press visuals and tells the drag handler whether a slide-away should
    /// cancel an in-flight recording.
    @State private var holdActive = false
    /// True while the hold-to-talk drag has slid far enough off the mic to mean
    /// "release here to cancel"; the strip reflects this so the user knows.
    @State private var holdWillCancel = false

    private var trimmed: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// True while the recorder is capturing or transcribing — the input row is
    /// replaced by the recording strip in that state.
    private var isCapturing: Bool {
        switch recorder.state {
        case .idle: return false
        case .recording, .transcribing: return true
        }
    }

    /// While a turn is live on this stored session — a local one or an adopted
    /// foreign mirror — the send button enqueues instead of sends (both mean
    /// the session is busy; they differ in what STOP targets, which
    /// `ChatStore.interrupt()` routes to the stream's own runtime).
    /// DISCONNECTED with queueable text also enters queue mode: that is the
    /// offline outbox's front door — previously the enqueue affordance only
    /// existed while streaming, so the persisted outbox + reconnect-drain
    /// machinery was unreachable dead code.
    private var isQueueMode: Bool {
        chatStore.isStreaming || (!isConnected && canQueue)
    }

    /// Send is allowed with text, OR with at least one pending attachment (an
    /// image with no caption is sent with a default prompt — see `ChatStore.send`).
    private var canSend: Bool {
        isConnected && (!trimmed.isEmpty || attachmentStore.hasPending)
    }

    /// Camera is only offered on hardware that has one (the simulator does not).
    private var cameraAvailable: Bool {
        UIImagePickerController.isSourceTypeAvailable(.camera)
    }

    /// Whether the gateway supports `POST /api/upload`. The attach ("+") flow —
    /// photo / camera / scan — all funnel through upload, so when the server is
    /// known NOT to support it (stock gateway, E1) the whole menu has nothing to
    /// offer and the "+" button is hidden. `.unknown`/`.available` keep it shown
    /// (optimistic until a probe proves otherwise).
    private var uploadSupported: Bool {
        connection.capabilities.upload != .unavailable
    }

    /// Whether the gateway supports the F4A file endpoints (`GET /api/fs/list` /
    /// `/api/fs/read`). The @-file mention picker rides the SAME patched server,
    /// so when `fs` is known unavailable (stock gateway) the `@`-trigger is fully
    /// suppressed — typing `@` is just literal text, exactly as on a stock build.
    /// `.unknown`/`.available` keep it live (optimistic until proven otherwise).
    private var fileMentionsSupported: Bool {
        connection.capabilities.fs != .unavailable
    }

    /// The user's @-mention preference (default ON). Combined with the hard `fs`
    /// gate: BOTH must hold for the picker to appear.
    private var mentionsEnabled: Bool {
        fileMentionsSupported && DefaultsKeys.mentionAutocompleteEnabledValue()
    }

    /// The in-progress `@`-mention at the cursor, if any. Drives the picker.
    /// Re-derived from `text` on every keystroke; `nil` ⇒ no picker.
    private var activeMention: MentionCompletion.ActiveMention? {
        guard mentionsEnabled, isConnected, isFocused else { return nil }
        return MentionCompletion.activeMention(in: text)
    }

    var body: some View {
        VStack(spacing: 8) {
            if !queueStore.items.isEmpty {
                queueChip
            }
            if attachmentStore.hasPending {
                attachmentStrip
            }
            if let mention = activeMention {
                MentionPicker(
                    client: connection.client,
                    sessionId: sessions.activeRuntimeId,
                    query: mention.query,
                    onSelect: { item in insertMention(item, replacing: mention) }
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            composerCard
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        // Task 3: the outer opaque toolbarBg strip is removed so the
        // composer floats as a glass card over the transcript. The glass card
        // surface (ComposerCardSurface) is the only opaque/glass layer. The
        // readability fade behind the whole bottom stack is supplied by ChatView's
        // bottomStack .background modifier (iOS 17-25) or the system
        // scrollEdgeEffectStyle (iOS 26).
        .animation(.easeInOut(duration: 0.16), value: activeMention != nil)
        .animation(.easeInOut(duration: 0.18), value: isCapturing)
        .animation(.easeInOut(duration: 0.18), value: queueStore.items.count)
        .animation(.snappy(duration: 0.16), value: holdActive)
        // Session hot-swap picker — a half-height sheet (drag up to full,
        // like the Inbox) anchored to the composer chip. Sends config.set with
        // session_id so changes are scoped to the current chat only. The global
        // default lives in Settings.
        .sheet(isPresented: $showModelPicker) {
            // The picker works at ANY point — with a live session it hot-swaps
            // via config.set; on a DRAFT (no session yet) it pends the pick,
            // which applies the moment the first message materializes the
            // session (so even the first turn runs on the chosen model).
            SessionModelPickerContent(
                connection: connection,
                sessionId: (sessions.activeRuntimeId?.isEmpty == false) ? sessions.activeRuntimeId : nil,
                themeStore: themeStore,
                isPresented: $showModelPicker
            )
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
            .hermesThemed(themeStore)
        }
        .alert("Microphone Access Needed", isPresented: $showMicDeniedAlert) {
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Enable microphone access in Settings to dictate messages to Hermes.")
        }
        .sheet(isPresented: $showQueueSheet) {
            QueueSheet(queueStore: queueStore, chatStore: chatStore)
                .hermesThemed(themeStore)
        }
        .photosPicker(
            isPresented: $showPhotoPicker,
            selection: $photoItem,
            matching: .images
        )
        .fullScreenCover(isPresented: $showCamera) {
            CameraPicker { data in
                if let data { attachmentStore.add(data: data) }
                showCamera = false
            }
            .ignoresSafeArea()
        }
        .fullScreenCover(isPresented: $showScanner) {
            DocumentScanner(onComplete: { pages in
                for data in pages { _ = attachmentStore.add(data: data) }
                showScanner = false
            }, onCancel: {
                showScanner = false
            })
            .ignoresSafeArea()
        }
        .sheet(isPresented: $showFileBrowser) {
            // F4A-A1 file browser mounted on the chat surface (iPhone sheet). Only
            // reachable when `fs != .unavailable` and a REST client exists; the
            // view degrades safely on an empty/404 listing.
            // The sheet root owns the ONE NavigationStack (— drill-ins
            // push within it) and BOTH branches get Done dismiss chrome — the
            // draft/no-session branch was a bare ContentUnavailableView with
            // only swipe-to-dismiss.
            NavigationStack {
                Group {
                    if let control = connection.control,
                       let sessionId = sessions.activeRuntimeId, !sessionId.isEmpty {
                        // P4 cache-on-access: thread the (server, profile) scope so
                        // FileViewerView can serve/store image blobs from disk.
                        FileBrowserView(
                            rest: control,
                            sessionId: sessionId,
                            onMentionFile: { path in
                                // Wire the "@" button (was a no-op → no visible
                                // feedback, build-29 QA): append a @file: token to
                                // the composer, close the browser, refocus.
                                text = MentionCompletion.appendMention(path: path, to: text)
                                showFileBrowser = false
                                isFocused = true
                            },
                            serverId: connection.serverURLString,
                            profileId: sessions.activeProfile
                        )
                    } else {
                        ContentUnavailableView(
                            "No Active Session",
                            systemImage: "folder",
                            description: Text("Open a chat to browse its working directory.")
                        )
                        .navigationTitle("Files")
                        .navigationBarTitleDisplayMode(.inline)
                    }
                }
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { showFileBrowser = false }
                    }
                }
            }
            .hermesThemed(themeStore)
        }
        .onChange(of: photoItem) { _, newItem in
            guard let newItem else { return }
            Task {
                // loadTransferable(Data) yields the original bytes (often HEIC);
                // AttachmentStore normalises to JPEG on add. A Photos failure
                // must SURFACE — the picked image silently vanishing was a
                // release-audit P1.
                do {
                    if let data = try await newItem.loadTransferable(type: Data.self) {
                        attachmentStore.add(data: data)
                    } else {
                        photoLoadError = "That photo couldn't be loaded. Try another."
                    }
                } catch {
                    photoLoadError = "Couldn't load the photo: \(error.localizedDescription)"
                }
                photoItem = nil
            }
        }
        .alert("Photo Error", isPresented: Binding(
            get: { photoLoadError != nil },
            set: { if !$0 { photoLoadError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(photoLoadError ?? "")
        }
        .onAppear {
            // Deliver watchdog (B3) / interruption (B4) SALVAGE transcripts into
            // the field — the recorder ends those captures itself (no explicit
            // stop call site to receive the text), so register the same append
            // the manual stop flow uses. Generation-guarded inside the recorder
            // a race-cancelled salvage never fires this.
            recorder.onSalvagedTranscript = { transcript in
                appendTranscript(transcript)
            }
        }
    }

    // MARK: - Two-row card

    /// The composer card: a rounded-rect surface holding the message field on
    /// Row 1 and the action row on Row 2.
    ///

    /// B1 — the gesture HOST must survive the field↔strip transition.
    /// Previously the whole card body was swapped out (`if isCapturing { strip }
    /// else { field + actionRow }`), which DESTROYED the mic's in-flight
    /// `LongPress→Drag` recognizer the instant a hold flipped `isCapturing` — and
    /// when SwiftUI then dropped `.onEnded`, the recorder wedged in `.recording`
    /// with no way out. Now `field + actionRow` STAYS mounted across the capture
    /// and the `RecordingStrip` is laid OVER it as an `.overlay`. The mic glyph —
    /// the `holdToTalkGesture` host — never leaves the tree, so `.onEnded` always
    /// fires; B2's always-reachable strip stop/cancel buttons are the second net.
    ///

    /// I3 — the container is a SYSTEM surface: on iOS 26+ a `glassEffect`
    /// (verified iOS 26 API) clipped to the 24pt rounded rect; on 17–25 the
    /// established solid treatment (theme.card fill + hairline border + soft
    /// lift shadow). The focus ring rides ON TOP in BOTH eras (a stroke overlay):
    /// `composerRing` when focused, `border` otherwise — so the focus affordance
    /// composes over glass exactly as it did over the solid fill. The custom
    /// two-row LAYOUT is retained (no system chat composer exists); every ELEMENT
    /// inside is a system primitive.
    private var composerCard: some View {
        // Keep the focus ring stable while mention completion is active to avoid
        // rapid border color toggles (blue flicker) during transient focus churn.
        let showsFocusRing = isFocused || activeMention != nil
        return VStack(spacing: 8) {
            composerField
            actionRow
        }
        // Keep the field+actionRow MOUNTED while capturing (so the mic's in-flight
        // hold recognizer is never torn down — that teardown is the wedge)
        // but visually yield the card to the strip via opacity. Do NOT `.disabled`
        // the rows: disabling tears down the very recognizer we are preserving, so
        // a hold-release's `.onEnded` would stop firing again. The strip is laid
        // over the top and intercepts NEW touches; a hold gesture that has already
        // begun tracking keeps receiving `.onEnded` from its still-mounted host.
        .opacity(isCapturing ? 0 : 1)
        .accessibilityHidden(isCapturing)
        .overlay {
            if isCapturing {
                RecordingStrip(
                    recorder: recorder,
                    isHoldMode: recorder.isHoldToTalk,
                    willCancel: holdWillCancel,
                    // Reset the composer's hold @State alongside the recorder
                    // action so a strip-button escape (B2) — used when a hold's
                    // `.onEnded` was dropped — also clears `holdActive`/
                    // `holdWillCancel`, leaving the mic glyph un-armed.
                    onCancel: {
                        resetHoldState()
                        recorder.cancel()
                    },
                    onStop: {
                        resetHoldState()
                        stopAndTranscribe()
                    }
                )
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .modifier(ComposerCardSurface(theme: theme, cornerRadius: 24))
        .overlay(
            RoundedRectangle(cornerRadius: 24)
                .strokeBorder(showsFocusRing ? theme.composerRing : theme.border, lineWidth: 1)
        )
        // Send haptic — the most frequent action, fires on every message sent.
        // `.impact(flexibility:intensity:)` available iOS 17+; maps to the
        // desktop's "submit" haptic pattern (a soft but crisp confirmation
        // pulse distinct from the medium hold-start impact).
        .sensoryFeedback(.impact(flexibility: .soft, intensity: 0.8), trigger: sendFeedbackTrigger)
        // Queue haptic — lighter than send; enqueue is transient, not final.
        .sensoryFeedback(.impact(flexibility: .rigid, intensity: 0.5), trigger: queueFeedbackTrigger)
    }

    /// Row 2: attach ("+"), the model chip, a spacer, the mic glyph, and the
    /// dark filled action circle (send / stop / queue). Hidden while a capture is
    /// live (the recording strip takes over the card).
    ///

    /// CC-12 — animate the trailing slot's mode transitions (mic↔send↔stop/queue)
    /// with a snappy spring so the circle appears to morph in/out as content changes
    /// rather than swapping abruptly. The symbol morph inside the glyph (`replace`
    /// contentTransition) handles the symbol itself; this layer handles the outer
    /// layout switch between the three `@ViewBuilder` branches.
    private var actionRow: some View {
        HStack(spacing: 10) {
            attachButton
            modelChip
            Spacer(minLength: 0)
            trailingAction
                .animation(.snappy(duration: 0.18), value: showSend)
                .animation(.snappy(duration: 0.18), value: isQueueMode)
        }
    }

    // MARK: - Attachment strip

    private var attachmentStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(attachmentStore.pending) { item in
                    attachmentThumbnail(item)
                }
            }
            .padding(.horizontal, 2)
            .padding(.vertical, 2)
        }
        .frame(height: 68)
    }

    private func attachmentThumbnail(_ item: AttachmentStore.PendingAttachment) -> some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if let thumbnail = item.thumbnail {
                    Image(uiImage: thumbnail)
                        .resizable()
                        .scaledToFill()
                } else {
                    Image(systemName: "photo")
                        .font(.title2)
                        .foregroundStyle(theme.mutedFg)
                }
            }
            .frame(width: 60, height: 60)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(theme.border, lineWidth: 1)
            }
            .overlay {
                if case .uploading = item.state {
                    ZStack {
                        RoundedRectangle(cornerRadius: 10)
                            .fill(.black.opacity(0.35))
                        ProgressView()
                            .tint(.white)
                    }
                }
            }
            .overlay(alignment: .bottom) {
                if case .failed = item.state {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption2)
                        .foregroundStyle(theme.statusWarn)
                        .padding(2)
                }
            }

            Button {
                attachmentStore.remove(id: item.id)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.body)
                    .foregroundStyle(.white, .black.opacity(0.55))
            }
            .buttonStyle(.plain)
            .padding(2)
            .accessibilityLabel("Remove attachment")
        }
    }

    // MARK: - Buttons

    @ViewBuilder
    private var attachButton: some View {
        // Hidden entirely when the server can't accept uploads — every menu item
        // depends on `POST /api/upload`, so an empty menu would just confuse (E1).
        //

        // Task 4: replaced the bottom confirmationDialog with an anchored
        // Menu so the options pop up immediately above/left of the "+" button.
        // On iOS 26 the system Menu gets native glass automatically. Same five
        // actions, same order, same icons. `composerAttachButton` id preserved.
        if uploadSupported {
            Menu {
                // Plain Button → top-level `.photosPicker(isPresented:)`. A
                // PhotosPicker nested in the Menu does not present on device.
                Button {
                    isFocused = false
                    showPhotoPicker = true
                } label: {
                    Label("Photo Library", systemImage: "photo.on.rectangle")
                }
                if cameraAvailable {
                    Button {
                        isFocused = false
                        showCamera = true
                    } label: {
                        Label("Camera", systemImage: "camera")
                    }
                }
                if DocumentScanner.isSupported {
                    Button {
                        isFocused = false
                        showScanner = true
                    } label: {
                        Label("Scan Document", systemImage: "doc.viewfinder")
                    }
                }
                if fileMentionsSupported {
                    Button {
                        isFocused = false
                        showFileBrowser = true
                    } label: {
                        Label("Browse Files", systemImage: "folder")
                    }
                    .accessibilityIdentifier("composerBrowseFiles")
                }
            } label: {
                Image(systemName: "plus.circle.fill")
                    .font(.title2)
                    .foregroundStyle(isConnected ? theme.midground : theme.mutedFg)
            }
            .menuOrder(.fixed)
            .disabled(!isConnected)
            .accessibilityLabel("Add attachment")
            .accessibilityIdentifier("composerAttachButton")
        }
    }

    /// Row 1: the message field. The card itself is the surface now (border +
    /// fill + shadow live on `composerCard`), so the field is plain text on a
    /// transparent ground; the context-sensitive action lives on Row 2.
    private var composerField: some View {
        TextField("Message Hermes…", text: $text, axis: .vertical)
            .lineLimit(1...6)
            .focused($isFocused)
            .padding(.horizontal, 2)
            .padding(.top, 2)
            .submitLabel(.return)
    }

    // MARK: - Model chip (relocated from the nav header — F3 / Amendment E)

    /// A compact capsule showing the gateway's running model's short name, tapping
    /// to the model picker. Renders ONLY when `connection.activeModelName` is
    /// non-nil (Amendment E: "the model chip renders ONLY when activeModelName
    /// non-nil") and a control surface exists to switch it. carries the
    /// `composerModelChip` accessibility id its UI test gates on.
    ///

    /// When the active session's context-window occupancy is known (H1) the chip
    /// becomes a combined model+context affordance: a 2pt progress fill runs along
    /// the capsule's bottom edge (width = `contextPercent`, `theme.midground`,
    /// turning `theme.statusWarn` at the ≥75% compression threshold), and at ≥50%
    /// the label gains a " · N%" suffix. With no occupancy it is the plain chip —
    /// zero layout shift either way (the meter is an overlay, the suffix only adds
    /// trailing text).
    ///

    /// I3 — the capsule background is now a SYSTEM surface: on iOS 26+ a tinted,
    /// interactive `glassEffect` clipped to the Capsule (verified iOS 26 API); on
    /// 17–25 the established `theme.secondary` capsule fill. The H context meter is
    /// PRESERVED bit-for-bit and re-expressed as a TINT OVERLAY: it is drawn on TOP
    /// of whichever background era is active (`.overlay(alignment: .bottomLeading)`
    /// then clipped to the capsule), so the 2pt fill composes over the glass exactly
    /// as it did over the solid fill — no meter logic changes, only the ground it
    /// sits on. The chip's interactive feel (touch shimmer on 26) comes from the
    /// glass itself; the brand still reads through the meter + `secondaryFg` label.
    @ViewBuilder
    private var modelChip: some View {
        // Prefer the per-session hot-swap model over the global default.
        // When a session has a model override the gateway emits `session.info`,
        // ConnectionStore writes it to `sessionModel`, and the pill reflects the
        // swap immediately. On a DRAFT a pended pick shows next; falls back to
        // `activeModelName` (the global default) when there's no override.
        if let model = connection.sessionModel ?? connection.draftModelShortName ?? connection.activeModelName,
           !model.isEmpty {
            let context = chatStore.contextUsage
            let percent = context?.percent
            Button {
                if connection.control != nil {
                    isFocused = false
                    showModelPicker = true
                }
            } label: {
                Text(chipLabel(model: model, percent: percent))
                    .font(.caption.weight(.medium))
                    .foregroundStyle(theme.secondaryFg)
                    .lineLimit(1)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .modifier(ChipCapsuleSurface(theme: theme))
                    .overlay(alignment: .bottomLeading) {
                        if let percent { contextMeter(percent: percent) }
                    }
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(connection.control == nil)
            .accessibilityIdentifier("composerModelChip")
            .accessibilityLabel("Model: \(model)")
            .accessibilityValue(percent.map { "context \($0) percent" } ?? "")
            .accessibilityHint("Change model")
        }
    }

    /// The chip text: the model name, plus a " · N%" context suffix once
    /// occupancy reaches 50% (so the number only appears when it's worth the
    /// glance). Below 50% — and when occupancy is unknown — it's the bare model
    /// name (no layout shift).
    private func chipLabel(model: String, percent: Int?) -> String {
        guard let percent, percent >= 50 else { return model }
        return "\(model) · \(percent)%"
    }

    /// The 2pt context-occupancy fill hugging the chip capsule's bottom edge:
    /// width proportional to `percent`, `theme.midground` until the ≥75%
    /// compression threshold flips it to `theme.statusWarn`. A `GeometryReader`
    /// gives it the chip's own width so it never overruns the capsule.
    private func contextMeter(percent: Int) -> some View {
        GeometryReader { proxy in
            let fraction = CGFloat(min(max(percent, 0), 100)) / 100
            Capsule()
                .fill(percent >= 75 ? theme.statusWarn : theme.midground)
                .frame(width: proxy.size.width * fraction, height: 2)
                .frame(maxHeight: .infinity, alignment: .bottom)
        }
        .frame(height: 2)
        .allowsHitTesting(false)
    }

    /// The single docked action glyph. SF Symbol `.replace` morphs between mic and
    /// send as the field gains/loses content; while streaming it becomes a stop
    /// (interrupt) glyph, or a queue glyph when there is queueable text.
    @ViewBuilder
    private var trailingAction: some View {
        if isQueueMode {
            streamingAction
        } else if showSend {
            sendAction
        } else {
            micAction
        }
    }

    /// True when the trailing button should present "send" (there is text or a
    /// pending attachment ready to go).
    private var showSend: Bool {
        !trimmed.isEmpty || attachmentStore.hasPending
    }

    /// The send arrow: a dark filled `theme.fg` circle (Claude-iOS Row-2 action).
    /// Morphs in from the mic via the shared `.replace` symbol transition.
    ///

    /// CC-11 — a spring press-scale (.actionCircle ButtonStyle) gives the
    /// circle tactile depth on tap, matching the mic's `scaleEffect` press
    /// affordance. The style is applied here and on the stop/queue circles so
    /// every docked action button has the same physical feel.
    private var sendAction: some View {
        Button {
            send()
        } label: {
            actionGlyph(
                "arrow.up",
                filled: true,
                tint: theme.fg,
                enabled: canSend
            )
        }
        .buttonStyle(ActionCircleButtonStyle())
        .disabled(!canSend)
        .accessibilityLabel("Send")
    }

    /// The mic glyph (empty field, idle). TAP → tap-to-record strip flow;
    /// LONG-PRESS (≥0.35s) → hold-to-talk. Rendered as a tappable/pressable Color
    /// surface (not a `Button`) so the long-press + drag sequence isn't swallowed
    /// by button gesture handling.
    ///

    /// B1: the tap + long-press now share ONE recognizer tree — a single
    /// `.gesture` carrying an `ExclusiveGesture` of (tap) vs (long-press→drag) —
    /// instead of the previous `.onTapGesture` + `.gesture` on the same view,
    /// which raced two simultaneous recognizers. The host stays mounted across the
    /// `isCapturing` swap (see `composerCard`), so the hold's `.onEnded` always
    /// fires.
    ///

    /// B5: the mic stays VISIBLE for discoverability but is inert
    /// while DISCONNECTED — dimmed to `theme.mutedFg` and the gesture entry points
    /// (`tapMic` / `beginHoldIfNeeded`) no-op offline, so a capture whose
    /// transcript would silently vanish never starts.
    private var micAction: some View {
        actionGlyph(
            "mic.fill",
            filled: holdActive,
            tint: micTint,
            enabled: isConnected
        )
        .scaleEffect(holdActive ? 1.18 : 1)
        .contentShape(Circle())
        .gesture(micGesture)
        // The mic is a custom (non-`Button`) tappable surface so the long-press +
        // drag hold-to-talk sequence isn't swallowed by button gesture handling.
        // Add the button trait so assistive tech — and XCUITest's `app.buttons`
        // query — still see it as the interactive control it is (the idle-composer
        // signal the live ChatFlowUITests waits on after a turn completes).
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("Dictate message")
        .accessibilityHint("Tap to record, or touch and hold to talk")
    }

    /// Mic glyph tint: the pressed/armed midground while a hold is live, the muted
    /// foreground otherwise — and likewise muted (dimmed) while disconnected,
    /// mirroring the attach button's `isConnected ? theme.midground: theme.mutedFg`
    /// idiom (B5).
    private var micTint: Color {
        holdActive ? theme.midground : theme.mutedFg
    }

    /// While the agent is streaming the docked button either interrupts the turn
    /// (empty field — "stop replaces both") or queues the typed prompt for after
    /// the turn (preserves the queue affordance).
    ///

    /// CC-11 — ActionCircleButtonStyle applied here as on sendAction so the
    /// stop and queue circles have the same spring press depth.
    @ViewBuilder
    private var streamingAction: some View {
        if canQueue {
            Button {
                enqueue()
            } label: {
                actionGlyph("text.badge.plus", filled: true, tint: theme.fg, enabled: true)
            }
            .buttonStyle(ActionCircleButtonStyle())
            .accessibilityLabel("Queue message")
        } else {
            Button {
                Task { await chatStore.interrupt() }
            } label: {
                actionGlyph("stop.fill", filled: true, tint: theme.destructive, enabled: true)
            }
            .buttonStyle(ActionCircleButtonStyle())
            .accessibilityLabel("Interrupt")
        }
    }

    /// Shared 32pt glyph chrome for every docked action so the morph reads as one
    /// element changing symbol rather than separate buttons swapping in/out.
    private func actionGlyph(
        _ systemName: String,
        filled: Bool,
        tint: Color,
        enabled: Bool
    ) -> some View {
        Image(systemName: systemName)
            .font(.body.weight(.semibold))
            .foregroundStyle(filled ? tint.contrastingForeground : (enabled ? tint : theme.mutedFg))
            .frame(width: 32, height: 32)
            .background {
                if filled {
                    Circle().fill(enabled ? tint : theme.muted)
                }
            }
            .contentTransition(.symbolEffect(.replace))
    }

    /// "N queued" chip above the composer, opening the queue-management sheet.
    private var queueChip: some View {
        HStack {
            Button {
                showQueueSheet = true
            } label: {
                Label("\(queueStore.items.count) queued", systemImage: "text.badge.plus")
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(theme.muted, in: Capsule())
            }
            .buttonStyle(.plain)
            .foregroundStyle(theme.mutedFg)
            .accessibilityLabel("\(queueStore.items.count) queued prompts")
            Spacer(minLength: 0)
        }
    }

    /// Queueing only needs non-empty text (attachments aren't queued; they ride
    /// the live composer state).
    private var canQueue: Bool { !trimmed.isEmpty }

    private func send() {
        guard canSend else { return }
        let outgoing = trimmed
        text = ""
        // Fire the send haptic before the async send so the feedback lands
        // at the moment of the tap, not after the network round-trip.
        sendFeedbackTrigger &+= 1
        // ChatStore consumes the queued attachments; it clears them on success.
        Task { await chatStore.send(text: outgoing) }
    }

    /// Replace the active `@`-mention range with the chosen file's `@file:<path>`
    /// token (CHOSEN REPRESENTATION: an inline plain-text token in the buffer).
    /// Keeps focus so the user keeps typing after the inserted token.
    private func insertMention(
        _ item: PathCompletionItem,
        replacing mention: MentionCompletion.ActiveMention
    ) {
        text = MentionCompletion.insert(path: item.text, replacing: mention, in: text)
        isFocused = true
    }

    /// Enqueue the current text for after-turn delivery (drains on completion
    /// or reconnect). Stamped with the active stored session so it can never
    /// drain into a different session opened later; a draft (no
    /// stored session yet) queues unstamped and delivers wherever active.
    private func enqueue() {
        guard canQueue else { return }
        queueStore.enqueue(trimmed, storedSessionId: sessions.activeStoredId)
        queueFeedbackTrigger &+= 1
        text = ""
    }

    // MARK: - Voice dictation

    /// TAP the mic → start the tap-to-record strip flow (record, then stop/cancel
    /// via the strip controls). No-op if a capture is somehow already live, or
    /// while DISCONNECTED — transcription needs the gateway, so a capture taken
    /// offline would silently vanish on stop (B5 /). The gate is the MIC
    /// entry point only; it does NOT touch the send/queue path.
    private func tapMic() {
        guard isConnected else { return }
        guard !isCapturing else { return }
        isFocused = false
        startRecording(hold: false)
    }

    /// Begin recording. `start()` requests permission itself; if it lands in a
    /// denied state, surface the settings-link alert. `hold` marks the capture as
    /// hold-to-talk so the strip shows the "release to transcribe" affordance.
    ///

    /// The live REST client is handed to `start(rest:)` so the recorder's
    /// watchdog (B3) / interruption observer (B4) can salvage-transcribe a
    /// capture the user never explicitly stopped; salvaged transcripts are
    /// delivered back through `recorder.onSalvagedTranscript` (wired in `body`).
    private func startRecording(hold: Bool) {
        Task {
            if hold { recorder.beginHoldToTalk() }
            await recorder.start(rest: connection.rest)
            if recorder.permission == .denied {
                showMicDeniedAlert = true
            }
        }
    }

    /// Append a transcript to the composer field for review (NOT auto-sent),
    /// after any text the user already typed. Shared by the explicit
    /// stop-and-transcribe flow and the watchdog / interruption SALVAGE path so
    /// a recording the user did not manually stop still lands its words.
    private func appendTranscript(_ transcript: String) {
        let existing = text.trimmingCharacters(in: .whitespacesAndNewlines)
        text = existing.isEmpty ? transcript : existing + " " + transcript
        isFocused = true
    }

    /// Stop + transcribe; the transcript is dropped into the composer for review
    /// (NOT auto-sent), appending after any text the user already typed.
    private func stopAndTranscribe() {
        guard let rest = connection.rest else {
            recorder.cancel()
            return
        }
        Task {
            if let transcript = await recorder.stopAndTranscribe(rest: rest), !transcript.isEmpty {
                appendTranscript(transcript)
            }
        }
    }

    // MARK: - Hold-to-talk

    /// Distance (pts) the finger must slide off the mic before release cancels
    /// instead of transcribing.
    private static let holdCancelThreshold: CGFloat = 80

    /// The mic's SINGLE recognizer tree (B1): an `ExclusiveGesture` that resolves
    /// TAP-to-record vs HOLD-to-talk on one view, replacing the prior racing
    /// `.onTapGesture` + `.gesture` pair (root cause 2). Tap is the high-priority
    /// branch (an instantaneous `TapGesture`); if instead the press is held long
    /// enough the long-press→drag branch takes over. Exclusive (not simultaneous)
    /// so the two never both fire for one press.
    private var micGesture: some Gesture {
        ExclusiveGesture(tapGesture, holdToTalkGesture)
    }

    /// TAP branch: a plain tap starts the tap-to-record strip flow (gated inside
    /// `tapMic`).
    private var tapGesture: some Gesture {
        TapGesture().onEnded { tapMic() }
    }

    /// LongPress (≥0.35s) → Drag sequence driving push-to-talk. The long-press
    /// arms the capture and fires a start haptic; the trailing drag tracks the
    /// slide-away-to-cancel zone; release either transcribes or cancels. Reuses
    /// the recorder's existing start / stopAndTranscribe / cancel lifecycle. The
    /// host view stays mounted across `isCapturing` (B1), so `.onEnded` always
    /// fires even after the strip overlays the field.
    private var holdToTalkGesture: some Gesture {
        LongPressGesture(minimumDuration: 0.35)
            .sequenced(before: DragGesture(minimumDistance: 0))
            .onChanged { value in
                switch value {
                case .first:
                    // Long-press recognized but the drag hasn't begun: arm hold.
                    beginHoldIfNeeded()
                case .second(_, let drag):
                    beginHoldIfNeeded()
                    // Track the slide-away cancel zone (vertical lift counts most —
                    // the user drags up/away from the docked mic to bail).
                    if let drag {
                        let distance = hypot(drag.translation.width, drag.translation.height)
                        let willCancel = distance > Self.holdCancelThreshold
                        if willCancel != holdWillCancel { holdWillCancel = willCancel }
                    }
                }
            }
            .onEnded { _ in
                endHold()
            }
    }

    /// Arm hold-to-talk exactly once per press: flip the press visual, fire the
    /// start haptic, and kick off recording. No-ops while DISCONNECTED — a
    /// disconnected long-press gives no haptic and starts no capture, since the
    /// resulting transcript would silently vanish without the gateway (B5 /
    /// ). MIC entry gate only; the send/queue path is untouched.
    private func beginHoldIfNeeded() {
        guard isConnected else { return }
        guard !holdActive else { return }
        holdActive = true
        holdWillCancel = false
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        isFocused = false
        startRecording(hold: true)
    }

    /// Release the hold: transcribe unless the finger slid into the cancel zone.
    /// Fires a confirmation haptic and resets the press state. Guards against a
    /// release that arrives before `start()` actually entered `.recording`.
    private func endHold() {
        let wasActive = holdActive
        let cancel = holdWillCancel
        resetHoldState()
        guard wasActive else { return }
        if cancel {
            recorder.cancel()
            UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
        } else if recorder.isRecording {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            stopAndTranscribe()
        } else {
            // Released before recording actually began (permission prompt, race):
            // discard whatever partial state exists.
            recorder.cancel()
        }
    }

    /// Reset the composer's hold-press @State so the mic glyph is un-armed (no
    /// scale/fill). Called by `endHold()` and by the B2 strip stop/cancel buttons
    /// so a button-driven escape leaves the same clean state a gesture release
    /// would.
    private func resetHoldState() {
        holdActive = false
        holdWillCancel = false
    }
}

// MARK: - Composer system surfaces (I3)
//

// GLASS FOR THE CONTAINER, THEMES FOR CONTENT (the I3 reading of the Batch-I
// principle: the composer is a custom LAYOUT with no system equivalent, so the
// LAYOUT survives but its container + chip backgrounds become system primitives).
//

// API provenance (verified against the installed iPhoneSimulator 26.5 SDK,
// SwiftUICore.swiftinterface, by reading the `glassEffect` / `Glass` declarations
// — the geometry-fix / H3 house method):
//

//  @available(iOS 26.0, *) @available(visionOS, unavailable)
//  func glassEffect(_ glass: Glass = .regular,
//  in shape: some Shape = DefaultGlassEffectShape()) -> some View
//

//  @available(iOS 26.0, *) @available(visionOS, unavailable)
//  struct Glass { static var regular/clear/identity;
//  func tint(Color?) -> Glass; func interactive(Bool = true) -> Glass }
//

// Both are gated `#available(iOS 26.0, *)` so the iOS 17 deployment target keeps
// the solid fallback; visionOS is unavailable on the symbol, but this target is
// iOS-only so no extra guard is needed (the `else` covers every non-26 case).

/// The composer card container surface. iOS 26+: a system `glassEffect`
/// (`.regular.interactive()`, untinted — the brand reads through the field text,
/// chip, and action glyphs, and neutral glass stays legible over any scrolled
/// transcript behind the composer) clipped to the rounded rect. iOS 17–25: the
/// established solid treatment — `theme.card` fill + a soft lift shadow — so the
/// pre-26 card is a behaviour-preserving no-op. The focus-ring stroke is applied
/// by the caller ON TOP of this surface in both eras.
///

/// Non-private so `RecordingStrip` (VC-08) can reuse the same glass idiom
/// without duplicating the availability gate.
struct ComposerCardSurface: ViewModifier {
    let theme: HermesTheme
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius)
        #if DEBUG
        // Round-2 conic-stroke hunt (see RenderCache.expNoGlass*).
        if RenderCache.expNoGlass {
            return AnyView(content
                .background(theme.card, in: shape)
                .shadow(color: .black.opacity(0.06), radius: 8, x: 0, y: 2))
        }
        #endif
        if #available(iOS 26.0, *) {
            // Untinted, touch-reactive glass clipped to the card silhouette. Glass
            // adapts to the active scheme; the forced-dark themes pin `.dark` at
            // their root (`hermesThemed`), so the glass renders dark and does not
            // fight the forced scheme.
            #if DEBUG
            let glass: Glass = RenderCache.expNoGlassInteractive ? .regular : .regular.interactive()
            return AnyView(content.glassEffect(glass, in: shape))
            #else
            return AnyView(content.glassEffect(.regular.interactive(), in: shape))
            #endif
        } else {
            // iOS 17–25 (and visionOS): the established solid composer card — the
            // same fill + shadow the card shipped with (the border stroke remains
            // the caller's focus-ring overlay).
            return AnyView(content
                .background(theme.card, in: shape)
                .shadow(color: .black.opacity(0.06), radius: 8, x: 0, y: 2))
        }
    }
}

// MARK: - Action-circle press style (CC-11)
//

// The send, stop, and queue circles previously had no press-state animation —
// they responded flat like static Images, while the mic already carried a
// `scaleEffect(holdActive ? 1.18: 1)` press visual. CC-11 closes the gap:
// every filled docked action circle now springs down 10% on press and returns
// with a snappy rebound, giving the same physical feel across all three modes.

/// A ButtonStyle that scales the label down slightly on press and springs back.
/// Applied to the send / stop / queue circles so they feel as tactile as the mic.
private struct ActionCircleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.90 : 1.0)
            .animation(.snappy(duration: 0.14), value: configuration.isPressed)
    }
}

/// The model-chip capsule surface. iOS 26+: a tinted, interactive `glassEffect`
/// clipped to the Capsule — small enough to read as a chrome affordance, lightly
/// tinted with `theme.secondary` so it keeps chip identity while gaining the
/// system touch shimmer. iOS 17–25: the established `theme.secondary` capsule
/// fill. The H context meter is layered OVER this surface by the caller (a tint
/// overlay) in both eras, so it composes over glass exactly as it did over the
/// solid fill — no meter logic changes.
private struct ChipCapsuleSurface: ViewModifier {
    let theme: HermesTheme

    func body(content: Content) -> some View {
        #if DEBUG
        if RenderCache.expNoGlass {
            return AnyView(content.background(theme.secondary, in: Capsule()))
        }
        #endif
        if #available(iOS 26.0, *) {
            #if DEBUG
            let glass: Glass = RenderCache.expNoGlassInteractive
                ? .regular.tint(theme.secondary)
                : .regular.tint(theme.secondary).interactive()
            return AnyView(content.glassEffect(glass, in: Capsule()))
            #else
            return AnyView(content.glassEffect(.regular.tint(theme.secondary).interactive(), in: Capsule()))
            #endif
        } else {
            return AnyView(content.background(theme.secondary, in: Capsule()))
        }
    }
}

// MARK: - Recording strip

/// Replaces the text field while the recorder is active.
///

/// Two presentations share the strip:
/// - **Tap-to-record** (`isHoldMode == false`): a cancel (X) button, animated
///  level bars, elapsed time, and a checkmark to finish & transcribe.
/// - **Hold-to-talk** (`isHoldMode == true`): no buttons — the gesture owns the
///  lifecycle. Shows a recording dot, level bars, elapsed time, and a hint that
///  tracks the slide-away-cancel zone ("Release to transcribe" / "Release to
///  cancel").
///

/// VC-08 — the strip now uses the same `ComposerCardSurface` glass idiom as
/// the composer card (superseding CC-10's `theme.card` solid fill). On iOS 26
/// the strip renders as neutral interactive glass that matches the card it
/// overlays; on 17–25 it keeps the `theme.card` fill + shadow fallback. The
/// border ring is preserved on top in both eras, consistent with the card's own
/// focus-ring layering.
private struct RecordingStrip: View {
    let recorder: VoiceRecorder
    /// Whether the active capture is a hold-to-talk press (no inline controls).
    var isHoldMode: Bool = false
    /// In hold mode, whether releasing now would cancel (finger slid away).
    var willCancel: Bool = false
    let onCancel: () -> Void
    let onStop: () -> Void

    @Environment(\.hermesTheme) private var theme

    private let cornerRadius: CGFloat = 20

    var body: some View {
        HStack(spacing: 12) {
            if isHoldMode {
                holdContent
            } else {
                tapContent
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity)
        .modifier(ComposerCardSurface(theme: theme, cornerRadius: cornerRadius))
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius)
                .strokeBorder(theme.border, lineWidth: 1)
        )
        .animation(.easeInOut(duration: 0.15), value: willCancel)
    }

    // MARK: Tap-to-record presentation

    @ViewBuilder
    private var tapContent: some View {
        RecordingControls(
            isTranscribing: isTranscribing,
            onCancel: onCancel,
            onStop: onStop
        ) {
            LevelBars(level: recorder.level)
                .frame(maxWidth: .infinity)

            Text(elapsedText)
                .font(.callout.monospacedDigit())
                .foregroundStyle(theme.mutedFg)
        }
    }

    // MARK: Hold-to-talk presentation

    /// Hold-to-talk strip. The gesture is the fast path (release to transcribe /
    /// slide-away to cancel), but B2 adds the ALWAYS-reachable stop +
    /// cancel buttons via the shared ``RecordingControls`` so a dropped `.onEnded`
    /// can never dead-end the user in a frozen `.recording`. The recording dot +
    /// "Release to…" hint stay as the gesture affordance; the buttons are the
    /// guaranteed escape. Single control source — no forked component.
    @ViewBuilder
    private var holdContent: some View {
        RecordingControls(
            isTranscribing: isTranscribing,
            onCancel: onCancel,
            onStop: onStop
        ) {
            HStack(spacing: 8) {
                Image(systemName: willCancel ? "xmark.circle.fill" : "mic.fill")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(willCancel ? theme.destructive : theme.midground)
                    .frame(width: 28, height: 28)
                    .symbolEffect(.pulse, options: .repeating, isActive: !willCancel)

                LevelBars(level: recorder.level)
                    .frame(maxWidth: .infinity)
                    .opacity(willCancel ? 0.4 : 1)

                Text(elapsedText)
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(theme.mutedFg)

                Text(willCancel ? "Release to cancel" : "Release to transcribe")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(willCancel ? theme.destructive : theme.mutedFg)
                    .accessibilityLabel(willCancel ? "Release to cancel recording" : "Release to transcribe")
            }
        }
    }

    private var isTranscribing: Bool {
        if case .transcribing = recorder.state { return true }
        return false
    }

    private var elapsedText: String {
        if case .recording(let value) = recorder.state { return value.mmss }
        return TimeInterval.zero.mmss
    }
}

/// A small animated bar meter driven by the recorder's 0…1 level.
private struct LevelBars: View {
    let level: Float

    @Environment(\.hermesTheme) private var theme

    private let barCount = 5

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<barCount, id: \.self) { index in
                Capsule()
                    .fill(theme.midground)
                    .frame(width: 4, height: barHeight(index))
            }
        }
        .animation(.easeOut(duration: 0.12), value: level)
        .frame(height: 28)
    }

    /// Center bars react most strongly; edges stay shorter for a waveform look.
    private func barHeight(_ index: Int) -> CGFloat {
        let mid = Double(barCount - 1) / 2
        let distance = abs(Double(index) - mid) / mid          // 0 (center) … 1 (edge)
        let weight = 1.0 - distance * 0.55
        let scaled = Double(level) * weight
        return CGFloat(6 + scaled * 22)
    }
}

// MARK: - Queue sheet

/// Management UI for the prompt queue: list with inline editing, swipe-to-delete,
/// and a "Send next now" button that drains the head of the queue immediately.
private struct QueueSheet: View {
    let queueStore: QueueStore
    let chatStore: ChatStore

    @Environment(\.dismiss) private var dismiss
    @Environment(\.hermesTheme) private var theme

    var body: some View {
        NavigationStack {
            Group {
                if queueStore.items.isEmpty {
                    ContentUnavailableView(
                        "Queue empty",
                        systemImage: "text.badge.plus",
                        description: Text("Prompts you queue while Hermes is busy show up here.")
                    )
                } else {
                    List {
                        ForEach(queueStore.items) { item in
                            QueuedPromptRow(
                                text: item.text,
                                onCommit: { newText in queueStore.update(id: item.id, text: newText) }
                            )
                            .listRowBackground(theme.card)
                        }
                        .onDelete { offsets in
                            for index in offsets {
                                queueStore.remove(id: queueStore.items[index].id)
                            }
                        }
                    }
                    .scrollContentBackground(.hidden)
                    .background(theme.bg)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(theme.bg)
            .navigationTitle("Queued (\(queueStore.items.count))")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .bottomBar) {
                    Button {
                        Task { await queueStore.drain(chat: chatStore) }
                    } label: {
                        Label("Send next now", systemImage: "paperplane.fill")
                    }
                    .disabled(queueStore.items.isEmpty || chatStore.isStreaming)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

/// One editable queued-prompt row. Edits commit on submit / focus loss.
private struct QueuedPromptRow: View {
    @State var text: String
    let onCommit: (String) -> Void

    @FocusState private var focused: Bool

    var body: some View {
        TextField("Queued prompt", text: $text, axis: .vertical)
            .lineLimit(1...4)
            .focused($focused)
            .onSubmit { onCommit(text) }
            // Commit on focus LOSS too (release audit P1): the doc promised
            // it, but only `.onSubmit` was wired — tapping away (keyboard
            // dismiss, sheet drag) silently discarded the edit.
            .onChange(of: focused) { _, isFocused in
                if !isFocused { onCommit(text) }
            }
            .submitLabel(.done)
    }
}

// MARK: - Camera

/// Thin `UIImagePickerController` wrapper for `.camera` capture. Returns the
/// captured image as JPEG `Data`, or `nil` if the user cancelled.
private struct CameraPicker: UIViewControllerRepresentable {
    let onComplete: (Data?) -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onComplete: onComplete)
    }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let onComplete: (Data?) -> Void

        init(onComplete: @escaping (Data?) -> Void) {
            self.onComplete = onComplete
        }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            let image = info[.originalImage] as? UIImage
            // Hand raw JPEG to AttachmentStore, which re-normalises (downscale).
            onComplete(image?.jpegData(compressionQuality: 0.95))
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            onComplete(nil)
        }
    }
}
