import SwiftUI

/// Full-surface background for themed roots. Paints the supplied base color and,
/// for the adaptive `nous` palette only, layers the desktop-style "nous"
/// backdrop (a warm top-left glow + a faint texture grain) on top. Every other
/// palette renders the flat base color unchanged.
///
/// This mirrors the *visual feel* of the desktop `Backdrop.tsx` (warmGlow +
/// filler texture from `web/src/themes/presets.ts`) WITHOUT replicating its LENS
/// foreground-inversion mechanism — so all component contrast/legibility tokens
/// stay exactly as they are today. Drop it in wherever a full-bleed `theme.bg`
/// (or `theme.listBg`) fill is painted.
///
/// Usage:
/// ```swift
/// .background { HermesSurfaceBackground(theme: theme).ignoresSafeArea() }
/// ```
struct HermesSurfaceBackground: View {
    let theme: HermesTheme
    /// The opaque base fill. Defaults to `theme.bg`; surfaces like the drawer
    /// pass `theme.listBg` so the glow sits over their own canvas color.
    let base: Color

    init(theme: HermesTheme, base: Color? = nil) {
        self.theme = theme
        self.base = base ?? theme.bg
    }

    var body: some View {
        ZStack {
            base
            // Gated on the only adaptive palette; the five forced-dark themes
            // keep their flat surfaces (the backdrop is a `nous`-specific look).
            if theme.name == "nous" {
                NousBackdrop()
            }
        }
    }
}

/// The additive "nous" layer stack — designed to sit OVER an opaque base fill.
///
/// Desktop source of truth (`web/src/components/Backdrop.tsx` + the `nous`
/// preset in `presets.ts`):
///   • filler texture — `filler-bg0` at opacity ~0.02–0.033, blend `difference`
///   • warm vignette  — `warmGlow: rgba(255, 189, 56, 0.35)`, opacity 0.22,
///                       blend `lighten`, radial from the top-left corner
///
/// The desktop's `difference`/inversion blends flip the whole canvas (LENS_5I);
/// we deliberately skip that and use gentle, non-inverting SwiftUI blends so the
/// look reads the same on both the light (near-white) and dark (deep-blue) nous
/// canvases without disturbing foreground contrast.
private struct NousBackdrop: View {
    @Environment(\.colorScheme) private var scheme

    /// The glow hue is the *displayed* color, not the desktop's amber source.
    /// On the desktop the amber `warmGlow` (#FFAC02) is flipped by the LENS FG
    /// inversion into nous-blue — the `nous-blue` preset's own swatch is
    /// `#0053FD` / `#E8F2FD`. So the light canvas gets a cool nous-blue wash
    /// (painting amber here would just muddy the near-white surface to gray).
    /// The bespoke dark palette ("psyche cream over deep nous blue") instead
    /// takes a warm cream glow that lifts the deep-blue canvas.
    private static let lightGlow = Color(hex: "#0053FD")  // displayed nous-blue
    private static let darkGlow = Color(hex: "#FFE6CB")   // psyche cream

    private var isDark: Bool { scheme == .dark }

    var body: some View {
        GeometryReader { geo in
            // Reach roughly corner-to-corner so the glow falls off across the
            // whole surface rather than pooling in the top-left.
            let glowRadius = max(geo.size.width, geo.size.height) * 0.95

            ZStack {
                // Texture grain — DARK canvas only. On the near-white light
                // canvas the gray filler texture only muddies the surface (the
                // "grayish" look), and the desktop's grain is essentially
                // invisible there anyway, so it is omitted in light mode.
                if isDark {
                    Image("NousBackdropTexture")
                        .resizable()
                        .scaledToFill()
                        .frame(width: geo.size.width, height: geo.size.height)
                        .clipped()
                        .opacity(0.10)
                        .blendMode(.softLight)
                }

                // Corner glow. Light: a cool nous-blue wash painted with normal
                // alpha for clean, non-gray depth that matches the desktop's
                // post-inversion blue. Dark: a warm cream glow lifted with
                // `screen` over the deep-blue canvas.
                RadialGradient(
                    colors: [
                        (isDark ? Self.darkGlow : Self.lightGlow)
                            .opacity(isDark ? 0.22 : 0.09),
                        .clear
                    ],
                    center: .topLeading,
                    startRadius: 0,
                    endRadius: glowRadius
                )
                .blendMode(isDark ? .screen : .normal)
            }
        }
        // Purely decorative — never intercept touches meant for the content.
        .allowsHitTesting(false)
    }
}
