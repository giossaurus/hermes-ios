import SwiftUI
import UserNotifications

/// App settings, presented as a **full-height card sheet** (F2 / Amendment C),
/// rebuilt on the native grouped **`List`** for UI Batch I (I2).
///

/// ## Native chrome principle (the design contract-I, binding)
///

/// "System components render chrome; Hermes identity expresses through tint,
/// typography, and content surfaces." Settings is pure chrome, so it is now a
/// system `List` (`.insetGrouped`) whose rows are system primitives only —
/// `NavigationLink`, `LabeledContent`, `Toggle`, `Button` — with **no**
/// hand-rolled row containers, hairlines, or hit-target geometry. On iOS 26 the
/// system gives the inset-grouped list its new Liquid Glass design for free; on
/// 17–25 it renders the classic grouped list. Both are correct, zero custom
/// drawing. This deletes the prior bug class entirely (the Appearance row's
/// collapsed hit target, the manual hairline insets, the flat-row tap-through).
///

/// Hermes identity rides on top of the system list via `.tint(theme.midground)`
/// (the toggles, the back-chevrons, the selection accents) and on the **content
/// surfaces** the list hosts (the account header card, destructive coloring),
/// not on the chrome itself. Row backgrounds are painted `theme.card` over a
/// `theme.bg` canvas via `.scrollContentBackground(.hidden)` so the six themes
/// keep their identity; on iOS 26 the system materials would otherwise win, but
/// these are content fills (the spec keeps `card`/`bg` as content tokens).
///

/// ## Presentation contract (entry point for F1's drawer avatar) — UNCHANGED
///

/// `SettingsView` owns its **own** `NavigationStack` (sheet-internal pushes are
/// fine — they mirror Claude) and supplies its **own** chrome: a standard
/// toolbar with an `X` close item (leading, `settingsClose`), a centered
/// "Settings" principal title, and an info item (trailing, `settingsInfo`).
///

/// F1 presents it as a `Bool`-binding sheet. The canonical call site is:
///

/// ```swift
/// // In DrawerView (and the iPad sidebar), owned by F1:
/// @State private var showingSettings = false
/// // … avatar button sets `showingSettings = true` …
/// .sheet(isPresented: $showingSettings) {
///  SettingsView(
///  connectionStore: connection,
///  sessionStore: sessions,
///  appLock: appLock
/// )
///  .presentationDragIndicator(.hidden) // contract: indicator hidden
///  .hermesThemed(themeStore) // re-install palette across the sheet boundary
/// }
/// ```
///

/// The view dismisses itself via `@Environment(\.dismiss)` from the X item, so F1
/// needs no `onDismiss` plumbing — a plain `Bool` binding (or a `sheet(item:)`
/// enum case) is sufficient. Nothing about Settings reaches back into the drawer.
///

/// > Why `.hermesThemed` at the call site, not here: SwiftUI does not reliably
/// > inherit the custom `\.hermesTheme` environment value across a sheet
/// > presentation boundary, and `SettingsView` does not receive the `ThemeStore`
/// > as an init argument (it reads it from the environment for the Appearance
/// > row). Re-installing at the presentation site keeps the whole sheet — and its
/// > pushed panels — painted in the active palette. The `ThemeStore` must already
/// > be in the environment at the call site (it is, app-wide).
///

/// ## Layout (native grouped sections)
///

/// An account+server **card** (display name, server URL) sits in the first
/// section as content; the rest is grouped settings sections: Appearance + the
/// control panels (each a push), inline Toggles (Notifications, Security),
/// Connection (server value + destructive Disconnect), and About (version + push).
/// Simple settings render their value inline via `LabeledContent` and never push;
/// the control panels push within this sheet's own stack.
struct SettingsView: View {
    /// Owns the connection lifecycle (server URL, disconnect, control client).
    let connectionStore: ConnectionStore
    /// Owns the session list and active-session pointers.
    let sessionStore: SessionStore
    /// Biometric app-lock gate; drives the "Require Face ID" toggle.
    let appLock: AppLock

    /// The theme store. Read here so the Appearance row can show the current theme
    /// name inline and the picker push can bind to it. The hosting sheet applies
    /// `.hermesThemed` at the presentation site (see the presentation contract).
    @Environment(ThemeStore.self) private var themeStore
    @Environment(LocalizationManager.self) private var localization
    @Environment(\.hermesTheme) private var theme
    /// Dismisses the sheet from the X item. F1 needs no `onDismiss`.
    @Environment(\.dismiss) private var dismiss

    @State private var confirmingDisconnect = false
    /// The sheet-internal navigation path. Pushes are driven by the system
    /// `NavigationLink(value:)` cells (Appearance, the control panels, About) and
    /// matched by `navigationDestination(for:)` — the native list-cell push.
    @State private var path = NavigationPath()

    /// Dynamic-Type-scaled size for the disconnected-state "Reconnect" label
    /// (base value preserves the default-size layout; grows with Larger Text).
    @ScaledMetric(relativeTo: .subheadline) private var reconnectLabelFontSize: CGFloat = 14

    // MARK: Identity (F2 / Amendment E)

    /// The user's first name, the greeting source on the draft chat. Bound to the
    /// shared ``DefaultsKeys/displayName`` key so the chat greeting (F3) reads the
    /// same source of truth without re-presenting anything.
    @AppStorage(DefaultsKeys.displayName) private var displayName = ""

    // MARK: Per-event push prefs (F2-A / A4)

    /// The three per-event push toggles. All default ON. A change re-POSTs
    /// `/api/push/register` with the new `events` list via
    /// ``PushRegistrar/reRegisterEvents()``. The `@AppStorage` default of `true`
    /// matches ``DefaultsKeys/pushEventEnabled(_:_:)``'s "absent ⇒ on" semantics.
    @AppStorage(DefaultsKeys.pushEventApproval) private var notifyApproval = true
    @AppStorage(DefaultsKeys.pushEventClarify) private var notifyClarify = true
    @AppStorage(DefaultsKeys.pushEventTurnComplete) private var notifyTurnComplete = true

    // MARK: Notifications permission bridge (P0)
    //

    // The toggle is disabled while authorization status is `.unknown` (probe on
    // appear). If the user has `.denied` notification access, flipping the toggle
    // ON is blocked: instead the toggle snaps back to OFF and an alert offers an
    // "Open Settings" deep-link so they can re-grant.
    //

    // Only `.authorized` and `.provisional` allow the toggle to flip on normally.

    /// Cached UNAuthorizationStatus — probed on appear and after the alert
    /// dismisses (so re-granting in Settings is reflected immediately on return).
    @State private var notifAuthStatus: UNAuthorizationStatus = .notDetermined
    /// Whether the FIRST authorization probe has completed. The toggle is
    /// disabled only until this is true (a brief "probing" window) — NOT on the
    /// settled status. Critical fix: `.notDetermined` is BOTH the transient
    /// pre-probe state AND the permanent "user never granted" state, so gating
    /// the toggle on `notifAuthStatus == .notDetermined` left a user who had
    /// never been asked with a PERMANENTLY disabled toggle — they could never tap
    /// it to trigger the OS permission prompt (chicken-and-egg lockout). Gating on
    /// `notifAuthProbed` instead enables the toggle once probed, so a
    /// `.notDetermined` user can tap it and the `set` handler requests auth.
    @State private var notifAuthProbed = false
    /// Whether to show the "notifications denied — open Settings" alert.
    @State private var showNotifDeniedAlert = false

    var body: some View {
        NavigationStack(path: $path) {
            List {
                accountSection
                appearanceAndPanelsSection
                notificationsAndSecuritySection
                devicesSection
                connectionSection
                aboutSection
            }
            .listStyle(.insetGrouped)
            // Content tokens paint the rows + canvas so the six themes keep their
            // identity over the system grouped list (the spec keeps `card`/`bg`
            // as content fills; the system would otherwise paint its own materials).
            .scrollContentBackground(.hidden)
            .background(theme.bg)
            // PSF-04: use the standard navigationTitle so this root matches all
            // pushed-stack panels (DevicesView, AboutPanel, etc.) — the system
            // renders the inline title consistently; the custom `.principal`
            // ToolbarItem it replaced was a bespoke re-implementation that differed
            // from the pushed views and produced mismatched title sizes on iOS 26.
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { header }
            .navigationDestination(for: ControlPanel.self) { panel in
                panelView(panel)
                    .background(theme.bg)
            }
            .task { await probeNotifStatus() }
            // Re-probe when the sheet returns to active (e.g. after the user
            // re-granted in the system Settings app).
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
                Task { await probeNotifStatus() }
            }
            .alert("Notifications Blocked", isPresented: $showNotifDeniedAlert) {
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Notification access is blocked. Allow it in Settings to receive agent alerts on this device.")
            }
        }
    }

    // MARK: - Header (X item / centered title / info item)

    @ToolbarContentBuilder
    private var header: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            // Standard toolbar close item. On iOS 26 the system renders toolbar
            // items as floating glass automatically; on 17–25 classic — both
            // correct, zero custom drawing. (`xmark` glyph keeps the established
            // close affordance.)
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
            }
            .accessibilityLabel("Close settings")
            .accessibilityIdentifier("settingsClose")
        }
        // PSF-04: principal ToolbarItem removed — the title now comes from
        // .navigationTitle("Settings") above, matching all pushed-stack panels.
        ToolbarItem(placement: .topBarTrailing) {
            // Info item → About (version). Pushes the same place as the About row
            // so the affordance has a destination (mirrors Claude's info pill).
            Button {
                path.append(ControlPanel.about)
            } label: {
                Image(systemName: "info.circle")
            }
            .accessibilityLabel("About Hermes")
            .accessibilityIdentifier("settingsInfo")
        }
    }

    // MARK: - Account / server section (content card)

    /// The account header card: an avatar circle with the user's initials, the
    /// editable display name, and the server URL. A single content card hosted in
    /// the list's first section (Claude's "account email card"). It is content,
    /// not chrome, so it keeps its themed card fill + hairline.
    private var accountSection: some View {
        Section {
            HStack(spacing: 14) {
                avatarCircle
                VStack(alignment: .leading, spacing: 2) {
                    TextField("Your name", text: $displayName)
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(theme.fg)
                        .textInputAutocapitalization(.words)
                        .autocorrectionDisabled()
                        .submitLabel(.done)
                        .accessibilityIdentifier("displayNameField")
                    Text(serverDisplay)
                        .font(.footnote)
                        .foregroundStyle(theme.mutedFg)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 4)
            .listRowBackground(theme.card)
        }
    }

    /// Circular avatar holding the display-name initials (or a person glyph when
    /// the name is unset). Mirrors the drawer avatar so the two read as one
    /// identity.
    private var avatarCircle: some View {
        ZStack {
            Circle().fill(theme.midground)
            if let initials = avatarInitials {
                Text(initials)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(theme.midground.contrastingForeground)
            } else {
                Image(systemName: "person.fill")
                    .font(.title3)
                    .foregroundStyle(theme.midground.contrastingForeground)
            }
        }
        .frame(width: 48, height: 48)
        .accessibilityHidden(true)
    }

    /// Up to two uppercased initials from the display name, or `nil` when unset.
    private var avatarInitials: String? {
        guard let name = DefaultsKeys.displayNameValue() else { return nil }
        let parts = name.split(separator: " ").prefix(2)
        let letters = parts.compactMap { $0.first }.map(String.init)
        let joined = letters.joined().uppercased()
        return joined.isEmpty ? nil : joined
    }

    private var serverDisplay: String {
        connectionStore.serverURLString.isEmpty ? "Not connected"
                                                 : connectionStore.serverURLString
    }

    // MARK: - Appearance + control panels

    @ViewBuilder
    private var appearanceAndPanelsSection: some View {
        Section {
            // Appearance — inline current theme name; tap pushes the picker within
            // this sheet's own NavigationStack via the system NavigationLink. The
            // list cell IS the (full-width, ≥44pt) hit target — the system owns
            // the geometry, deleting the prior collapsed-hit-target bug class.
            NavigationLink(value: ControlPanel.appearance) {
                SettingsRow(
                    icon: "paintpalette",
                    title: "Appearance",
                    value: themeStore.current.label
                )
            }
            .listRowBackground(theme.card)
            .accessibilityIdentifier("settingsAppearanceRow")

            // UI language — in-app switch (pt-BR / English / follow system).
            // Applies live via ``LocalizationManager`` (no app restart).
            Picker(selection: Binding(
                get: { localization.language },
                set: { localization.setLanguage($0) }
            )) {
                ForEach(LocalizationManager.Language.allCases) { lang in
                    Text(lang.displayName).tag(lang)
                }
            } label: {
                Label("Language", systemImage: "globe")
                    .foregroundStyle(theme.fg)
            }
            .tint(theme.mutedFg)
            .listRowBackground(theme.card)
            .accessibilityIdentifier("settingsLanguagePicker")

            // Control panels — each pushes within this sheet's stack.
            if connectionStore.control != nil {
                ForEach(ControlPanel.pushable) { panel in
                    NavigationLink(value: panel) {
                        SettingsRow(
                            icon: panel.systemImage,
                            title: panel.title,
                            value: panel.inlineValue(connectionStore: connectionStore)
                        )
                    }
                    .listRowBackground(theme.card)
                    .accessibilityIdentifier(panel.accessibilityIdentifier)
                }
            } else {
                // Disconnected placeholder: describe + offer a Reconnect CTA.
                VStack(alignment: .leading, spacing: 8) {
                    SettingsRow(
                        icon: "cpu",
                        title: "Connect to manage models, automations, and more.",
                        value: nil,
                        muted: true
                    )
                    Button {
                        reconnect()
                    } label: {
                        Label("Reconnect", systemImage: "arrow.clockwise")
                            .font(.system(size: reconnectLabelFontSize, weight: .medium))
                            .foregroundStyle(theme.midground)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("settingsReconnect")
                }
                .listRowBackground(theme.card)
            }
        }
    }

    // MARK: - Notifications + Security (inline toggles)

    @ViewBuilder
    private var notificationsAndSecuritySection: some View {
        Section {
            // Notifications — inline Toggle (master opt-in).
            // P0 PERMISSION BRIDGE: if the OS has denied notification access the
            // toggle is blocked from turning on — instead it snaps back to OFF and
            // an alert offers "Open Settings". While status is .notDetermined the
            // toggle is disabled (we probe on appear and on foreground).
            Toggle(isOn: Binding(
                get: { PushRegistrar.shared.isEnabled },
                set: { newValue in
                    guard newValue else {
                        // Turning off is always allowed.
                        PushRegistrar.shared.setEnabled(false)
                        return
                    }
                    switch notifAuthStatus {
                    case .denied:
                        // Snap the toggle back and show the alert.
                        showNotifDeniedAlert = true
                        // Don't call setEnabled — the toggle binding will revert.
                    case .authorized, .provisional, .ephemeral:
                        PushRegistrar.shared.setEnabled(true)
                    case .notDetermined:
                        // Let PushRegistrar request authorization normally.
                        PushRegistrar.shared.setEnabled(true)
                    @unknown default:
                        PushRegistrar.shared.setEnabled(true)
                    }
                }
            )) {
                SettingsRowLabel(icon: "bell", title: "Notifications")
            }
            // Disable only while the FIRST probe is in flight, or when the server
            // genuinely doesn't support push. A settled `.notDetermined` (user
            // never granted) leaves the toggle ENABLED so tapping it triggers the
            // OS permission prompt via the `set` handler above.
            .disabled(pushUnsupported || !notifAuthProbed)
            .listRowBackground(theme.card)

            // Per-event push prefs (A4): three native Toggles, shown only when
            // push is on (they have no effect otherwise). Each change re-POSTs
            // /api/push/register with the new events list. Pure system Toggles —
            // chrome via the system, identity via the .tint applied app-wide.
            if PushRegistrar.shared.isEnabled && !pushUnsupported {
                Toggle(isOn: $notifyApproval) {
                    SettingsRowLabel(icon: "checkmark.shield", title: "Approvals")
                }
                .listRowBackground(theme.card)
                .accessibilityIdentifier("notifyApprovalsToggle")
                .onChange(of: notifyApproval) { _, _ in
                    PushRegistrar.shared.reRegisterEvents()
                }

                Toggle(isOn: $notifyClarify) {
                    SettingsRowLabel(icon: "questionmark.circle", title: "Questions")
                }
                .listRowBackground(theme.card)
                .accessibilityIdentifier("notifyQuestionsToggle")
                .onChange(of: notifyClarify) { _, _ in
                    PushRegistrar.shared.reRegisterEvents()
                }

                Toggle(isOn: $notifyTurnComplete) {
                    SettingsRowLabel(icon: "clock.badge.checkmark", title: "Long turns")
                }
                .listRowBackground(theme.card)
                .accessibilityIdentifier("notifyLongTurnsToggle")
                .onChange(of: notifyTurnComplete) { _, _ in
                    PushRegistrar.shared.reRegisterEvents()
                }
            }

            // Security — App Lock Toggle with dynamic biometric label.
            Toggle(isOn: Binding(
                get: { appLock.isEnabled },
                set: { appLock.setEnabled($0) }
            )) {
                SettingsRowLabel(
                    icon: biometricSystemImage,
                    title: "Require \(biometricLabel)"
                )
            }
            .listRowBackground(theme.card)
            .accessibilityIdentifier("settingsAppLockToggle")

            // Secrets biometric gate — separate toggle from app-lock.
            Toggle(isOn: Binding(
                get: { DefaultsKeys.requiresBiometricForSecretsValue() },
                set: { UserDefaults.standard.set($0, forKey: DefaultsKeys.requiresBiometricForSecrets) }
            )) {
                SettingsRowLabel(
                    icon: biometricSystemImage,
                    title: "Require \(biometricLabel) for secrets"
                )
            }
            .listRowBackground(theme.card)
            .accessibilityIdentifier("settingsSecretsbiometricToggle")
        } footer: {
            if pushUnsupported {
                Text("Notifications are not supported by this server.")
            } else if notifAuthStatus == .denied {
                Text("Notification access is blocked. Tap Notifications to open Settings and re-grant.")
            } else if PushRegistrar.shared.isEnabled {
                Text("Choose which agent events notify you on this device.")
            }
        }
    }

    // MARK: - Devices (W3A-A — feature-detected; hidden on a stock server)

    /// The W3a Devices section — a single push to ``DevicesView`` (the native
    /// device list + revoke + approval audit). Rendered ONLY when the connected
    /// gateway advertises the `devices` capability AND a live REST client exists;
    /// on a stock hermes-agent (`devices != .available`) the whole section is
    /// absent and the legacy shared token is untouched (W3a stock degradation).
    @ViewBuilder
    private var devicesSection: some View {
        if connectionStore.capabilities.devices == .available,
           let rest = connectionStore.rest {
            Section {
                NavigationLink {
                    DevicesView(
                        rest: rest,
                        serverURL: connectionStore.serverURLString,
                        authenticator: LAContextAuthenticator()
                    )
                } label: {
                    SettingsRow(icon: "iphone.and.arrow.forward", title: "Devices", value: nil)
                }
                .listRowBackground(theme.card)
                .accessibilityIdentifier("settingsDevices")
            } footer: {
                Text("Manage the devices paired with this server and review who approved what.")
            }
        }
    }

    // MARK: - Connection (server value + destructive disconnect)

    @ViewBuilder
    private var connectionSection: some View {
        Section {
            LabeledContent {
                Text(serverDisplay)
                    .foregroundStyle(theme.mutedFg)
                    .lineLimit(1)
                    .truncationMode(.middle)
            } label: {
                SettingsRowLabel(icon: "network", title: "Server")
            }
            .listRowBackground(theme.card)

            Button(role: .destructive) {
                confirmingDisconnect = true
            } label: {
                SettingsRowLabel(
                    icon: "rectangle.portrait.and.arrow.right",
                    title: "Disconnect",
                    destructive: true
                )
            }
            .listRowBackground(theme.card)
            .accessibilityIdentifier("settingsDisconnect")
            .confirmationDialog(
                "Disconnect from this server?",
                isPresented: $confirmingDisconnect,
                titleVisibility: .visible
            ) {
                Button("Disconnect", role: .destructive) {
                    Task {
                        await connectionStore.disconnect()
                        dismiss()
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("You'll need the server URL and token to reconnect.")
            }
        }
    }

    // MARK: - About (version inline + push)

    @ViewBuilder
    private var aboutSection: some View {
        Section {
            NavigationLink(value: ControlPanel.about) {
                SettingsRow(icon: "info.circle", title: "About", value: appVersion)
            }
            .listRowBackground(theme.card)
            .accessibilityIdentifier("settingsAbout")
        }
    }

    // MARK: - Control panels

    /// The control panels reachable from Settings. `model … gateway` push the
    /// live control surface; `about` is the local version page (no control
    /// client needed) and is excluded from ``pushable``.
    private enum ControlPanel: String, Identifiable, Hashable {
        case appearance, model, personality, usage, cron, skills, gateway, about
        var id: String { rawValue }

        /// The panels that need a live control client (`appearance` + `about` do
        /// NOT — they are local pages, excluded from ``pushable``).
        static var pushable: [ControlPanel] {
            [.model, .personality, .usage, .cron, .skills, .gateway]
        }

        var title: LocalizedStringKey {
            switch self {
            case .appearance: return "Appearance"
            case .model: return "Model"
            case .personality: return "Personality"
            case .usage: return "Usage"
            case .cron: return "Automations"
            case .skills: return "Skills"
            case .gateway: return "Gateway Status"
            case .about: return "About"
            }
        }

        var systemImage: String {
            switch self {
            case .appearance: return "paintpalette"
            case .model: return "cpu"
            case .personality: return "theatermasks"
            case .usage: return "chart.bar"
            case .cron: return "clock.arrow.circlepath"
            case .skills: return "wand.and.stars"
            case .gateway: return "network"
            case .about: return "info.circle"
            }
        }

        var accessibilityIdentifier: String { "settings\(rawValue.capitalized)" }

        /// The inline value shown on the row (right-aligned, before the chevron).
        /// Only Model surfaces one — the running model name (F0) — so the
        /// most-used panel reads its state without a push.
        @MainActor
        func inlineValue(connectionStore: ConnectionStore) -> String? {
            switch self {
            case .model: return connectionStore.activeModelName
            default: return nil
            }
        }
    }

    @ViewBuilder
    private func panelView(_ panel: ControlPanel) -> some View {
        switch panel {
        case .appearance:
            // Local page — no control client needed; pushes the theme picker
            // within this sheet's own NavigationStack.
            AppearanceView(store: themeStore)
                .background(theme.bg)
        case .about:
            AboutPanel(appVersion: appVersion, connectionStore: connectionStore)
        default:
            if let control = connectionStore.control {
                switch panel {
                case .model:
                    // pass the WS client so the global default
                    // fast/reasoning controls are shown in Settings.
                    ModelPickerView(
                        control: control,
                        gatewayClient: connectionStore.client
                    ) {
                        // Keep the running-model chip in sync after a switch made
                        // from Settings (F0 / Amendment B).
                        Task { await connectionStore.refreshActiveModel() }
                    }
                case .personality:
                    PersonalityPickerView(
                        control: control,
                        client: connectionStore.client,
                        activeSessionId: sessionStore.activeRuntimeId
                    )
                case .usage:
                    UsageView(control: control)
                case .cron:
                    CronJobsView(control: control)
                case .skills:
                    SkillsBrowserView(control: control)
                case .gateway:
                    GatewayStatusView(control: control)
                case .appearance, .about:
                    EmptyView() // handled by the outer switch
                }
            } else {
                ContentUnavailableView(
                    "Not connected",
                    systemImage: "wifi.slash",
                    description: Text("Reconnect to manage this.")
                )
            }
        }
    }

    // MARK: - Derived

    /// Whether the connected gateway is known NOT to support push registration
    /// (stock server, E1). Only `.unavailable` disables the toggle.
    private var pushUnsupported: Bool {
        connectionStore.capabilities.pushRegistry == .unavailable
    }

    /// "1.0 (1)" from the bundle's short version + build number.
    private var appVersion: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "—"
        let build = info?["CFBundleVersion"] as? String ?? "—"
        return "\(short) (\(build))"
    }

    /// SF Symbol name for the device's biometric type (delegated to ``AppLock``).
    private var biometricSystemImage: String { AppLock.biometricSystemImage }

    /// Human label for the device's biometric type (delegated to ``AppLock``).
    private var biometricLabel: String { AppLock.biometricLabel }

    // MARK: - Notification authorization probe

    /// Fetch the current UNAuthorizationStatus and store it in ``notifAuthStatus``.
    /// Must be called on appear and on every foreground transition so the UI
    /// reflects any change the user made in the system Settings app.
    private func probeNotifStatus() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        notifAuthStatus = settings.authorizationStatus
        notifAuthProbed = true
    }

    // MARK: - Reconnect

    /// Re-issue `configure` against the saved server + Keychain token, mirroring
    /// the ``ConnectionStatusBanner`` retry path.
    private func reconnect() {
        Task {
            guard let url = URL(string: connectionStore.serverURLString),
                  let host = url.host, !host.isEmpty,
                  let token = KeychainService.loadToken(server: connectionStore.serverURLString) else {
                return
            }
            _ = await connectionStore.configure(
                urlString: connectionStore.serverURLString,
                token: token
            )
        }
    }
}

// MARK: - Native row primitives
//

// These are thin LABEL builders for system list cells — NOT custom row
// containers. The enclosing `NavigationLink` / `Toggle` / `LabeledContent` /
// `Button` owns the cell chrome, the hit target, the chevron, and the
// separators; these only lay out the icon + title (+ optional inline value) the
// system cell wraps. No backgrounds, no hairlines, no padding-as-geometry.

/// A leading-icon + title label for a system list cell. Used as the label of a
/// `Toggle`, `LabeledContent`, or destructive `Button`.
private struct SettingsRowLabel: View {
    @Environment(\.hermesTheme) private var theme

    let icon: String
    let title: LocalizedStringKey
    var destructive: Bool = false

    var body: some View {
        Label {
            Text(title)
                .foregroundStyle(destructive ? theme.destructive : theme.fg)
        } icon: {
            Image(systemName: icon)
                .foregroundStyle(destructive ? theme.destructive : theme.fg)
        }
    }
}

/// A list cell label that also carries an optional trailing inline value (the
/// system `NavigationLink` adds the disclosure chevron). Used by the Appearance
/// row, the pushable control panels, and About.
private struct SettingsRow: View {
    @Environment(\.hermesTheme) private var theme

    let icon: String
    let title: LocalizedStringKey
    var value: String?
    var muted: Bool = false

    var body: some View {
        HStack(spacing: 12) {
            Label {
                Text(title)
                    .foregroundStyle(muted ? theme.mutedFg : theme.fg)
            } icon: {
                Image(systemName: icon)
                    .foregroundStyle(theme.fg)
            }
            if let value, !value.isEmpty {
                Spacer(minLength: 8)
                Text(value)
                    .font(.body)
                    .foregroundStyle(theme.mutedFg)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
    }
}

// MARK: - About panel (minimal+)

/// The local "About" page pushed from the About row / info item.
///

/// Shows: app version, gateway version + release date (fetched lazily from the
/// REST status endpoint if connected), and a Release Notes external link.
/// No update-check machinery — that lives on the desktop. On a disconnected
/// gateway the server rows show "—" (graceful degradation).
private struct AboutPanel: View {
    @Environment(\.hermesTheme) private var theme
    @Environment(\.openURL) private var openURL

    let appVersion: String
    let connectionStore: ConnectionStore

    /// Gateway version string from `GET /api/status`, e.g. "1.4.2".
    @State private var gatewayVersion: String = "—"
    /// Release date / build stamp from `GET /api/status` (closest available
    /// proxy for a build SHA on the stock REST shape).
    @State private var buildStamp: String = "—"

    private static let releaseNotesURL = URL(
        string: "https://github.com/NousResearch/hermes-agent/releases"
    )!

    var body: some View {
        List {
            Section("App") {
                LabeledContent("Version", value: appVersion)
                    .listRowBackground(theme.card)
                    .accessibilityIdentifier("aboutAppVersion")
            }
            Section("Gateway") {
                LabeledContent("Version", value: gatewayVersion)
                    .listRowBackground(theme.card)
                    .accessibilityIdentifier("aboutGatewayVersion")
                LabeledContent("Build") {
                    Text(buildStamp)
                        .font(.footnote.monospaced())
                        .foregroundStyle(theme.mutedFg)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
                .listRowBackground(theme.card)
                .accessibilityIdentifier("aboutBuildStamp")
            }
            Section {
                Button {
                    openURL(Self.releaseNotesURL)
                } label: {
                    Label("Release Notes", systemImage: "arrow.up.right.square")
                        .foregroundStyle(theme.midground)
                }
                .listRowBackground(theme.card)
                .accessibilityIdentifier("aboutReleaseNotes")
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(theme.bg)
        .navigationTitle("About")
        .navigationBarTitleDisplayMode(.inline)
        .task { await loadGatewayInfo() }
    }

    private func loadGatewayInfo() async {
        guard let rest = connectionStore.rest else { return }
        do {
            let status = try await rest.gatewayStatus()
            if let v = status.version, !v.isEmpty {
                gatewayVersion = v
            }
            if let release = status.releaseDate, !release.isEmpty {
                buildStamp = release
            }
        } catch {
            // Graceful degradation: leave the "—" placeholders.
        }
    }
}
