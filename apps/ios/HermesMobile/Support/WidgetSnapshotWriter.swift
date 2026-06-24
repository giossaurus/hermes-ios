import Foundation
#if canImport(WidgetKit)
import WidgetKit
#endif

/// Writes the home-screen widgets' data snapshot into the shared app group and
/// asks WidgetKit to refresh.
///

/// The widgets (X1: `StatusWidget`, `UsageWidget`) read ``SharedStore/WidgetSnapshot``
/// JSON from `group.gio.hermes.app`; this is the only writer of that key. The
/// snapshot is assembled from values the caller already has on hand — there is no
/// networking here — so the app stays the single source of truth and the widget
/// extension never needs gateway access.
///

/// All entry points are `@MainActor`: they're driven from the app's observable
/// stores, and `WidgetCenter.reloadAllTimelines()` is cheap and main-safe. Writes
/// are debounced-by-equality: an identical snapshot (ignoring `updatedAt`) is not
/// re-written, so high-frequency store mutations don't thrash WidgetKit reloads.
///

/// Hook points (the parent wires these; see integration notes):
/// - `ConnectionStore.phase` changes → `connected` / `activeSessions`
/// - `InboxStore.pendingCount` changes → `pendingApprovals`
/// - `SessionStore.sessions` changes → `activeSessions`
/// - a usage fetch on foreground → `tokensToday` / `costTodayUSD`
@MainActor
enum WidgetSnapshotWriter {

    /// Last snapshot we wrote, used to skip no-op rewrites. Compared on the
    /// meaningful fields only (`updatedAt` always differs, so it's excluded).
    private static var lastWritten: SharedStore.WidgetSnapshot?

    /// Assemble a snapshot from the given inputs and publish it to the widgets.
    ///

    /// `updatedAt` is stamped here (`Date()`), so callers pass only the live
    /// values. Usage figures are optional — pass `nil` to leave whatever the last
    /// usage fetch published in place (see ``update(tokensToday:costTodayUSD:)``).
    ///

    /// - Parameters:
    ///  - connected: whether the gateway WebSocket is currently established.
    ///  - activeSessions: count of live sessions (server-reported or local).
    ///  - pendingApprovals: number of approval/clarify prompts awaiting the user.
    ///  - tokensToday: today's token total, if a usage fetch has resolved.
    ///  - costTodayUSD: today's estimated cost in USD, if available.
    static func write(
        connected: Bool,
        activeSessions: Int,
        pendingApprovals: Int,
        tokensToday: Int? = nil,
        costTodayUSD: Double? = nil
    ) {
        // Preserve previously-published usage when this caller didn't supply it
        // (e.g. a connection-phase change shouldn't blank the token counts).
        let resolvedTokens = tokensToday ?? lastWritten?.tokensToday
        let resolvedCost = costTodayUSD ?? lastWritten?.costTodayUSD

        let snapshot = SharedStore.WidgetSnapshot(
            connected: connected,
            activeSessions: max(0, activeSessions),
            pendingApprovals: max(0, pendingApprovals),
            tokensToday: resolvedTokens,
            costTodayUSD: resolvedCost,
            updatedAt: Date()
        )

        guard hasMeaningfulChange(from: lastWritten, to: snapshot) else { return }
        lastWritten = snapshot
        SharedStore.writeSnapshot(snapshot)
        reloadWidgets()
    }

    /// Update only the usage figures, carrying the rest of the last snapshot
    /// forward. Convenience for the foreground usage fetch hook, which knows
    /// nothing about connection/session/approval state.
    ///

    /// If nothing has been written yet, seeds a disconnected baseline so the
    /// usage values aren't dropped on the floor.
    static func update(tokensToday: Int?, costTodayUSD: Double?) {
        let base = lastWritten
        write(
            connected: base?.connected ?? false,
            activeSessions: base?.activeSessions ?? 0,
            pendingApprovals: base?.pendingApprovals ?? 0,
            tokensToday: tokensToday,
            costTodayUSD: costTodayUSD
        )
    }

    /// True when any user-visible field differs (ignoring `updatedAt`), so we
    /// only touch WidgetKit when the widgets would actually render differently.
    private static func hasMeaningfulChange(
        from old: SharedStore.WidgetSnapshot?,
        to new: SharedStore.WidgetSnapshot
    ) -> Bool {
        guard let old else { return true }
        return old.connected != new.connected
            || old.activeSessions != new.activeSessions
            || old.pendingApprovals != new.pendingApprovals
            || old.tokensToday != new.tokensToday
            || old.costTodayUSD != new.costTodayUSD
    }

    private static func reloadWidgets() {
        #if canImport(WidgetKit)
        WidgetCenter.shared.reloadAllTimelines()
        #endif
    }
}
