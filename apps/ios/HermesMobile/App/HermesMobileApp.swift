import CoreSpotlight
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

@main
struct HermesMobileApp: App {
    @State private var environment = AppEnvironment()
    /// Carries a deferred `hermesapp://pair` payload from `onOpenURL` up to the
    /// confirmation UI in `RootView` (re-pairing while connected is destructive).
    @State private var deepLink = DeepLinkCoordinator()
    /// In-app UI language (pt-BR / English / system). Owned at the app root so the
    /// chosen `\.locale` propagates to the whole tree and `Text`/`String(localized:)`
    /// re-resolve live when the user switches language in Settings.
    @State private var localization = LocalizationManager()
    /// Cold-launch brand splash gate. `@State` is fresh per process, so this is
    /// `true` only on a genuine cold launch — a warm foreground resume keeps the
    /// already-dismissed value, so the splash never replays on resume.
    @State private var showSplash = true
    @Environment(\.scenePhase) private var scenePhase
    /// APNs token callbacks only reach a `UIApplicationDelegate`; this adaptor
    /// forwards them to `PushRegistrar` (see ``AppDelegate``).
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        Self.installTransparentNavigationBarAppearance()
    }

    /// Force a fully transparent navigation-bar appearance app-wide. This is the
    /// root cause of the user's top "white strip": on iOS 26 the SwiftUI
    /// `.toolbarBackground(.hidden)` / `.toolbarBackgroundVisibility(.hidden)`
    /// modifiers are silently overridden by the system's automatic opaque
    /// scroll-edge nav-bar appearance the moment transcript content scrolls under
    /// the bar — UINavigationBar falls back to `scrollEdgeAppearance`/
    /// `standardAppearance`, both of which default to an OPAQUE system-background
    /// fill (the white band the user sees from the status bar through the toolbar).
    /// Configuring BOTH appearances with a transparent background + clear shadow
    /// at the UIKit proxy level is the only treatment that holds on 26, so the
    /// full-bleed `theme.bg` chat canvas painted behind the bar shows through and
    /// the toolbar items float as bare glass over it. The compact chat is the only
    /// surface that wants a transparent bar; the iPad split detail re-asserts its
    /// own themed opaque bar via the SwiftUI `.toolbarBackground(.visible)` path
    /// in `applyingChatToolbarBackground`, which overrides this proxy default on
    /// that surface only.
    #if canImport(UIKit)
    @MainActor
    private static func installTransparentNavigationBarAppearance() {
        let appearance = UINavigationBarAppearance()
        appearance.configureWithTransparentBackground()
        appearance.backgroundColor = .clear
        appearance.backgroundEffect = nil
        appearance.shadowColor = .clear
        appearance.shadowImage = UIImage()
        let proxy = UINavigationBar.appearance()
        proxy.standardAppearance = appearance
        proxy.compactAppearance = appearance
        proxy.scrollEdgeAppearance = appearance
        proxy.compactScrollEdgeAppearance = appearance
    }
    #else
    private static func installTransparentNavigationBarAppearance() {}
    #endif

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(environment.connectionStore)
                .environment(environment.sessionStore)
                .environment(environment.chatStore)
                .environment(environment.attachmentStore)
                .environment(environment.queueStore)
                .environment(environment.voiceRecorder)
                .environment(environment.speechPlayer)
                .environment(environment.inboxStore)
                .environment(environment.appLock)
                .environment(environment.themeStore)
                // The deep-link pair-confirmation coordinator (L11). Owned at the
                // app root, observed by RootView to present the destructive-repair
                // confirmation. Not part of AppEnvironment — it is a view-layer
                // concern with no store dependencies.
                .environment(deepLink)
                // Install the resolved palette (\.hermesTheme), the global brand
                // tint, and the forced color scheme at the app root in one shot.
                // Sheet/NavigationStack roots must re-apply `.hermesThemed(store)`
                // because SwiftUI does not reliably inherit custom environment
                // values across presentation boundaries.
                .hermesThemed(environment.themeStore)
                // In-app UI language. Injected OUTSIDE `.hermesThemed` ON PURPOSE:
                // that modifier re-applies `\.locale` at EVERY root (app + sheets)
                // by reading this manager, and — being a ViewModifier — re-renders
                // reactively when the user switches language, with no app restart.
                // If injected inside, the app-root `hermesThemed` would read nil
                // and pin the system language (only sheets, which inherit it via
                // presentation, would switch). The previous explicit
                // `.environment(\.locale, …)` is gone: read in the App's Scene
                // body it was pinned to the launch locale (Scene bodies do not
                // re-evaluate on @State change), which then overrode the live one.
                .environment(localization)
                // Cold-launch brand splash, above the whole UI (RootView forks
                // its phase switch immediately, so the splash must sit over it).
                // The bootstrap `.task` below keeps running underneath, so the
                // ~2.8s clip overlaps connection setup for free.
                .overlay {
                    if showSplash {
                        // SplashView crossfades ITSELF out (incl. the AVPlayerLayer)
                        // before calling back, so the overlay is already invisible
                        // here — just remove it, no extra animation/transition.
                        SplashView(onFinish: { showSplash = false })
                    }
                }
                .task {
                    #if DEBUG
                    // DEBUG-only main-thread hitch logger (HERMES_PERF_LOG=1). Cheap,
                    // allocation-free in steady state; durable measurement tooling.
                    // Started FIRST so it captures the seed/stream window too.
                    if PerfHitchLogger.isEnabled {
                        PerfHitchLogger.shared.start()
                    }
                    // DEBUG-only deterministic seed: when HERMES_UITEST_SEED is set,
                    // bypass the network bootstrap AND the debug overlay/badge so
                    // seeded captures (demo footage) are clean.
                    if let seed = UITestSeed.requestedMode {
                        UITestSeed.apply(seed, environment: environment)
                        // MEASUREMENT MODE: when BOTH the seed AND the debug bridge are
                        // requested (HERMES_DEBUG_BRIDGE=1), start the bridge anyway so a
                        // harness can drive scrolls (/swipe → setContentOffset) against
                        // the seeded transcript. The on-device badge/overlay is fine
                        // during measurement (it is not a demo capture). Clean seeded
                        // captures simply omit HERMES_DEBUG_BRIDGE.
                        if ProcessInfo.processInfo.environment["HERMES_DEBUG_BRIDGE"] == "1" {
                            startGstackDebugBridge(environment: environment)
                        }
                        return
                    }
                    // gstack debug bridge (task UI-G): loopback-only StateServer
                    // + typed store accessors. DEBUG-only; absent in Release.
                    startGstackDebugBridge(environment: environment)
                    #endif
                    environment.appLock.authenticateAtLaunch()
                    // Route notification taps (local + remote APNs) into the store
                    // graph. Registered before bootstrap so a cold-launch tap —
                    // which iOS delivers right after launch — is honored once the
                    // session list is refreshed inside the router.
                    NotificationService.setTapHandler { tap in
                        HermesURLRouter.routePushTap(
                            tap,
                            sessions: environment.sessionStore,
                            inbox: environment.inboxStore
                        )
                    }
                    // Wire the notification-action backend (A2): APPROVE / DENY on
                    // a HERMES_APPROVAL push resolves against the gateway via this
                    // resolved endpoint (same loopback URL + Keychain token as the
                    // push registrar). `nil` when unconfigured → the action falls
                    // back to a feedback notification.
                    NotificationService.setActionEndpointProvider {
                        PushRegistrar.shared.resolveEndpoint().map {
                            NotificationService.ActionEndpoint(
                                baseURL: $0.url, token: $0.token, pathStyle: $0.pathStyle
                            )
                        }
                    }
                    await environment.connectionStore.bootstrap()
                    // Push is opt-in; this no-ops unless the user enabled it.
                    PushRegistrar.shared.enableIfAllowed()
                    // First-launch usage figures for the widgets, once connected.
                    environment.refreshUsageSnapshot()
                }
                .onChange(of: scenePhase) { _, newPhase in
                    environment.connectionStore.handleScenePhase(newPhase)
                    environment.appLock.handleScenePhase(newPhase)
                    // UX1: start/stop the 30-second foreground heartbeat so the
                    // session list refreshes without user interaction in the foreground.
                    environment.sessionStore.handleScenePhaseActive(newPhase == .active)
                    // On foreground: apply parked App Intents, drain the share
                    // inbox, and refresh the widgets' usage figures.
                    if newPhase == .active {
                        PendingIntentRouter.drain(
                            connection: environment.connectionStore,
                            sessions: environment.sessionStore,
                            chat: environment.chatStore
                        )
                        SharedInboxDrainer.drain(
                            connection: environment.connectionStore,
                            sessions: environment.sessionStore,
                            chat: environment.chatStore,
                            attachments: environment.attachmentStore
                        )
                        environment.refreshUsageSnapshot()
                    }
                }
                .onOpenURL { url in
                    HermesURLRouter.route(
                        url,
                        connection: environment.connectionStore,
                        sessions: environment.sessionStore,
                        chat: environment.chatStore,
                        inbox: environment.inboxStore,
                        // Re-pairing over a live/saved connection is destructive;
                        // stash the payload and let RootView confirm before the
                        // disconnect-and-repair (an unconfigured app pairs directly
                        // inside `route`, never reaching this seam).
                        requestPairConfirmation: { payload in
                            deepLink.requestPairConfirmation(payload)
                        }
                    )
                }
                // P0 SPOTLIGHT / HANDOFF RECEIVER (L11): SpotlightIndexer mints
                // both the open-session Handoff activity AND Spotlight items, and
                // Info.plist registers the activity type — but nothing received the
                // continuation, so Handoff arrivals and Spotlight taps no-oped.
                // Receive BOTH the open-session activity (Handoff from a peer / the
                // app's own advertised activity) AND CSSearchableItemActionType (a
                // tapped Spotlight result) here at the scene root, routing each to
                // the same stored-id resolution (+ inbox fallback) as the
                // `session/<id>` deep link. iOS replays the launch activity right
                // after the scene connects, so a cold-launch tap is honored once
                // the router's refresh resolves the (possibly empty) list.
                .onContinueUserActivity(SpotlightIndexer.openSessionActivityType) { activity in
                    HermesURLRouter.routeContinuedActivity(
                        activity,
                        sessions: environment.sessionStore,
                        inbox: environment.inboxStore
                    )
                }
                .onContinueUserActivity(CSSearchableItemActionType) { activity in
                    HermesURLRouter.routeContinuedActivity(
                        activity,
                        sessions: environment.sessionStore,
                        inbox: environment.inboxStore
                    )
                }
        }
    }
}

#if canImport(UIKit)
/// App delegate adaptor whose sole job is forwarding the APNs device-token
/// callbacks (which only fire on a `UIApplicationDelegate`) to ``PushRegistrar``.
/// `PushRegistrar` is `@MainActor`; these UIKit callbacks land on the main
/// thread, so `MainActor.assumeIsolated` is safe and avoids a hop.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        MainActor.assumeIsolated {
            PushRegistrar.shared.didRegister(deviceToken: deviceToken)
        }
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        MainActor.assumeIsolated {
            PushRegistrar.shared.didFailToRegister(error: error)
        }
    }
}
#endif
