import Foundation

/// Conventions for data shared between the app and its extensions through
/// the `group.gio.hermes.app` app group: widget snapshots and the share-sheet
/// inbox. Extensions and app compile this same file into their targets.
enum SharedStore {
    static let appGroupID = "group.gio.hermes.app"

    static var defaults: UserDefaults? {
        UserDefaults(suiteName: appGroupID)
    }

    static var containerURL: URL? {
        FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupID
        )
    }

    // MARK: - Widget snapshot

    /// Snapshot the app writes and widgets read. Keep flat + Codable-stable.
    struct WidgetSnapshot: Codable, Sendable {
        var connected: Bool
        var activeSessions: Int
        var pendingApprovals: Int
        var tokensToday: Int?
        var costTodayUSD: Double?
        var updatedAt: Date
    }

    private static let snapshotKey = "hermes.widgetSnapshot"

    static func writeSnapshot(_ snapshot: WidgetSnapshot) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        defaults?.set(data, forKey: snapshotKey)
    }

    static func readSnapshot() -> WidgetSnapshot? {
        guard let data = defaults?.data(forKey: snapshotKey) else { return nil }
        return try? JSONDecoder().decode(WidgetSnapshot.self, from: data)
    }

    // MARK: - Share-sheet inbox

    /// One item queued by the share extension for the app to drain.
    struct SharedInboxItem: Codable, Identifiable, Sendable {
        var id: UUID
        var text: String?
        var url: String?
        var comment: String?
        /// Filenames (relative to `sharedImagesDirectory`) of attached images.
        var imageFiles: [String]
        var createdAt: Date
    }

    private static let inboxKey = "hermes.sharedInbox"

    static var sharedImagesDirectory: URL? {
        guard let base = containerURL else { return nil }
        let dir = base.appendingPathComponent("SharedImages", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func readInbox() -> [SharedInboxItem] {
        guard let data = defaults?.data(forKey: inboxKey) else { return [] }
        return (try? JSONDecoder().decode([SharedInboxItem].self, from: data)) ?? []
    }

    static func appendInboxItem(_ item: SharedInboxItem) {
        var items = readInbox()
        items.append(item)
        if let data = try? JSONEncoder().encode(items) {
            defaults?.set(data, forKey: inboxKey)
        }
    }

    static func clearInbox() {
        defaults?.removeObject(forKey: inboxKey)
        if let dir = sharedImagesDirectory {
            try? FileManager.default.removeItem(at: dir)
        }
    }
}
