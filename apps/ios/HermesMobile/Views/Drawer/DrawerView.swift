import SwiftUI

/// The Claude-iOS navigation drawer (F1): a serif wordmark + avatar header, thin
/// line-icon nav rows (Inbox, Automations), a muted "Recents" label, plain
/// one-line recent session rows (selected → soft rounded fill), and a FLOATING
/// "New chat" capsule overlapping the list bottom-right. Settings is now reached
/// from the header **avatar** (a sheet — F2), not a footer gear.
///

/// Used in two places by ``RootView``:
/// - **Compact (iPhone):** as the push-card surface beneath the chat
///  (``CompactLayout`` owns the offset/drag; the drawer just renders content).
/// - **Regular (iPad):** as the `NavigationSplitView` sidebar column.
///

/// Per Amendment D the drawer keeps its own `NavigationStack` exactly where it
/// was (NOT re-parented) — it now only ever holds the root drawer surface; the
/// settings push is gone (replaced by the avatar sheet), so the stack carries no
/// destinations in F1.
///

/// Selection source of truth stays `sessionStore.activeStoredId`; tapping a row
/// calls `sessionStore.open(_:)` and closes the drawer (compact only — the
/// closure is a no-op on iPad). All B/E functional wiring is preserved: the
/// search field (+ the ⌘F focus bridge and live search results), pinned section,
/// live-pulse + source glyphs, collapsible/pinnable workspace groups, the Inbox
/// sheet, and the opt-in quick-capture entry.
///

/// ## UI Batch I — I4 (FULL NATIVE drawer internals)
/// The drawer **mechanics** (push-card gesture, width, scrim-less layering) are
/// UNCHANGED — they live in ``CompactLayout`` (RootView), not here. The drawer
/// **internals** moved from a hand-rolled `ScrollView` + `LazyVStack` to a system
/// `List(.plain)` with system `Section` headers-I §I4 ("rows/
/// sections move to system List (plainStyle) IF it coexists with the drawer's
/// gesture + scroll edge effect").
///

/// Coexistence was validated against the binding architecture before adopting
/// List:
/// - The drawer drag gesture is a `simultaneousGesture` on the parent ZStack in
///  ``CompactLayout`` (global coordinate space), gated on horizontal dominance
///  (`abs(dx) > abs(dy) * 1.2`). That arbitration is identical whether the
///  scrolling child is a `ScrollView` or a `List` — both wrap the same
///  `UIScrollView` pan recognizer, which runs simultaneously with the parent
///  drag, and the dominance latch is what decides. Vertical List scrolls stay
///  dy-dominant (parent never latches → List scrolls); horizontal-dominant
///  drawer drags originate on the chat CARD (the drawer is hidden/`offset`
///  beneath when closed, the close-drag rides the card overlay), never on List
///  rows, so the List's pan never competes with a drawer-open/close drag.
/// - We deliberately keep the per-row pin/delete affordance on `.contextMenu`
///  (long-press) and add **no** `.swipeActions`, so no per-row horizontal pan
///  recognizer is introduced that could fight a horizontal drawer drag.
/// - The bottom scroll-edge effect (`scrollEdgeEffectStyle(.soft)`, the geometry-
///  fix house pattern) composes with `List` exactly as it did with `ScrollView`.
///

/// Every row is built from system primitives (`Label`, `Button`, `Text`,
/// `Image`); the New-chat capsule is a system `Button` with
/// `.buttonStyle(.glassProminent)` on iOS 26 (verified against the iPhoneSimulator
/// 26.5 SDK SwiftUI.swiftinterface) and the established solid capsule below it.
/// All accessibility identifiers are preserved verbatim (`settingsAvatar`,
/// `drawerInbox`, `drawerAutomations`, `drawerRecentsFilter`, `sessionRow`,
/// `drawerNewChat`).
struct DrawerView: View {
    /// The accessibility identifier stamped on the pull-to-reveal Archived Chats
    /// row (`archivedRevealRow`). Exposed as a `static let` so tests can assert
    /// against the production constant rather than a duplicated string literal
    /// (— the prior tautological test compared two literals in the
    /// test body that never touched this file).
    static let archivedChatsAccessibilityIdentifier = "drawerArchivedChats"

    @Environment(ConnectionStore.self) private var connection
    @Environment(SessionStore.self) private var sessions
    @Environment(InboxStore.self) private var inbox
    @Environment(AppLock.self) private var appLock
    @Environment(ThemeStore.self) private var themeStore
    @Environment(\.hermesTheme) private var theme

    /// Invoked after a navigation action that should dismiss the drawer (row
    /// open, New chat). Injected by ``RootView``: closes the push-card in
    /// compact layouts, a no-op on iPad where the drawer is permanent.
    var onNavigate: () -> Void = {}

    /// Drives navigation into ArchivedSessionsView (pull-to-reveal row in the
    /// drawer list — see `archivedRevealRow`).
    @State private var showingArchivedChats = false
    /// Drives presentation of the global approval/clarification inbox sheet.
    @State private var showingInbox = false
    /// Drives presentation of the automation-runs sheet (build-32 QA: the
    /// automation feed was buried in Settings; surfaced here as a drawer nav row
    /// alongside Inbox / Archived).
    @State private var showingAutomation = false
    /// The session a rename alert is editing (— `SessionStore.rename`
    /// was REST-wired + unit-tested with no UI entry point); nil = no alert.
    @State private var renamingSession: SessionSummary?
    /// Working text for the rename alert's field.
    @State private var renameText = ""
    /// Drives presentation of the Settings sheet (F2), opened from the header
    /// gear button. The gear is the Settings entry point (item 3).
    @State private var showingSettings = false
    /// Whether the sessions list has ever completed its first data load. Latches
    /// `true` on first non-empty sessions array so the skeleton/spinner guards
    /// the "No conversations yet" flash (DC-02).
    @State private var didCompleteFirstLoad = false
    /// the session staged for destructive-delete confirmation. Set when
    /// the user taps Delete in the context menu; the confirmation dialog fires
    /// before the actual `SessionStore.delete` call.
    @State private var sessionPendingDelete: SessionSummary?
    /// The drawer's own NavigationStack path. Empty in F1 — the only former
    /// destination (Settings) became a sheet — but kept so search/inbox/row
    /// pushes the integrator may add later have a home, and so the structural
    /// `NavigationStack` (Amendment D: not re-parented) is unchanged.
    @State private var path = NavigationPath()

    /// The current display name (Settings field, F2) used for the avatar
    /// initials. `nil`/blank → a neutral person glyph.
    @AppStorage(DefaultsKeys.displayName) private var displayName = ""

    // Dynamic-Type-scaled icon/glyph sizes. Base values preserve the exact
    // layout at the default text size; they grow when the user sets Larger Text.
    /// Settings gear glyph (header avatar button).
    @ScaledMetric(relativeTo: .title3) private var gearGlyphSize: CGFloat = 20
    /// Search-field magnifying-glass glyph.
    @ScaledMetric(relativeTo: .subheadline) private var searchIconSize: CGFloat = 14
    /// Search field text + clear ("xmark") glyph.
    @ScaledMetric(relativeTo: .subheadline) private var searchFieldFontSize: CGFloat = 15
    /// Recents "…" filter menu glyph.
    @ScaledMetric(relativeTo: .footnote) private var recentsFilterGlyphSize: CGFloat = 13

    var body: some View {
        NavigationStack(path: $path) {
            VStack(spacing: 0) {
                header
                searchField
                listBody
                slimFooter
            }
            .background(theme.listBg)
            // Floating "New chat" capsule overlapping the list bottom-right
            // (observed reference). theme.fg fill / theme.bg text — the per-theme
            // "black-on-cream" equivalent. Floats ABOVE the list's bottom scroll-
            // edge fade (BUG 3: hugs the bottom safe area).
            .overlay(alignment: .bottomTrailing) {
                // Baseline parity with the chat composer (user spec): ignore the
                // CONTAINER bottom inset so `controlBottomBaseline` measures from
                // the absolute screen edge — identical to ChatView's bottomStack.
                // Without this the capsule sat home-indicator-height above the
                // composer's baseline.
                // DC-07: capsule fades + scales in from bottom-right on first
                // appear so it doesn't pop in abruptly while the drawer animates
                // open. `.spring(response: 0.35)` matches the drawer open spring.
                newChatCapsule
                    .ignoresSafeArea(.container, edges: .bottom)
                    .transition(
                        .asymmetric(
                            insertion: .scale(scale: 0.8, anchor: .bottomTrailing)
                                .combined(with: .opacity),
                            removal: .scale(scale: 0.8, anchor: .bottomTrailing)
                                .combined(with: .opacity)
                        )
                    )
            }
            // The drawer hosts no pushed destinations in F1 (Settings is a sheet
            // now); the root drawer surface has no large title (chat-as-home owns
            // chrome).
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(.hidden, for: .navigationBar)
        }
        // Re-install the resolved palette + brand tint at this stack root;
        // SwiftUI does not reliably inherit custom environment values across
        // presentation/column boundaries.
        .hermesThemed(themeStore)
        .sheet(isPresented: $showingSettings) { settingsSheet }
        // Archived Chats sheet (pull-to-reveal entry point).
        .sheet(isPresented: $showingArchivedChats) {
            NavigationStack {
                ArchivedSessionsView(onNavigate: onNavigate)
                    .environment(sessions)
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { showingArchivedChats = false }
                        }
                    }
            }
            .hermesThemed(themeStore)
        }
        // Rename alert: a system alert with a text field, committed
        // through the previously-unreachable `SessionStore.rename`.
        .alert(
            "Rename Session",
            isPresented: Binding(
                get: { renamingSession != nil },
                set: { if !$0 { renamingSession = nil } }
            ),
            presenting: renamingSession
        ) { summary in
            TextField("Title", text: $renameText)
            Button("Rename") {
                let title = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !title.isEmpty else { return }
                Task { await sessions.rename(summary, to: title) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Set a custom title for this session.")
        }
        // a session mutation (delete/archive/rename) failed. A failure
        // used to vanish silently into the unobserved `lastError`; this binds a
        // system alert to the dedicated, observed `sessionActionError` so the
        // failure is unmissable. Mirrors the rename alert's value-presenting
        // form. The destructive-confirmation dialog is OUT of scope —
        // this alert fires only on FAILURE, never to confirm a delete.
        .alert(
            "\(sessions.sessionActionError?.action ?? "Action") Failed",
            isPresented: Binding(
                get: { sessions.sessionActionError != nil },
                set: { if !$0 { sessions.sessionActionError = nil } }
            ),
            presenting: sessions.sessionActionError
        ) { _ in
            Button("OK", role: .cancel) { sessions.sessionActionError = nil }
        } message: { error in
            Text(error.message)
        }
        // destructive-delete confirmation dialog. Sits in FRONT of the
        // existing delete path. The `.destructive` role colours the
        // "Delete" button red — system affordance, no custom drawing required.
        .confirmationDialog(
            "Delete this chat?",
            isPresented: Binding(
                get: { sessionPendingDelete != nil },
                set: { if !$0 { sessionPendingDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let pending = sessionPendingDelete {
                Button("Delete", role: .destructive) {
                    Task { await sessions.delete(pending) }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will permanently remove the conversation.")
        }
        .sheet(isPresented: $showingInbox) {
            NavigationStack {
                InboxView()
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { showingInbox = false }
                        }
                    }
            }
            // I1: open at the medium detent by default (resizable to large) so the
            // empty state no longer over-allocates a full-height sheet. The iPad
            // inspector column in RootView stays full — it is a column, not a sheet.
            .presentationDetents([.medium, .large])
            .hermesThemed(themeStore)
        }
        .sheet(isPresented: $showingAutomation) {
            NavigationStack {
                Group {
                    if let control = connection.control {
                        AutomationRunsView(rest: control)
                    } else {
                        ContentUnavailableView(
                            "Not Connected",
                            systemImage: "clock.arrow.2.circlepath",
                            description: Text("Connect to a gateway to see automation runs.")
                        )
                        .navigationTitle("Automation")
                        .navigationBarTitleDisplayMode(.inline)
                    }
                }
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { showingAutomation = false }
                    }
                }
            }
            .hermesThemed(themeStore)
        }
    }

    // MARK: - Header (wordmark + avatar)

    /// The drawer header: the theme wordmark "Hermes" (serif, observed) on the
    /// leading edge, and the user avatar circle on the trailing edge. Tapping the
    /// avatar presents the Settings sheet (F2) — the new Settings entry point.
    private var header: some View {
        HStack(spacing: 12) {
            Text("Hermes Agent")
                .font(.system(.title3, design: .serif).weight(.semibold))
                .foregroundStyle(theme.fg)
                .accessibilityAddTraits(.isHeader)

            Spacer(minLength: 0)

            // F4b multi-profile switcher (DORMANT by default). Renders ONLY under
            // the double gate (`profiles == .available` AND profile count > 1), so
            // on the gateway (no `/api/profiles`) it is absent entirely and the
            // header is byte-identical to the pre-F4b drawer. FULL NATIVE: a system
            // `Menu` (the `recentsFilterMenu` precedent), identity via tint.
            if sessions.isMultiProfileAvailable {
                profileSwitcherMenu
            }

            avatarButton
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 10)
    }

    // MARK: - Profile switcher (F4b, FULL NATIVE)

    /// The multi-profile switcher: a native `Menu` listing "All profiles" + each
    /// fetched ``ProfileSummary`` (the default marked, the active scope
    /// checkmarked). Selecting an item writes `sessions.activeProfile` and
    /// triggers a rail re-fetch (``SessionStore/selectProfile(_:)``). Gated by the
    /// caller on ``SessionStore/isMultiProfileAvailable`` so it never appears on a
    /// stock gateway. The label shows the active scope name with a person glyph.
    private var profileSwitcherMenu: some View {
        Menu {
            // Aggregate "All profiles" scope.
            Button {
                sessions.selectProfile(DefaultsKeys.allProfilesScope)
            } label: {
                Label(
                    "All profiles",
                    systemImage: sessions.isAllProfilesScope ? "checkmark" : "square.stack.3d.up"
                )
            }
            Divider()
            // One row per fetched profile; the active scope is checkmarked, the
            // default profile carries a "(default)" suffix.
            ForEach(sessions.profiles) { profile in
                Button {
                    sessions.selectProfile(profile.name)
                } label: {
                    Label(
                        profile.isDefault ? "\(profile.name) (default)" : profile.name,
                        systemImage: sessions.activeProfile == profile.name
                            ? "checkmark"
                            : "person.crop.circle"
                    )
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "person.crop.circle")
                    .font(.footnote.weight(.semibold))
                Text(profileSwitcherLabel)
                    .font(.footnote.weight(.medium))
                    .lineLimit(1)
            }
            // Bug fix: `theme.accent` and `theme.secondary` are neighbouring
            // low-contrast shades in every preset, so the chip read as muffled /
            // near-invisible. `theme.midground` is THE brand accent (tint / send
            // button / active pill) — high-contrast against `secondary` in every
            // theme, so the profile chip is clearly legible while staying branded.
            .foregroundStyle(theme.midground)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(theme.secondary, in: Capsule())
            .contentShape(Capsule())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .accessibilityIdentifier("drawerProfilePicker")
        .accessibilityLabel("Profile")
        .accessibilityValue(profileSwitcherLabel)
        .accessibilityHint("Switch the active profile")
    }

    /// The switcher's label text: "All" for the aggregate scope, else the active
    /// profile name (trimmed). Mirrors what the active scope resolves to.
    private var profileSwitcherLabel: String {
        sessions.isAllProfilesScope
            ? "All"
            : sessions.activeProfile.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A clear gear icon button that opens Settings. Replaces the initials-avatar
    /// (item 3 — the avatar rendered as a circle with initials; the gear
    /// reads more clearly as a settings entry). The `settingsAvatar` accessibility
    /// identifier is preserved verbatim — UI tests key on it and must not break.
    ///

    /// SETTINGS-GLITCH FIX: the sheet previously auto-closed on first open. Root
    /// cause: the gear tap set `showingSettings = true` during the same synchronous
    /// render pass that first committed the `DrawerView` into the hierarchy (on
    /// cold drawer open). SwiftUI can reset `@State` when a view completes its
    /// first layout pass, so a state write that races with first-commit could be
    /// dropped before the sheet had time to anchor. The fix: schedule the state
    /// write on the NEXT main-actor task so it lands AFTER the view's initial
    /// layout is fully committed, guaranteeing `showingSettings = true` is stable.
    ///

    /// Additionally, the drawer is NOT closed (no `onNavigate()` call) so the
    /// settings sheet presents reliably over the open drawer — a cleaner UX and
    /// removes any potential state conflict from a simultaneous drawer-close
    /// animation racing the sheet presentation.
    private var avatarButton: some View {
        Button {
            // SETTINGS-GLITCH FIX: defer to next main-actor task so this state
            // write is guaranteed to land after the view's first layout pass.
            Task { @MainActor in
                showingSettings = true
            }
        } label: {
            Image(systemName: "gearshape")
                .font(.system(size: gearGlyphSize, weight: .regular))
                .foregroundStyle(theme.fg)
                .frame(width: 34, height: 34)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // DC-01: light haptic on gear tap
        .sensoryFeedback(.impact(flexibility: .soft), trigger: showingSettings)
        .accessibilityIdentifier("settingsAvatar")
        .accessibilityLabel("Settings")
        .accessibilityHint("Open settings")
    }

    // MARK: - Settings sheet (F2 seam)

    /// Presents the Settings surface as a sheet from the header avatar — the
    /// canonical call site documented by F2's ``SettingsView`` presentation
    /// contract. F2's view owns its OWN `NavigationStack` + chrome (X close pill,
    /// centered title, info pill) and dismisses itself via `@Environment(\.dismiss)`,
    /// so F1 supplies only the `Bool`-binding sheet, the hidden drag indicator,
    /// and re-installs the palette across the sheet boundary. This same path
    /// drives the iPad sidebar avatar too (DrawerView is the split-view sidebar),
    /// satisfying Amendment E ("avatar→Settings sheet works from the iPad sidebar").
    private var settingsSheet: some View {
        SettingsView(
            connectionStore: connection,
            sessionStore: sessions,
            appLock: appLock
        )
        .presentationDragIndicator(.hidden)
        .hermesThemed(themeStore)
    }

    // MARK: - Search

    /// Drawer-local search field bound straight to the store's `searchQuery`,
    /// reusing the existing debounce machinery (`searchQueryChanged()`); no
    /// duplicate search state lives here. Preserved (with the ⌘F focus bridge and
    /// live results) per Amendment E — it is existing functional wiring.
    private var searchField: some View {
        @Bindable var sessions = sessions
        return VStack(spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: searchIconSize))
                    .foregroundStyle(theme.mutedFg)
                TextField("Search", text: $sessions.searchQuery)
                    .textFieldStyle(.plain)
                    .font(.system(size: searchFieldFontSize))
                    .foregroundStyle(theme.fg)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .onChange(of: sessions.searchQuery) { _, _ in
                        sessions.searchQueryChanged()
                    }
                if !sessions.searchQuery.isEmpty {
                    Button {
                        sessions.clearSearch()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: searchFieldFontSize))
                            .foregroundStyle(theme.mutedFg)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear search")
                    // DC-08: clear button fades/scales in when the query is non-empty
                    // so it doesn't pop in abruptly on the first keystroke.
                    .transition(.scale(scale: 0.7).combined(with: .opacity))
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(theme.muted, in: RoundedRectangle(cornerRadius: 10))

            // Scope toggle (All / Messages / Code) — appears while searching so
            // results aren't dominated by tool/structured noise (search QA).
            // Changing scope re-runs the active query.
            if sessions.isSearchActive {
                Picker("Scope", selection: $sessions.searchScope) {
                    ForEach(SessionStore.SearchScope.allCases, id: \.self) { scope in
                        Text(scope.label).tag(scope)
                    }
                }
                .pickerStyle(.segmented)
                .onChange(of: sessions.searchScope) { _, _ in
                    sessions.searchQueryChanged()
                }
                .accessibilityIdentifier("drawerSearchScope")
                .transition(.opacity)
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
        // DC-08: animate the clear button + scope picker insertion/removal
        .animation(.easeInOut(duration: 0.15), value: sessions.searchQuery.isEmpty)
        .animation(.easeInOut(duration: 0.15), value: sessions.isSearchActive)
    }

    // MARK: - List body (I4: system List(.plain))

    /// Stable anchor used by the pull-to-reveal mechanism: the scroll view starts
    /// here (just below the hidden `archivedRevealRow`) so the archived row is
    /// not visible when the drawer opens, but a pull-down exposes it.
    private let drawerListTopAnchor = "hermes.drawer.list.top"

    /// Infinite-scroll prefetch distance (rows). When a recents row within this
    /// many rows of the end scrolls into view, `loadMore()` is kicked so the next
    /// ~30-row batch is loading BEFORE the user reaches the bottom — the user spec
    /// ("auto-load … as the person is about to reach the bottom", ≥30 per batch).
    /// ~1 screenful of drawer rows; the tail `loadMoreSentinel` stays as a backstop
    /// for short lists and the grouped path.
    private static let loadMorePrefetchDistance = 12

    /// The drawer's scrolling body, now a system `List(.plain)`. Sections are
    /// system `Section`s; the cells are built from `Label`/`Button`/`Text`/`Image`
    /// system primitives. The List replaces the prior `ScrollView` +
    /// `LazyVStack` — see the type doc for the gesture-coexistence rationale.
    ///

    /// Row chrome is suppressed so the List reads as the same flat, accent-led
    /// drawer it did before (the per-theme identity, not the default grouped
    /// material): each row clears its separator (`.listRowSeparator(.hidden)`),
    /// uses a transparent row background (`.listRowBackground(Color.clear)` — the
    /// selected-row fill is painted by the row view itself, exactly as before),
    /// and tightens its insets. The List's own background is hidden
    /// (`.scrollContentBackground(.hidden)`) so `theme.listBg` shows through —
    /// preserving the painted canvas on iOS 17–25 and letting the system glass/
    /// material defer to the accent-led palette on 26.
    ///

    /// ## Pull-to-reveal Archived Chats (iMessage-hidden-row pattern)
    ///

    /// `archivedRevealRow` is placed at the very top of the List (position 0,
    /// before the nav section). On appear `ScrollViewReader` scrolls to
    /// `drawerListTopAnchor`, which is the first VISIBLE row (the `navSection`
    /// Inbox row) — pushing the archived row off the top edge so it is not
    /// visible when the drawer opens. The user exposes it by pulling the list
    /// down, exactly as iMessage hides its search bar above the conversation list.
    ///

    /// Why this approach over `contentOffset` / UIKit bridging:
    /// `ScrollViewReader` + an anchor scroll in `.onAppear` is the most robust
    /// SwiftUI-native method. It does not require a `UIScrollView` introspection
    /// bridge (which can break across OS versions and with `List`) and does not
    /// conflict with the drawer's `simultaneousGesture` architecture (the scroll
    /// is a one-shot programmatic `.top` anchor, not an ongoing gesture fight).
    /// The row stays revealed while the user holds the pull — standard overscroll
    /// physics — and re-hides naturally on release if the user does not tap.
    /// DC-01: haptic feedback for drawer open/close. Triggered by the List's
    /// `onAppear` (drawer opens) and `onDisappear` (drawer closes). Uses UUID
    /// triggers so `.sensoryFeedback` fires on every open/close event.
    @State private var drawerOpenFeedbackTrigger = UUID()
    @State private var drawerCloseFeedbackTrigger = UUID()

    @ViewBuilder
    private var listBody: some View {
        ScrollViewReader { listProxy in
            List {
                // PULL-TO-REVEAL: the archived row is hidden above the fold on
                // open (the ScrollViewReader snaps to `drawerListTopAnchor`
                // below it on appear). It becomes visible when the user pulls
                // the list downward, exactly like iMessage's hidden search.
                archivedRevealRow

                if sessions.isSearchActive {
                    searchResults
                        .id(drawerListTopAnchor)
                } else {
                    navSection
                        // The anchor is attached to the first visible content
                        // section (Inbox/Automations) so the initial scroll
                        // hides the archived row above.
                        .id(drawerListTopAnchor)
                    pinnedSection
                    recentSection
                }
            }
            .listStyle(.plain)
            .environment(\.defaultMinListRowHeight, 0)
            .scrollContentBackground(.hidden)
            .background(theme.listBg)
            // Keep the floating capsule from covering the last row: reserve a bottom
            // content margin so the scrolling content ends above the capsule's zone
            // (matches the prior `.padding(.bottom, 72)` on the LazyVStack).
            .contentMargins(.bottom, 72, for: .scrollContent)
            // BUG 2 — bottom fade behind the floating New-chat capsule. On iOS 26+
            // this is the SYSTEM scroll-edge effect (a graceful progressive fade of
            // the scrolling content at its bottom edge), replacing the hand-rolled
            // gradient band that read as an abrupt color block. The glass capsule
            // (H3) floats above it; the soft effect fades the list rows into the
            // bottom region so they dissolve under the capsule rather than colliding.
            // Below iOS 26 a mask-based content fade matches ChatView's EdgeFadeMask.
            // PRESERVED house pattern (the geometry-fix modifier), now applied to the
            // List rather than the ScrollView.
            .modifier(DrawerBottomFade())
            // Snap to the first visible section on every appear so the pull-to-
            // reveal archived row is above the fold. Animated: false to avoid a
            // visible scroll jump; this fires before the drawer finishes its own
            // open animation so the final resting state is correct.
            .onAppear {
                listProxy.scrollTo(drawerListTopAnchor, anchor: .top)
                // UX1: also trigger an immediate first-page refresh when the drawer
                // opens so the list is up-to-date without waiting for the next tick.
                sessions.drawerOpenRefresh()
                // DC-01: drawer open haptic — bump trigger so sensoryFeedback fires.
                drawerOpenFeedbackTrigger = UUID()
            }
            .onDisappear {
                // DC-01: drawer close haptic.
                drawerCloseFeedbackTrigger = UUID()
            }
            // DC-01: sensoryFeedback for open/close — placed on the List so the
            // triggers propagate through the view tree correctly.
            .sensoryFeedback(.impact(flexibility: .rigid, intensity: 0.5),
                             trigger: drawerOpenFeedbackTrigger)
            .sensoryFeedback(.impact(flexibility: .soft, intensity: 0.4),
                             trigger: drawerCloseFeedbackTrigger)
            // Also snap when the session list refreshes (e.g. search activation /
            // deactivation) so re-entering the normal mode doesn't expose the row.
            .onChange(of: sessions.isSearchActive) { _, _ in
                listProxy.scrollTo(drawerListTopAnchor, anchor: .top)
            }
        }
    }

    // MARK: - Pull-to-reveal Archived Chats row

    /// The hidden "Archived Chats" row that lives above the fold at the top of
    /// the drawer list. Not visible when the drawer opens (the list scrolls to
    /// `drawerListTopAnchor` below it on appear); pulling down reveals it.
    /// Tapping opens `ArchivedSessionsView` as a sheet.
    ///

    /// Positioned above the nav section (Inbox/Automations) — placing it above
    /// all drawer content mirrors iMessage's hidden search placement (above the
    /// conversation list) and reads cleanly as "extra row revealed by pull" rather
    /// than an inline item mixed into navigation controls.
    private var archivedRevealRow: some View {
        plainRow {
            Button {
                showingArchivedChats = true
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "archivebox")
                        .font(.body)
                        .foregroundStyle(theme.fg)
                        .frame(width: 22)
                    Text("Archived Chats")
                        .font(.body.weight(.medium))
                        .foregroundStyle(theme.fg)
                    Spacer(minLength: 0)
                    // DC-11: swap plain chevron.right for chevron.down to signal
                    // "this row lives above — pull down to see it" — the downward
                    // arrow reads more naturally as a pull-down affordance than
                    // a forward-navigate chevron for a row already revealed by
                    // pulling down.
                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(theme.mutedFg)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier(Self.archivedChatsAccessibilityIdentifier)
            .accessibilityLabel("Archived Chats")
            .accessibilityHint("Pull down to reveal, then tap to view archived sessions")
        }
    }

    /// Shared list-row chrome suppression: no separator, transparent background
    /// (rows paint their own selected fill), and tight horizontal insets that
    /// match the prior hand-laid `LazyVStack` padding. Applied to every row /
    /// header so the native List reads as the flat accent-led drawer.
    private func plainRow<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 1, leading: 8, bottom: 1, trailing: 8))
    }

    // MARK: Nav section (Inbox / Automations)

    /// Thin line-icon nav rows above the recents (observed reference), now a
    /// headerless system `Section`. "New chat" lives in the floating capsule;
    /// Inbox opens the approval sheet; Automations toggles whether cron sessions
    /// show in the recents list — a dedicated row replacing the old ellipsis menu
    /// (contract F1). Both are system `Button`s carrying a system `Label`.
    @ViewBuilder
    private var navSection: some View {
        @Bindable var sessions = sessions

        Section {
            plainRow {
                DrawerNavRow(
                    title: "Inbox",
                    systemImage: "tray",
                    badge: inbox.pendingCount,
                    identifier: "drawerInbox"
                ) {
                    showingInbox = true
                }
            }
            plainRow {
                DrawerNavRow(
                    title: "Automation",
                    systemImage: "clock.arrow.2.circlepath",
                    identifier: "drawerAutomations"
                ) {
                    showingAutomation = true
                }
            }
        }
    }

    // MARK: Pinned section

    @ViewBuilder
    private var pinnedSection: some View {
        if !sessions.pinnedSessions.isEmpty {
            Section {
                ForEach(sessions.pinnedSessions) { summary in
                    sessionRow(summary, pinned: true)
                }
            } header: {
                DrawerSectionHeader(title: String(localized: "Pinned"))
            }
        }
    }

    // MARK: Recents section

    /// The Recents section. Its header carries a trailing filter "…" menu whose
    /// "Group by workspace" checkmark item toggles `groupByWorkspace` (H2). When
    /// grouping is off the unpinned sessions render flat (as before); when on,
    /// per-workspace subheaders replace the flat list. The cron filter still
    /// applies in both modes (grouping reads from the already-filtered
    /// `unpinnedSessions`).
    ///

    /// UX1: a sentinel row at the bottom of the unpinned list (and inside each
    /// workspace group) triggers `loadMore()` via `.onAppear` when it scrolls into
    /// view. A `loadMoreRow` progress row replaces the sentinel while the fetch is
    /// in flight.
    @ViewBuilder
    private var recentSection: some View {
        Section {
            // DC-02: guard the empty-state flash during cold first-load.
            // Show skeleton rows while the first fetch is in flight AND no
            // sessions have loaded yet AND the first load hasn't completed.
            // Once sessions are present (or the load completes), the normal
            // empty/list paths take over. This mirrors the desktop's
            // `showSessionSkeletons = sessionsLoading && sortedSessions.length === 0`.
            if sessions.isLoading && !didCompleteFirstLoad && sessions.unpinnedSessions.isEmpty {
                sessionSkeletonRows
            } else if sessions.unpinnedSessions.isEmpty {
                emptyRecent
            } else if sessions.groupByWorkspace {
                groupedRecents
            } else {
                ForEach(sessions.unpinnedSessions) { summary in
                    sessionRow(summary, pinned: false)
                        .onAppear { maybePrefetchMore(rowId: summary.id) }
                }
                // Infinite scroll sentinel / loading row (UX1).
                loadMoreSentinel
            }
        } header: {
            DrawerSectionHeader(title: recentsHeaderTitle) {
                recentsFilterMenu
            }
        }
        // DC-02: latch didCompleteFirstLoad once sessions arrive so the skeleton
        // is replaced exactly once and never re-shown during a heartbeat refresh.
        // Latched off VISIBLE sessions (release audit): the backing array can be
        // momentarily all-cron (filtered out of Recents), and latching on it
        // flashed "No conversations yet" while the fill was still paging.
        .onChange(of: sessions.visibleSessions.isEmpty) { _, isEmpty in
            if !isEmpty {
                withAnimation(.easeInOut(duration: 0.2)) {
                    didCompleteFirstLoad = true
                }
            }
        }
        // Also latch when the loading flag clears — even if zero sessions, we
        // still want to escape the skeleton (a truly empty account).
        // DC-12: use a gentle ease-in animation so the empty state fades in
        // rather than popping in abruptly after the skeleton disappears.
        .onChange(of: sessions.isLoading) { _, loading in
            if !loading {
                withAnimation(.easeIn(duration: 0.25)) {
                    didCompleteFirstLoad = true
                }
            }
        }
    }

    /// The "Load more" row (UX1). Replaces the former zero-height `Color.clear`
    /// sentinel that failed to fire `.onAppear` reliably on cold launch because
    /// SwiftUI lazy lists do not guarantee off-screen `.onAppear` delivery.
    ///

    /// Design: an always-tappable `Button` with real, measurable height (minimum
    /// 36 pt) mirroring the desktop `SidebarLoadMoreRow` (sidebar/index.tsx:1159).
    /// The button calls `loadMore()` explicitly so pagination never depends on a
    /// re-render. An `.onAppear` is retained as a bonus auto-trigger for when the
    /// row scrolls into view naturally.
    ///

    /// The row is hidden once `loadedOffset ≥ totalSessions` (server exhausted).
    /// A stable `.id("loadMoreRow")` prevents the List from fusing it with the
    /// ForEach above and losing the `.onAppear` on first insertion.
    /// Near-bottom prefetch trigger for infinite scroll. Called from each recents
    /// row's `.onAppear` (both the flat list AND the grouped-workspace layout);
    /// when the appearing row is within ``loadMorePrefetchDistance`` of the end of
    /// the unpinned list it kicks `loadMore()` (which pages until ≥30 NEW visible
    /// rows land or the server is exhausted). Fires EARLY — before the user hits
    /// the bottom — so the next batch is already arriving as they scroll into it.
    ///

    /// The row's position is resolved LIVE by its stable `id` against the current
    /// `unpinnedSessions`, not a captured enumeration index — so a re-sort /
    /// filter / pin change between render and `.onAppear` can't desync the index
    /// from the count. Measuring against the flat `unpinnedSessions` is correct
    /// for the grouped layout too, since grouping only reorders the same rows.
    /// Guards against re-entrancy (`isLoadingMore`) and server-exhaustion.
    private func maybePrefetchMore(rowId: SessionSummary.ID) {
        guard !sessions.isLoadingMore else { return }
        if let total = sessions.totalSessions, sessions.loadedOffset >= total { return }
        let list = sessions.unpinnedSessions
        guard let index = list.firstIndex(where: { $0.id == rowId }) else { return }
        guard index >= list.count - Self.loadMorePrefetchDistance else { return }
        Task { await sessions.loadMore() }
    }

    @ViewBuilder
    private var loadMoreSentinel: some View {
        let isAtEnd: Bool = {
            guard let total = sessions.totalSessions else { return false }
            return sessions.loadedOffset >= total
        }()
        if !isAtEnd {
            plainRow {
                // INFINITE SCROLL (no "Load more" button): an invisible probe at the
                // list tail. When it scrolls into view (the user nears the bottom) it
                // auto-loads the next page — no tap. A small spinner shows only while
                // a fetch is in flight. The `.id` is keyed on `loadedCount` so that
                // after each page lands the probe gets a FRESH identity and its
                // `.onAppear` RE-FIRES if it is still on screen — that is what makes
                // it keep loading continuously as the user scrolls (the old static
                // id fired `.onAppear` only once, so it stalled after one page).
                HStack {
                    Spacer(minLength: 0)
                    if sessions.isLoadingMore {
                        ProgressView().scaleEffect(0.7)
                    }
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, minHeight: 28)
                .contentShape(Rectangle())
                .accessibilityHidden(true)
                .onAppear {
                    guard !sessions.isLoadingMore else { return }
                    Task { await sessions.loadMore() }
                }
            }
            .id("loadMoreRow-\(sessions.loadedCount)")
        }
    }

    /// The Recents section header title, updated for UX1 filter honesty.
    ///

    /// Shows one of:
    /// - "Recents" — single page, no filters hiding rows, nothing to explain.
    /// - "Recents · N shown · M loaded of TOTAL" — client filters (hideCron etc.)
    ///  are hiding some fetched rows AND more pages remain on the server.
    /// - "Recents · N shown of M loaded" — filters are hiding rows within the
    ///  loaded set, but all server rows are loaded.
    /// - "Recents · M of TOTAL" — no rows are hidden by filters, but more pages
    ///  remain on the server (the original item 6 display).
    ///

    /// "loaded" = server rows fetched (`sessions.loadedCount`); "shown" = rows
    /// visible after filters (`sessions.filteredCount`). This pairing is always
    /// honest: hidden rows are never a mystery to the user.
    private var recentsHeaderTitle: String {
        let loaded = sessions.loadedCount
        let shown  = sessions.filteredCount
        let total  = sessions.totalSessions

        let hasMoreOnServer = total.map { $0 > loaded } ?? false
        let filtersHidingRows = loaded > 0 && shown < loaded

        switch (filtersHidingRows, hasMoreOnServer) {
        case (true, true):
            // Filters active AND more pages available.
            return "Recents · \(shown) shown · \(loaded) loaded of \(total!)"
        case (true, false):
            // Filters active, all pages loaded.
            return "Recents · \(shown) shown of \(loaded) loaded"
        case (false, true):
            // No filters hiding rows, more pages remain.
            return "Recents · \(loaded) of \(total!)"
        case (false, false):
            return String(localized: "Recents")
        }
    }

    /// The Recents "…" filter menu. Holds the "Group by workspace" checkmark
    /// item (H2). Kept as a menu so future filters (e.g. surfacing the cron
    /// toggle here) have a home, matching the desktop sidebar's header action.
    private var recentsFilterMenu: some View {
        @Bindable var sessions = sessions
        return Menu {
            Button {
                sessions.groupByWorkspace.toggle()
            } label: {
                Label("Group by workspace", systemImage: sessions.groupByWorkspace ? "checkmark" : "")
            }
        } label: {
            Image(systemName: "line.3.horizontal.decrease")
                .font(.system(size: recentsFilterGlyphSize, weight: .semibold))
                .foregroundStyle(theme.mutedFg)
                .frame(width: 28, height: 22)
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .accessibilityIdentifier("drawerRecentsFilter")
        .accessibilityLabel("Recents filter")
    }

    /// Recents grouped into per-workspace subgroups (H2). Each group renders a
    /// collapsible folder subheader (label + chevron) as a plain row followed by
    /// its session rows. Tapping the header collapses/expands the group; the
    /// collapsed state is persisted in ``SessionStore`` backed by UserDefaults.
    /// A long-press context menu on the header allows pinning/unpinning the group
    /// to the top of the list (also persisted). Section order = pinned first,
    /// then recency; rows within a section = `startedAt` DESC — the desktop's
    /// exact ordering (see `SessionStore.workspaceGroups()`).
    ///

    /// The grouping subheaders ride INSIDE the single Recents `Section` (as plain
    /// rows) rather than as nested `Section`s, preserving the prior two-level
    /// hierarchy (all-caps "RECENTS" header + folder subheaders) — a `List`
    /// cannot nest `Section`s, so the subheaders stay as `DrawerWorkspaceHeader`
    /// rows exactly as before.
    @ViewBuilder
    private var groupedRecents: some View {
        ForEach(sessions.workspaceGroups()) { group in
            let isCollapsed = sessions.collapsedWorkspaces.contains(group.id)
            let isPinned    = sessions.pinnedWorkspaceKeys.contains(group.id)
            plainRow {
                DrawerWorkspaceHeader(
                    label: group.label,
                    isCollapsed: isCollapsed,
                    isPinned: isPinned
                ) {
                    // Collapse/expand tap: persist via store.
                    withAnimation(.easeInOut(duration: 0.2)) {
                        sessions.toggleCollapsed(workspaceKey: group.id)
                    }
                } onPin: {
                    // Pin/unpin: also persisted via store.
                    sessions.togglePinnedWorkspace(group.id)
                }
            }
            if !isCollapsed {
                ForEach(group.sessions) { summary in
                    sessionRow(summary, pinned: false)
                        // Grouped layout gets the same near-bottom prefetch as
                        // the flat list (resolved by id against the flat
                        // unpinned list).
                        .onAppear { maybePrefetchMore(rowId: summary.id) }
                }
            }
        }
        // Infinite scroll sentinel — appended after all groups (UX1).
        loadMoreSentinel
    }

    /// DC-02: skeleton placeholder shown during the 100–400 ms cold-load window.
    /// Five rows with shimmer-width title bars + a smaller trailing glyph stub,
    /// mirroring the desktop's `SidebarSessionSkeletons` shape. No text or date
    /// values are shown (the user can't interact with them anyway); the widths are
    /// staggered so the skeleton reads as real content rather than a spinner.
    private var sessionSkeletonRows: some View {
        let widths: [CGFloat] = [130, 160, 112, 144, 96]
        return ForEach(Array(widths.enumerated()), id: \.offset) { _, w in
            plainRow {
                HStack(spacing: 10) {
                    Color.clear.frame(width: 8, height: 8)
                    VStack(alignment: .leading, spacing: 5) {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(theme.mutedFg.opacity(0.18))
                            .frame(width: w, height: 10)
                        RoundedRectangle(cornerRadius: 3)
                            .fill(theme.mutedFg.opacity(0.11))
                            .frame(width: w * 0.6, height: 8)
                    }
                    Spacer(minLength: 0)
                    RoundedRectangle(cornerRadius: 3)
                        .fill(theme.mutedFg.opacity(0.12))
                        .frame(width: 14, height: 14)
                }
                .padding(.vertical, 7)
                .padding(.horizontal, 10)
            }
            .accessibilityHidden(true)
        }
    }

    private var emptyRecent: some View {
        // DC-02: guard the "No conversations yet" flash during the 100–400 ms
        // cold first-load window. Until the first successful fetch resolves
        // (latched by `didCompleteFirstLoad`), show skeleton rows if the store is
        // still loading — the same pattern the desktop uses (`showSessionSkeletons
        // = sessionsLoading && sortedSessions.length === 0`). Once the load
        // settles (or if `isLoading` is false from the start) show the real empty
        // state or the cron-hidden message.
        plainRow {
            if sessions.isLoading && !didCompleteFirstLoad {
                // Invisible spacer — the skeleton rows are rendered by recentSection
                // above this (see DC-02 guard in recentSection). This empty plainRow
                // is a fallback in case the section path shows emptyRecent directly.
                Color.clear.frame(height: 0)
            } else {
                Text(sessions.hideCron && !sessions.sessions.isEmpty
                     ? "Automation sessions are hidden."
                     : "No conversations yet.")
                    .font(.footnote)
                    .foregroundStyle(theme.mutedFg)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 12)
                    .transition(.opacity.animation(.easeIn(duration: 0.2)))
            }
        }
    }

    // MARK: Search results

    /// VC-02: haptic trigger for search result row taps.
    @State private var searchResultFeedbackTrigger = UUID()

    @ViewBuilder
    private var searchResults: some View {
        if sessions.isSearching && sessions.searchResults.isEmpty {
            plainRow {
                HStack { Spacer(); ProgressView(); Spacer() }
                    .padding(.top, 24)
            }
        } else if sessions.searchResults.isEmpty {
            plainRow {
                Text("No results for \u{201C}\(sessions.searchQuery)\u{201D}")
                    .font(.footnote)
                    .foregroundStyle(theme.mutedFg)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 12)
            }
        } else {
            Section {
                ForEach(sessions.searchResults) { result in
                    plainRow {
                        Button {
                            // VC-02: bump trigger so sensoryFeedback fires on tap.
                            searchResultFeedbackTrigger = UUID()
                            sessions.open(searchResult: result)
                            onNavigate()
                        } label: {
                            DrawerSearchResultRow(result: result, query: sessions.searchQuery)
                        }
                        .buttonStyle(.plain)
                        // VC-02: search result tap haptic
                        .sensoryFeedback(.selection, trigger: searchResultFeedbackTrigger)
                    }
                }
            } header: {
                DrawerSectionHeader(title: String(localized: "Results"))
            }
        }
    }

    // MARK: - Row builder

    /// Haptic trigger for session row tap — bumped each time a row is opened so
    /// `.sensoryFeedback` fires on each new selection even if the same row is
    /// tapped twice (UUID changes every call).
    @State private var rowTapFeedbackTrigger = UUID()

    /// One recent/pinned session row, wrapped in a system `Button` so it reads as
    /// a native List cell while keeping the `sessionRow` accessibility id and the
    /// pin/delete `.contextMenu` (long-press) plus `.swipeActions` (trailing edge).
    ///

    /// ## Swipe-action gesture safety
    /// The drawer open/close gesture (`abs(dx) > abs(dy) * 1.2`) is a
    /// `simultaneousGesture` on the parent ZStack in ``CompactLayout``, operating
    /// in the global coordinate space. Per-row List swipe actions use the List's
    /// own internal `UIScrollView` pan recognizer, which runs on the List's scroll
    /// view — a separate, deeper recognizer chain inside the drawer's content area.
    /// When the user swipes a row the gesture begins inside the List's scroll view;
    /// the parent ZStack's drag sees the same dx/dy but, because the List scroll
    /// recognizer claims the touch, the parent drag does not latch (the `UIGesture`
    /// co-ownership rules give the scroll view priority for horizontal touches that
    /// start on a swipe-action row). In practice this is the same pattern that
    /// `ArchivedSessionsView` already uses (.swipeActions inside a List pushed
    /// over the drawer), and is the same geometry the comment in I4 describes for
    /// the validated List/drawer coexistence. Confirmed safe before adding.
    @ViewBuilder
    private func sessionRow(_ summary: SessionSummary, pinned: Bool) -> some View {
        plainRow {
            Button {
                // DC-01: bump trigger so sensoryFeedback fires on every tap
                rowTapFeedbackTrigger = UUID()
                open(summary)
            } label: {
                DrawerSessionRow(
                    summary: summary,
                    isPinned: pinned,
                    isSelected: summary.id == sessions.activeStoredId,
                    isLive: sessions.isLive(summary)
                )
            }
            .buttonStyle(.plain)
            // DC-01: row-tap haptic. `.selection` is the standard iOS "row selected"
            // feedback — the same weight as UITableView's selection click.
            .sensoryFeedback(.selection, trigger: rowTapFeedbackTrigger)
            // DC-01: pin haptic — fires from both the context menu and swipe path
            // since both bump `pinFeedbackTrigger`. Placed here (on the row Button
            // wrapper) so SwiftUI's feedback machinery reliably picks it up rather
            // than relying on the context-menu or swipe-action ViewBuilder scopes.
            .sensoryFeedback(.impact(weight: .medium, intensity: 0.7),
                             trigger: pinFeedbackTrigger)
            .accessibilityIdentifier("sessionRow")
            .contextMenu {
                rowContextMenu(for: summary, pinned: pinned)
            }
            // REVERTED (user decision): NO `.swipeActions` on drawer rows.
            // A per-row trailing swipe is horizontally-dominant, and while the
            // drawer is open the CompactLayout card-drag latches ANY horizontal
            // pan (RootView dragGesture open branch has no start-zone gate), so the
            // row swipe closes the drawer instead of revealing actions — it simply
            // did not work. Pin / Rename / Archive / Delete remain on the
            // `.contextMenu` (long-press) above, which the card-drag does not
            // intercept. (Re-enabling swipe would require gating that card-drag to
            // card-originating drags — deferred.)
        }
    }

    /// Haptic trigger for pin/unpin — bumped each time a pin state changes.
    @State private var pinFeedbackTrigger = UUID()

    @ViewBuilder
    private func rowContextMenu(for summary: SessionSummary, pinned: Bool) -> some View {
        Button {
            pinFeedbackTrigger = UUID()   // DC-01: pin haptic (fires at row level)
            sessions.togglePin(summary)
        } label: {
            Label(pinned ? "Unpin" : "Pin", systemImage: pinned ? "pin.slash" : "pin")
        }
        // rename + archive were fully implemented, REST-wired, and
        // unit-tested in SessionStore with zero UI callers. The drawer row's
        // long-press menu is their natural home (mirrors Pin/Delete).
        Button {
            renameText = summary.title ?? ""
            renamingSession = summary
        } label: {
            Label("Rename", systemImage: "pencil")
        }
        Button {
            Task { await sessions.archive(summary) }
        } label: {
            Label("Archive", systemImage: "archivebox")
        }
        Divider()
        // stage for confirmation; the .confirmationDialog on the
        // NavigationStack root presents the destructive confirmation before the
        // actual `SessionStore.delete` call (wired in FRONT of the path).
        // DC-06: the system `.destructive` role button already carries a warning
        // weight; no extra haptic is needed here — iOS fires `.warning` feedback
        // automatically for `.destructive` context-menu items on tap.
        Button(role: .destructive) {
            sessionPendingDelete = summary
        } label: {
            Label("Delete", systemImage: "trash")
        }
    }

    // MARK: - Floating "New chat" capsule

    /// Haptic trigger for the New Chat capsule — bumped on each tap.
    @State private var newChatFeedbackTrigger = UUID()

    /// The floating "New chat" capsule overlapping the list bottom-right (observed
    /// reference). Carries the `drawerNewChat` id (preserved). BUG 3: hugs the
    /// bottom safe area (~14pt above it) rather than floating high.
    ///

    /// I4 / H3 — glass chrome: on iOS 26+ the capsule is a system `Button` with
    /// `.buttonStyle(.glassProminent)` (verified against the installed
    /// iPhoneSimulator 26.5 SDK SwiftUI.swiftinterface — `glassProminent` is
    /// `@available(iOS 26.0, *)`, the prominent Liquid Glass primitive the
    /// reference chrome uses for its primary floating action) tinted by the brand
    /// `theme.midground` so identity expresses through TINT over the system
    /// material. It reads correctly OVER the list's bottom scroll-edge fade
    /// (BUG 2 — `DrawerBottomFade`): the list content dissolves toward the bottom
    /// edge, so the glass refracts a faded list edge rather than colliding with
    /// raw rows. Below iOS 26 the established solid treatment stays: `theme.fg`
    /// fill / contrasting text — the per-theme "black-on-cream" equivalent.
    /// The floating "New chat" capsule overlapping the list bottom-right (observed
    /// reference). Carries the `drawerNewChat` id (preserved). BUG 3: hugs the
    /// bottom safe area (~14pt above it) rather than floating high.
    ///

    /// made taller / more substantial. The pre-26 branch uses
    /// taller vertical padding (14pt instead of 11pt) + a larger icon/text size
    /// (16pt) so the capsule has a more prominent hit target. The iOS 26+
    /// `.glassProminent` branch gains the same larger label (the system button
    /// style sizes itself around the label) plus a min-height `.frame` so the
    /// glass material renders at the same weight as the solid branch.
    @ViewBuilder
    private var newChatCapsule: some View {
        if #available(iOS 26.0, *) {
            Button {
                newChatFeedbackTrigger = UUID()  // DC-01
                startDraft()
            } label: {
                // Stock Liquid Glass sizing: no custom frame(minHeight:) inflation.
                // `.glassProminent` renders at the system's native control height
                // for this button style, matching the reference chrome. The label
                // font drives the intrinsic size; no fixed height override.
                newChatCapsuleLabel
                    .font(.body.weight(.semibold))
            }
            .buttonStyle(.glassProminent)
            // Stock-kit sizing, one notch up (user: bare default reads too
            // thin, custom 50pt inflation read too tall): `.controlSize(.large)`
            // is the system's own larger glass variant — still entirely the
            // UI-kit button, no frame hacks.
            .controlSize(.large)
            .tint(theme.midground)
            // DC-01: haptic on new-chat tap — `.impact(.medium)` is the standard
            // primary action weight (matches the composer send button).
            .sensoryFeedback(.impact(weight: .medium), trigger: newChatFeedbackTrigger)
            .padding(.trailing, 16)
            // Shared baseline: the bottom edge of the capsule sits at the same
            // distance from the screen bottom as the floating composer card in
            // ChatView. Both consume the same constant so a single tweak keeps
            // them visually aligned when the drawer slides over the chat.
            .padding(.bottom, HermesLayoutConstants.controlBottomBaseline)
            .accessibilityIdentifier("drawerNewChat")
            .accessibilityLabel("New chat")
        } else {
            Button {
                newChatFeedbackTrigger = UUID()  // DC-01
                startDraft()
            } label: {
                newChatCapsuleLabel
                    .foregroundStyle(theme.fg.contrastingForeground)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 14)
                    .background(theme.fg, in: Capsule())
                    .shadow(color: .black.opacity(0.18), radius: 10, x: 0, y: 3)
            }
            .buttonStyle(.plain)
            // DC-01: haptic on new-chat tap
            .sensoryFeedback(.impact(weight: .medium), trigger: newChatFeedbackTrigger)
            .padding(.trailing, 16)
            .padding(.bottom, HermesLayoutConstants.controlBottomBaseline)
            .accessibilityIdentifier("drawerNewChat")
            .accessibilityLabel("New chat")
        }
    }

    /// Shared label for the New-chat capsule across the glass / solid branches.
    private var newChatCapsuleLabel: some View {
        HStack(spacing: 8) {
            Image(systemName: "square.and.pencil")
                .font(.body.weight(.semibold))
            Text("New chat")
                .font(.body.weight(.semibold))
        }
    }

    // MARK: - Slim footer (capture-if-enabled only)

    /// The footer. item 6: the Quick Note row is removed from the drawer
    /// (feature parked). The drawer footer is now always empty so the footer
    /// collapses entirely. The deep link, share extension, App Intents quick-capture
    /// paths are untouched — only the visible row in this surface is removed.
    @ViewBuilder
    private var slimFooter: some View {
        EmptyView()
    }

    // MARK: - Actions

    /// Open an existing session and dismiss the drawer (compact). Activation is
    /// instant (transcript + resume continue in the background).
    ///

    /// R40 — REVEAL-ON-PAINT (supersedes FIX 4). Keep the drawer OPEN through the
    /// tap and hand `open(_:)` the close as `revealOnFirstPaint`: the store fires
    /// it the instant the new transcript's first frame is painted (cache hit ≈ one
    /// frame; miss = the skeleton), so the rigid close-slide uncovers SETTLED
    /// content. The prior FIX-4 order closed on frame 0 while the async cache paint
    /// landed a frame later — mid-slide — which the user saw as "the transcript
    /// moves on its own beat before the chat-view layer." The switch-hitch FIX 4
    /// targeted is still avoided: `open()` keeps deferring its heavy teardown, and
    /// nothing heavy runs on the close-spring's frame 0 (the slide now even starts
    /// a frame later, fully clear of the activation work).
    private func open(_ summary: SessionSummary) {
        sessions.open(summary) { onNavigate() }
    }

    /// Start a fresh local draft chat (B3 API) and dismiss the drawer. Draft
    /// sessions avoid empty-session litter — the gateway session is created
    /// lazily on first send (B3's ChatStore change).
    private func startDraft() {
        sessions.startDraft()
        onNavigate()
    }
}

// MARK: - Nav row

/// A tappable drawer nav row (Inbox, Automations) with an optional trailing
/// badge and an "active" accent state. Single line, thin leading line-icon
/// (observed reference). When `isActive` is set the row reads as toggled-on
/// (accent glyph + soft fill) — used by the Automations visibility toggle.
///

/// Built from system primitives only (`Button` + `Image` + `Text`); it is a List
/// cell now (I4). The leading glyph + label are a hand-laid `HStack` rather than
/// a `Label` so the trailing badge can sit on the same baseline — but every
/// element is a system view and the row carries no custom shape beyond the soft
/// active-state fill (theme accent), which IS the drawer's identity expression.
private struct DrawerNavRow: View {
    @Environment(\.hermesTheme) private var theme

    let title: LocalizedStringKey
    let systemImage: String
    var badge: Int = 0
    var isActive: Bool = false
    var identifier: String? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: systemImage)
                    .font(.body)
                    .foregroundStyle(isActive ? theme.midground : theme.fg)
                    .frame(width: 22)
                Text(title)
                    .font(.body.weight(.medium))
                    .foregroundStyle(theme.fg)
                Spacer(minLength: 0)
                if badge > 0 {
                    Text("\(badge)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(theme.midground.contrastingForeground)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(theme.midground, in: Capsule())
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 9)
                    .fill(isActive ? theme.accent.opacity(0.16) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue(badge > 0 ? "\(badge) pending" : "")
        .accessibilityAddTraits(isActive ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier(identifier ?? "")
    }
}

// MARK: - Section header

/// A drawer section header, used as the `header:` of a system `Section`. The
/// all-caps muted label matches the prior hand-laid header; an optional trailing
/// accessory (e.g. the Recents filter menu, H2) sits vertically centered against
/// the label. Insets are zeroed/tightened by the surrounding `plainRow`-style
/// list-row config on the header itself so it aligns with the rows beneath.
private struct DrawerSectionHeader<Accessory: View>: View {
    @Environment(\.hermesTheme) private var theme
    let title: String
    /// An optional trailing accessory (e.g. the Recents filter menu, H2),
    /// vertically centered against the label.
    @ViewBuilder var accessory: () -> Accessory

    init(title: String, @ViewBuilder accessory: @escaping () -> Accessory = { EmptyView() }) {
        self.title = title
        self.accessory = accessory
    }

    var body: some View {
        HStack(spacing: 6) {
            Text(title.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(theme.mutedFg)
            Spacer(minLength: 0)
            accessory()
        }
        .padding(.horizontal, 10)
        // DC-09: tighten the top padding from 10 → 8 pt for a more compact
        // section-gap rhythm. The 4 pt bottom pad is already tight; the 10 pt top
        // created a noticeable "jump" between the search field and Inbox/Recents
        // headers. 8 pt reads proportional to the row height without crowding.
        .padding(.top, 8)
        .padding(.bottom, 4)
        // System Section headers default to an uppercased, indented treatment;
        // override the case (we already uppercase the text) and clear the default
        // header insets so the label aligns with the rows.
        .textCase(nil)
        .listRowInsets(EdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 8))
    }
}

// MARK: - Workspace group subheader (H2)

/// A per-workspace subheader inside the grouped Recents list (H2): a folder SF
/// symbol + workspace label + trailing chevron (collapse affordance) + optional
/// pin badge. Tapping the header collapses/expands the group; a long-press
/// context menu pins/unpins it to the top of the list.
///

/// Design hierarchy: distinct from the all-caps `DrawerSectionHeader` (the
/// top-level "RECENTS" label) — this is the second-level folder header. The
/// chevron rotates to signal collapsed state (points right when collapsed,
/// points down when expanded). A pin badge appears when the group is pinned.
private struct DrawerWorkspaceHeader: View {
    @Environment(\.hermesTheme) private var theme
    let label: String
    var isCollapsed: Bool = false
    var isPinned: Bool = false
    /// Called when the header is tapped (toggle collapse).
    var onToggle: (() -> Void)? = nil
    /// Called when the "Pin" / "Unpin" context-menu item is chosen.
    var onPin: (() -> Void)? = nil

    // Dynamic-Type-scaled subheader glyph sizes (base values preserve the
    // default-size layout; grow with Larger Text).
    /// Folder glyph leading the workspace label.
    @ScaledMetric(relativeTo: .caption2) private var folderGlyphSize: CGFloat = 10
    /// Pin / chevron trailing glyphs.
    @ScaledMetric(relativeTo: .caption2) private var trailingGlyphSize: CGFloat = 9

    var body: some View {
        Button {
            onToggle?()
        } label: {
            // VC-10: tighten the top padding from 8 → 6 pt so workspace
            // subheaders sit closer to the preceding row.
            HStack(spacing: 5) {
                Image(systemName: "folder")
                    .font(.system(size: folderGlyphSize))
                    .foregroundStyle(theme.mutedFg.opacity(0.65))
                Text(label)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(theme.mutedFg)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if isPinned {
                    Image(systemName: "pin.fill")
                        .font(.system(size: trailingGlyphSize))
                        .foregroundStyle(theme.midground.opacity(0.7))
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: trailingGlyphSize, weight: .semibold))
                    .foregroundStyle(theme.mutedFg.opacity(0.55))
                    // Rotate 90° when expanded (chevron.right → chevron.down).
                    .rotationEffect(.degrees(isCollapsed ? 0 : 90))
                    .animation(.easeInOut(duration: 0.2), value: isCollapsed)
            }
            .padding(.horizontal, 10)
            .padding(.top, 6)
            .padding(.bottom, 3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button {
                onPin?()
            } label: {
                Label(
                    isPinned ? "Unpin workspace" : "Pin workspace",
                    systemImage: isPinned ? "pin.slash" : "pin"
                )
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
        .accessibilityLabel("Workspace \(label)\(isPinned ? ", pinned" : "")\(isCollapsed ? ", collapsed" : "")")
        .accessibilityHint(isCollapsed ? "Double-tap to expand" : "Double-tap to collapse")
    }
}

// MARK: - Search result row

/// A drawer search-result row: a normalized, match-highlighted snippet + relative
/// time + source glyph (R1/R2).
///

/// The snippet is rendered through ``SessionSearchResult/attributedSnippet(query:highlight:)``
/// which strips JSON scaffolding from prose excerpts and bolds the matched term in
/// `theme.midground`. Genuinely structured content (JSON objects/arrays) is left
/// verbatim and shown in a monospaced face; everything else reads as plain prose.
private struct DrawerSearchResultRow: View {
    @Environment(\.hermesTheme) private var theme
    let result: SessionSearchResult
    /// The live search query, used to bold the matched term when the server
    /// omits FTS markers.
    let query: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if !result.displaySnippet.isEmpty {
                Text(attributedSnippet)
                    .font(snippetFont)
                    .foregroundStyle(theme.fg)
                    .lineLimit(2)
            } else {
                Text("Match")
                    .font(.footnote)
                    .foregroundStyle(theme.mutedFg)
            }
            HStack(spacing: 6) {
                if let date = result.startedDate {
                    // tick the relative-time label every 60s.
                    TimelineView(.periodic(from: .now, by: 60)) { _ in
                        Text(date.sessionRelativeLabel)
                            .font(.caption2)
                            .foregroundStyle(theme.mutedFg)
                    }
                }
                Image(systemName: DrawerSourceGlyph.systemImage(for: result.source))
                    .font(.caption2)
                    .foregroundStyle(theme.mutedFg)
                    .accessibilityLabel(DrawerSourceGlyph.label(for: result.source))
            }
        }
        .padding(.vertical, 7)
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Monospace ONLY for genuinely structured snippets; prose uses the system
    /// face at `.footnote` (R1).
    private var snippetFont: Font {
        result.snippetIsStructured
            ? .system(.footnote, design: .monospaced)
            : .footnote
    }

    /// Assemble the highlighted excerpt from the pure (Foundation-only) segments
    /// the result model produces, applying the brand accent + semibold weight to
    /// the matched run here in the view layer (R1: theme.midground emphasis).
    private var attributedSnippet: AttributedString {
        var out = AttributedString()
        for segment in result.snippetSegments(query: query) {
            var piece = AttributedString(segment.text)
            if segment.isMatch {
                piece.font = .footnote.weight(.semibold)
                piece.foregroundColor = theme.midground
            }
            out += piece
        }
        return out
    }
}

// MARK: - Drawer bottom scroll-edge fade (BUG 2)

/// The bottom fade behind the floating "New chat" capsule. Replaces the prior
/// hand-rolled `LinearGradient` band (which read as an abrupt color block) with
/// the platform primitive. Applied to the `List` (I4) exactly as it was applied
/// to the prior `ScrollView` — the geometry-fix house pattern, unchanged.
///

/// - **iOS 26+:** the SYSTEM scroll-edge effect
///  (`scrollEdgeEffectStyle(.soft, for: .bottom)`, verified against the
///  installed iPhoneSimulator 26.5 SDK — `ScrollEdgeEffectStyle.soft` is the
///  graceful progressive fade the reference chrome uses). It fades the
///  scrolling list content into the bottom region across the FULL width with no
///  abrupt cutoff, adapts to the active scheme (so it renders correctly under
///  the forced-dark themes, whose root pins `.dark`), and composes with the
///  glass New-chat capsule (H3) floating above it.
/// - **iOS 17–25:** a mask-based fade of the LIST content itself — the same
///  treatment as ``ChatView``'s `EdgeFadeMask` — so the rows dissolve toward the
///  bottom rather than being covered by an overlay band. Full-coverage and soft.
private struct DrawerBottomFade: ViewModifier {
    /// Height of the bottom fade band on the pre-26 mask path. Large enough to
    /// cover the floating capsule's vertical zone so rows dissolve fully under it.
    private let bottomFade: CGFloat = 96

    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content
                .scrollEdgeEffectStyle(.soft, for: .bottom)
        } else {
            content.mask(alignment: .top) {
                GeometryReader { proxy in
                    let h = proxy.size.height
                    let bottomStop = max(0.5, 1 - bottomFade / max(h, 1))
                    LinearGradient(
                        stops: [
                            .init(color: .black, location: 0),
                            .init(color: .black, location: bottomStop),
                            .init(color: .clear, location: 1)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                }
            }
        }
    }
}
