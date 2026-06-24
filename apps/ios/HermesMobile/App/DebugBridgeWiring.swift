// gstack debug bridge wiring (task UI-G).
//

// This entire file is #if DEBUG-gated and depends on the DebugBridge SPM
// package, which the HermesMobile target links only in Debug config
// (`.when(configuration: .debug)` in project.yml). In a Release build this
// file compiles to nothing and the bridge symbols are absent — verified by the
// release-purity check (nm/strings show no StateServer/DebugBridge symbols).
//

// To remove the bridge entirely, follow the ios-clean skill procedure
// (summarized at the bottom of this file).

#if DEBUG
import Foundation
import DebugBridgeCore
#if canImport(UIKit)
import DebugBridgeUI
#endif

@MainActor
func startGstackDebugBridge(environment: AppEnvironment) {
    // Recording mode draws the on-device "AGENT DEMO" watermark; opt in via
    // the launch argument the daemon passes for screencasts. (Only consumed by
    // the DebugOverlay install below, which is disabled locally — un-comment
    // both lines together to restore.)
    // let recording = ProcessInfo.processInfo.arguments.contains("--gstack-recording")

    // Install the UIKit-backed bridges (screenshot / elements / mutation) and
    // the DebugOverlay before the server starts, so the first authenticated
    // request can use them.
    //
    // DISABLED locally: `installAll` also installs the on-device DebugOverlay —
    // the animated rotating brand border + attribution chip — which is just a
    // QA presence indicator and is distracting during manual UI work. Skipping
    // the call removes it for EVERY launch method (Xcode Run, tap-to-open,
    // local install), unlike the HERMES_NO_DEBUG_OVERLAY env var which only
    // applies when Xcode launches the process. To restore the overlay + the
    // screenshot/element/mutation bridges (e.g. for gstack QA automation),
    // un-comment the call below.
    #if canImport(UIKit)
    // DebugBridgeUIWiring.installAll(recording: recording)
    #endif

    // Boot StateServer (loopback-only) and register the generated read
    // accessors for our @Observable stores. The …Accessor enums are emitted by
    // the gen-accessors tool into HermesMobile/DebugBridgeGenerated/.
    DebugBridgeManager.shared.start {
        ConnectionStoreAccessor.register(environment.connectionStore)
        ChatStoreAccessor.register(environment.chatStore)
        SessionStoreAccessor.register(environment.sessionStore)
        InboxStoreAccessor.register(environment.inboxStore)
    }
}
#endif

// MARK: - Removal (ios-clean procedure)
//

// The DebugBridge is removable with no trace via the /ios-clean skill, which
// expects exactly these steps:
//

// 1. Delete this file (HermesMobile/App/DebugBridgeWiring.swift) and the
//  `startGstackDebugBridge(environment:)` call site in HermesMobileApp.swift
//  (the `#if DEBUG startGstackDebugBridge(...) #endif` block in `.task`).
// 2. Remove every `#if DEBUG @Snapshotable #endif` marker (and the
//  `#if DEBUG import DebugBridgeCore #endif` line) from the stores:
//  ConnectionStore (phaseLabel, serverURLString), ChatStore (isStreaming,
//  lastError, activeToolName), SessionStore (activeStoredId, isLoading),
//  InboxStore (pendingCount). `grep -rn "@Snapshotable\|DebugBridge" HermesMobile`
//  must return nothing afterward.
// 3. Delete the generated directory: HermesMobile/DebugBridgeGenerated/.
// 4. Delete the SPM package directory: DebugBridge/.
// 5. Remove the `packages:` DebugBridge entry and the
//  `package: DebugBridge, product: DebugBridgeUI` dependency (gated
//  `.when(configuration: .debug)`) from project.yml, then re-run `xcodegen`.
// 6. Verify: a Release build links and `nm`/`strings` on the binary show no
//  StateServer / DebugBridge symbols.
