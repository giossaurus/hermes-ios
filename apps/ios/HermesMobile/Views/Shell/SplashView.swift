import SwiftUI
import AVKit

/// Cold-launch brand splash: the portal-figure-orb clip over a deep `#0000F2`
/// canvas, with the "HERMES / AGENT" wordmark above it. The source art is
/// white/blue line work on a BLACK background; the bundled `splash.mov` is HEVC
/// with an alpha channel (black keyed out), so the blue shows through.
///
/// Flow: the `#0000F2` covers the app instantly. The wordmark + figure are
/// revealed TOGETHER the moment the player has its first frame ready (so the
/// title never beats the video on screen). The clip plays once at a slowed rate,
/// holds on its final frame, then the whole splash fades OUT gracefully into the
/// app. A safety timeout guarantees it never traps the user.
struct SplashView: View {
    let onFinish: () -> Void

    /// The home's resolved palette. On exit the splash drains its blue INTO
    /// `theme.bg` so its final frame matches the home (no blue/white blend).
    /// Inherited — the splash overlay sits under the app-root `.hermesThemed`.
    @Environment(\.hermesTheme) private var theme
    /// Drop the (tightly-cropped) figure below centre so its silhouette isn't
    /// framed dead-centre. Fraction of screen height.
    private static let verticalDropFraction: CGFloat = 0.28
    /// Wordmark position from the top, as a fraction of screen height — centres it
    /// in the upper blue band, clear of both the Dynamic Island and the video.
    private static let titleTopFraction: CGFloat = 0.20
    /// Wordmark point size (big, hero-scale serif).
    private static let titleSize: CGFloat = 64
    /// Playback rate < 1 stretches the 2.8s clip so the intro reads slower.
    private static let playbackRate: Float = 0.8
    /// Linger on the final frame before the fade-out.
    private static let endHold: Duration = .seconds(1.0)
    /// How fast the figure + wordmark appear once the first frame is ready.
    private static let revealDuration: Double = 0.3
    /// Exit "drain": the blue washes into `theme.bg` while the figure fades.
    /// Short + easeOut so it reads as snappy, not a slow/janky crossfade.
    private static let fadeOutDuration: Double = 0.4

    /// Figure + wordmark, shown together when the video is ready (`0` until then).
    @State private var revealOpacity = 0.0
    /// Backdrop fill — starts the brand blue, animates to the home bg on exit.
    @State private var backdropColor = Color(hex: "#0000F2")
    @State private var ending = false

    var body: some View {
        GeometryReader { geo in
            ZStack {
                // Opaque from frame 1 — covers the (still-initializing) app, and
                // STAYS opaque through exit (the home is never seen through a
                // translucent blue): it drains to the home bg instead.
                backdropColor.ignoresSafeArea()
                SplashVideoView(
                    rate: Self.playbackRate,
                    endHold: Self.endHold,
                    onReady: reveal,
                    onEnd: endSplash
                )
                .ignoresSafeArea()
                .offset(y: geo.size.height * Self.verticalDropFraction)
                .opacity(revealOpacity)
            }
            // Wordmark in the upper blue band — the same serif as the chat
            // greeting (ChatView `draftGreeting`), scaled up to hero size.
            .overlay(alignment: .top) {
                VStack(spacing: 4) {
                    Text("HERMES")
                    Text("AGENT")
                }
                .font(.system(size: Self.titleSize, weight: .regular, design: .serif))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .padding(.horizontal, 24)
                .padding(.top, geo.size.height * Self.titleTopFraction)
                .opacity(revealOpacity)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Hermes Agent")
            }
        }
        .ignoresSafeArea()
        .preferredColorScheme(.dark)
        .task {
            // Safety net: if the clip never signals ready/end, dismiss anyway.
            try? await Task.sleep(for: .seconds(8))
            endSplash()
        }
    }

    /// Reveal the figure + wordmark TOGETHER, the instant the video has its first
    /// frame ready, so the title never appears before the video.
    private func reveal() {
        guard revealOpacity == 0 else { return }
        withAnimation(.easeOut(duration: Self.revealDuration)) { revealOpacity = 1 }
    }

    /// Gracefully crossfade the whole splash out, then hand off to the app.
    private func endSplash() {
        guard !ending else { return }
        ending = true
        // Drain the blue into the home's own background while the figure +
        // wordmark fade out together — the splash's final frame already matches
        // the home, so there is no blue/white blend and no opacity crossfade of
        // the splash over the live home.
        withAnimation(.easeOut(duration: Self.fadeOutDuration)) {
            backdropColor = theme.bg
            revealOpacity = 0
        }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(Self.fadeOutDuration))
            onFinish()
        }
    }
}

/// Hosts an `AVPlayerLayer` — NOT SwiftUI `VideoPlayer`, which shows transport
/// controls and an opaque black backing. Aspect-fit + transparent backing so the
/// alpha video composites over the blue canvas behind it. Reports `onReady` when
/// the first frame is on screen and `onEnd` after the clip plays once + holds.
private struct SplashVideoView: UIViewRepresentable {
    let rate: Float
    let endHold: Duration
    let onReady: () -> Void
    let onEnd: () -> Void

    func makeUIView(context: Context) -> PlayerUIView {
        PlayerUIView(rate: rate, endHold: endHold, onReady: onReady, onEnd: onEnd)
    }

    func updateUIView(_ uiView: PlayerUIView, context: Context) {}

    static func dismantleUIView(_ uiView: PlayerUIView, coordinator: ()) {
        uiView.teardown()
    }
}

/// A `UIView` backed by an `AVPlayerLayer` that plays the bundled splash once and
/// reports first-frame readiness + completion. Non-opaque with a clear layer
/// background so the video's alpha composites over the SwiftUI canvas behind it.
private final class PlayerUIView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    private var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }

    private let player = AVPlayer()
    private let endHold: Duration
    private let onReady: () -> Void
    private let onEnd: () -> Void
    private var endObserver: NSObjectProtocol?
    private var readyObservation: NSKeyValueObservation?
    private var ended = false

    init(rate: Float, endHold: Duration, onReady: @escaping () -> Void, onEnd: @escaping () -> Void) {
        self.endHold = endHold
        self.onReady = onReady
        self.onEnd = onEnd
        super.init(frame: .zero)

        isOpaque = false
        backgroundColor = .clear
        playerLayer.player = player
        playerLayer.videoGravity = .resizeAspect
        // The layer must stay transparent, or the alpha video would composite
        // over black instead of the blue SwiftUI canvas behind this view.
        playerLayer.backgroundColor = UIColor.clear.cgColor

        guard let url = Bundle.main.url(forResource: "splash", withExtension: "mov") else {
            // Asset missing → end on the next runloop so launch is unblocked.
            Task { @MainActor [weak self] in self?.onEnd() }
            return
        }

        let item = AVPlayerItem(url: url)
        player.replaceCurrentItem(with: item)
        player.isMuted = true
        player.actionAtItemEnd = .pause

        // Reveal the splash content the moment the first frame can be drawn — KVO
        // fires off the main thread, so hop back before touching SwiftUI state.
        readyObservation = playerLayer.observe(\.isReadyForDisplay, options: [.initial, .new]) { [weak self] layer, _ in
            guard layer.isReadyForDisplay else { return }
            Task { @MainActor in self?.onReady() }
        }
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            // Hold the final frame, then end.
            Task { @MainActor in
                try? await Task.sleep(for: self.endHold)
                self.finishEnd()
            }
        }
        // Play once at the slowed rate (local asset → ready almost immediately).
        player.playImmediately(atRate: rate)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func finishEnd() {
        guard !ended else { return }
        ended = true
        onEnd()
    }

    func teardown() {
        player.pause()
        readyObservation?.invalidate()
        readyObservation = nil
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
        endObserver = nil
    }
}
