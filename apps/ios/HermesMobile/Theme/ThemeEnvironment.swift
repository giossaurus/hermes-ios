import SwiftUI

// MARK: - Environment key

private struct HermesThemeKey: EnvironmentKey {
    /// Default to the light palette of the current default set so previews and
    /// any surface
    /// that forgets to re-install the theme still get a sane (non-crashing)
    /// value rather than an empty one.
    static let defaultValue: HermesTheme = HermesThemePresets.defaultSet.light
}

extension EnvironmentValues {
    /// The resolved palette for the current surface. Re-installed at every
    /// NavigationStack/sheet root via ``hermesThemed(_:)`` because SwiftUI sheets
    /// do not reliably inherit custom `EnvironmentValues` across presentation.
    var hermesTheme: HermesTheme {
        get { self[HermesThemeKey.self] }
        set { self[HermesThemeKey.self] = newValue }
    }
}

// MARK: - One-modifier theming helper

/// Bundles the three things every themed root needs into a single modifier so
/// migrators apply ONE thing at each sheet/stack root:
///

///  1. `\.hermesTheme` — the resolved palette in the environment.
///  2. `.tint(theme.midground)` — the global brand accent (fixes "half-skinned").
///  3. `.preferredColorScheme(store.forcedColorScheme)` — pins single-palette
///  themes to `.dark` so system chrome matches.
///

/// It also mirrors the live system scheme back into the store on appear/change so
/// the adaptive `nous` set resolves to the right variant.
///

/// Usage at every sheet / NavigationStack root:
/// ```swift
/// SettingsSheet()
///  .hermesThemed(themeStore)
/// ```
private struct HermesThemedModifier: ViewModifier {
    let store: ThemeStore
    @Environment(\.colorScheme) private var colorScheme
    /// Read the in-app language so the resolved `\.locale` can be RE-APPLIED at
    /// this root. SwiftUI does not reliably propagate `\.locale` across sheet /
    /// NavigationStack presentation boundaries (the same reason the theme is
    /// re-installed here), so a sheet would otherwise keep the system language
    /// even after the user switches in Settings. Optional so previews / any
    /// surface without the manager injected fall back to the system locale
    /// instead of trapping.
    @Environment(LocalizationManager.self) private var localization: LocalizationManager?

    func body(content: Content) -> some View {
        content
            .environment(\.hermesTheme, store.current)
            .environment(\.locale, localization?.locale ?? .autoupdatingCurrent)
            .tint(store.current.midground)
            .preferredColorScheme(store.forcedColorScheme)
            .onAppear { store.setSystemColorScheme(colorScheme) }
            .onChange(of: colorScheme) { _, newScheme in
                store.setSystemColorScheme(newScheme)
            }
            // Re-key the whole themed subtree when the in-app language changes, so
            // EVERY string re-resolves against the freshly-reclassed `Bundle.main`
            // — including values that resolve to a verbatim `String` and so don't
            // re-localize on their own (the draft greeting via `String(localized:)`,
            // and `String`-typed `navigationTitle`s). Applied at every root, so the
            // switch reflects live across chat, drawer, sheets and panels. Safe for
            // launch: the bootstrap `.task` sits OUTSIDE `.hermesThemed`, so this
            // inner `.id` never re-runs it. Resets transient view state (scroll,
            // drawer) on switch only — acceptable for a deliberate language toggle.
            .id(localization?.language.rawValue ?? "system")
    }
}

extension View {
    /// Apply the resolved theme (environment value + brand tint + forced color
    /// scheme) at a NavigationStack or sheet root. See ``HermesThemedModifier``.
    func hermesThemed(_ store: ThemeStore) -> some View {
        modifier(HermesThemedModifier(store: store))
    }
}
