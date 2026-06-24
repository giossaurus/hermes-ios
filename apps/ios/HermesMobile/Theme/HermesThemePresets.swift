import SwiftUI

/// The six built-in palettes, transcribed verbatim from the desktop
/// `the desktop app`. Hex strings are exact; every desktop
/// `color-mix(in srgb, …)` is pre-resolved to a literal value here (sRGB
/// per-component mix; transparent mixes become an alpha on the mixed color):
///

///  nousTint(p) = mix(#0053FD, #FFFFFF, p%)
///  nousTintTransparent(p) = #0053FD at alpha p%
///

///  muted nousTint(5) -> #F2F6FF
///  secondary nousTint(7) -> #EDF3FF
///  accent nousTint(10) -> #E6EEFF
///  userBubble nousTint(6) -> #F0F5FF
///  border nousTintTransparent(22) -> #0053FD @ 22% (#0053FD38)
///  input nousTintTransparent(30) -> #0053FD @ 30% (#0053FD4C)
///  sidebarBorder nousTintTransparent(18) -> #0053FD @ 18% (#0053FD2E)
///  userBubbleBorder nousTintTransparent(24) -> #0053FD @ 24% (#0053FD3D)
///

/// `nous` is the only adaptive set (light + hand-tuned dark pair, follows the
/// system). The other five are single dark palettes that force `.dark` so system
/// chrome (keyboards, menus, the status bar) matches the palette.
enum HermesThemePresets {

    // MARK: nous (adaptive light + dark)

    /// Light palette — glass neutrals with Nous-blue accents.
    static let nousLight = HermesTheme(
        name: "nous",
        label: "Nous",
        forcedColorScheme: nil,
        bg: Color(hex: "#F8FAFF"),
        fg: Color(hex: "#17171A"),
        card: Color(hex: "#FFFFFF"),
        cardFg: Color(hex: "#17171A"),
        muted: Color(hex: "#F2F6FF"),            // nousTint(5)
        mutedFg: Color(hex: "#666678"),
        popover: Color(hex: "#FFFFFF"),
        popoverFg: Color(hex: "#17171A"),
        primary: Color(hex: "#0053FD"),
        primaryFg: Color(hex: "#FCFCFC"),
        secondary: Color(hex: "#EDF3FF"),        // nousTint(7)
        secondaryFg: Color(hex: "#242432"),
        accent: Color(hex: "#E6EEFF"),           // nousTint(10)
        accentFg: Color(hex: "#202030"),
        border: Color(hex: "#0053FD38"),         // nousTintTransparent(22)
        input: Color(hex: "#0053FD4C"),          // nousTintTransparent(30)
        midground: Color(hex: "#0053FD"),
        composerRing: Color(hex: "#0053FD"),
        destructive: Color(hex: "#C72E4D"),
        destructiveFg: Color(hex: "#FFFFFF"),
        listBg: Color(hex: "#F3F7FF"),           // sidebarBackground
        listBorder: Color(hex: "#0053FD2E"),     // sidebarBorder nousTintTransparent(18)
        userBubble: Color(hex: "#F0F5FF"),       // nousTint(6)
        userBubbleBorder: Color(hex: "#0053FD3D") // nousTintTransparent(24)
    )

    /// Dark palette — psyche cream over deep Nous blue.
    static let nousDark = HermesTheme(
        name: "nous",
        label: "Nous",
        forcedColorScheme: nil,
        bg: Color(hex: "#0D2F86"),
        fg: Color(hex: "#FFE6CB"),               // PSYCHE_WARM
        card: Color(hex: "#12378F"),
        cardFg: Color(hex: "#FFE6CB"),
        muted: Color(hex: "#183F9A"),
        mutedFg: Color(hex: "#B5C7F3"),
        popover: Color(hex: "#123A96"),
        popoverFg: Color(hex: "#FFE6CB"),
        primary: Color(hex: "#FFE6CB"),
        primaryFg: Color(hex: "#0D2F86"),
        secondary: Color(hex: "#1B45A4"),
        secondaryFg: Color(hex: "#E0E8FF"),
        accent: Color(hex: "#1540B1"),           // PSYCHE_BLUE
        accentFg: Color(hex: "#F0F4FF"),
        border: Color(hex: "#3158AD"),
        input: Color(hex: "#0B2566"),
        midground: Color(hex: "#0053FD"),
        composerRing: Color(hex: "#FFE6CB"),
        destructive: Color(hex: "#C0473A"),
        destructiveFg: Color(hex: "#FEF2F2"),
        listBg: Color(hex: "#09286F"),
        listBorder: Color(hex: "#234A9C"),
        userBubble: Color(hex: "#143B91"),
        userBubbleBorder: Color(hex: "#3A63BD")
    )

    static let nous = HermesThemeSet(light: nousLight, dark: nousDark)

    // MARK: midnight (forced dark)

    static let midnight = HermesThemeSet(light: HermesTheme(
        name: "midnight",
        label: "Midnight",
        forcedColorScheme: .dark,
        bg: Color(hex: "#08081C"),
        fg: Color(hex: "#DDD6FF"),
        card: Color(hex: "#0D0D28"),
        cardFg: Color(hex: "#DDD6FF"),
        muted: Color(hex: "#13133A"),
        mutedFg: Color(hex: "#7C7AB0"),
        popover: Color(hex: "#0F0F2E"),
        popoverFg: Color(hex: "#DDD6FF"),
        primary: Color(hex: "#DDD6FF"),
        primaryFg: Color(hex: "#08081C"),
        secondary: Color(hex: "#1A1A4A"),
        secondaryFg: Color(hex: "#C4BFF0"),
        accent: Color(hex: "#1A1A44"),
        accentFg: Color(hex: "#D0C8FF"),
        border: Color(hex: "#1E1E52"),
        input: Color(hex: "#1E1E52"),
        midground: Color(hex: "#8B80E8"),
        destructive: Color(hex: "#B03060"),
        destructiveFg: Color(hex: "#FEF2F2"),
        listBg: Color(hex: "#06061A"),
        listBorder: Color(hex: "#12123A"),
        userBubble: Color(hex: "#14143A"),
        userBubbleBorder: Color(hex: "#242466")
    ))

    // MARK: ember (forced dark)

    static let ember = HermesThemeSet(light: HermesTheme(
        name: "ember",
        label: "Ember",
        forcedColorScheme: .dark,
        bg: Color(hex: "#160800"),
        fg: Color(hex: "#FFD8B0"),
        card: Color(hex: "#1E0E04"),
        cardFg: Color(hex: "#FFD8B0"),
        muted: Color(hex: "#2A1408"),
        mutedFg: Color(hex: "#AA7A56"),
        popover: Color(hex: "#221008"),
        popoverFg: Color(hex: "#FFD8B0"),
        primary: Color(hex: "#FFD8B0"),
        primaryFg: Color(hex: "#160800"),
        secondary: Color(hex: "#341800"),
        secondaryFg: Color(hex: "#F0C090"),
        accent: Color(hex: "#301600"),
        accentFg: Color(hex: "#E8C080"),
        border: Color(hex: "#3A1C08"),
        input: Color(hex: "#3A1C08"),
        midground: Color(hex: "#D97316"),
        destructive: Color(hex: "#C43010"),
        destructiveFg: Color(hex: "#FEF2F2"),
        listBg: Color(hex: "#100600"),
        listBorder: Color(hex: "#2A1004"),
        userBubble: Color(hex: "#2A1000"),
        userBubbleBorder: Color(hex: "#4A2010")
    ))

    // MARK: mono (forced dark)

    static let mono = HermesThemeSet(light: HermesTheme(
        name: "mono",
        label: "Mono",
        forcedColorScheme: .dark,
        bg: Color(hex: "#0E0E0E"),
        fg: Color(hex: "#EAEAEA"),
        card: Color(hex: "#141414"),
        cardFg: Color(hex: "#EAEAEA"),
        muted: Color(hex: "#1E1E1E"),
        mutedFg: Color(hex: "#808080"),
        popover: Color(hex: "#181818"),
        popoverFg: Color(hex: "#EAEAEA"),
        primary: Color(hex: "#EAEAEA"),
        primaryFg: Color(hex: "#0E0E0E"),
        secondary: Color(hex: "#262626"),
        secondaryFg: Color(hex: "#C8C8C8"),
        accent: Color(hex: "#222222"),
        accentFg: Color(hex: "#D8D8D8"),
        border: Color(hex: "#2A2A2A"),
        input: Color(hex: "#2A2A2A"),
        midground: Color(hex: "#9A9A9A"),
        destructive: Color(hex: "#A84040"),
        destructiveFg: Color(hex: "#FEF2F2"),
        listBg: Color(hex: "#0A0A0A"),
        listBorder: Color(hex: "#202020"),
        userBubble: Color(hex: "#1A1A1A"),
        userBubbleBorder: Color(hex: "#363636"),
        // mono is grayscale; keep the status trio chromatic so connection
        // health stays legible against the neutral palette (architect: derive
        // status colors, don't desaturate them away).
        statusError: Color(hex: "#A84040")
    ))

    // MARK: cyberpunk (forced dark)

    static let cyberpunk = HermesThemeSet(light: HermesTheme(
        name: "cyberpunk",
        label: "Cyberpunk",
        forcedColorScheme: .dark,
        bg: Color(hex: "#000A00"),
        fg: Color(hex: "#00FF41"),
        card: Color(hex: "#001200"),
        cardFg: Color(hex: "#00FF41"),
        muted: Color(hex: "#001A00"),
        mutedFg: Color(hex: "#1A8A30"),
        popover: Color(hex: "#001000"),
        popoverFg: Color(hex: "#00FF41"),
        primary: Color(hex: "#00FF41"),
        primaryFg: Color(hex: "#000A00"),
        secondary: Color(hex: "#002800"),
        secondaryFg: Color(hex: "#00CC34"),
        accent: Color(hex: "#002000"),
        accentFg: Color(hex: "#00E038"),
        border: Color(hex: "#003000"),
        input: Color(hex: "#003000"),
        midground: Color(hex: "#00FF41"),
        destructive: Color(hex: "#FF003C"),
        destructiveFg: Color(hex: "#000A00"),
        listBg: Color(hex: "#000600"),
        listBorder: Color(hex: "#001800"),
        userBubble: Color(hex: "#001400"),
        userBubbleBorder: Color(hex: "#004800"),
        // The matrix palette is monochrome green; an amber warn dot would clash,
        // so warn is tuned toward the theme's own neon while error stays its
        // pink destructive. OK uses the brand green.
        statusOK: Color(hex: "#00FF41"),
        statusWarn: Color(hex: "#E0E038"),
        statusError: Color(hex: "#FF003C")
    ))

    // MARK: slate (forced dark)

    static let slate = HermesThemeSet(light: HermesTheme(
        name: "slate",
        label: "Slate",
        forcedColorScheme: .dark,
        bg: Color(hex: "#0D1117"),
        fg: Color(hex: "#C9D1D9"),
        card: Color(hex: "#161B22"),
        cardFg: Color(hex: "#C9D1D9"),
        muted: Color(hex: "#21262D"),
        mutedFg: Color(hex: "#8B949E"),
        popover: Color(hex: "#1C2128"),
        popoverFg: Color(hex: "#C9D1D9"),
        primary: Color(hex: "#C9D1D9"),
        primaryFg: Color(hex: "#0D1117"),
        secondary: Color(hex: "#2A3038"),
        secondaryFg: Color(hex: "#ADB5BF"),
        accent: Color(hex: "#1E2530"),
        accentFg: Color(hex: "#C0C8D0"),
        border: Color(hex: "#30363D"),
        input: Color(hex: "#30363D"),
        midground: Color(hex: "#58A6FF"),
        destructive: Color(hex: "#CF4848"),
        destructiveFg: Color(hex: "#FEF2F2"),
        listBg: Color(hex: "#090D13"),
        listBorder: Color(hex: "#1C2228"),
        userBubble: Color(hex: "#1E2A38"),
        userBubbleBorder: Color(hex: "#2E4060")
    ))

    // MARK: Registry

    /// All sets in picker order. `nous` first (default + adaptive).
    static let all: [HermesThemeSet] = [nous, midnight, ember, mono, cyberpunk, slate]

    /// Default skin when nothing is persisted or the saved name is retired.
    static let defaultName = "nous"

    /// Canonical default set resolved from ``defaultName``.
    static var defaultSet: HermesThemeSet {
        all.first { $0.name == defaultName } ?? nous
    }

    /// Look up a set by persisted name, falling back to the current default set.
    static func set(named name: String) -> HermesThemeSet {
        all.first { $0.name == name } ?? defaultSet
    }
}
