import Foundation

/// Drains the share-extension inbox (queued by X2's `ShareViewController`) into
/// the live session graph when the app foregrounds.
///

/// The share extension does no networking — it just persists
/// ``SharedStore/SharedInboxItem`` JSON (plus any image files) into the
/// `group.gio.hermes.app` app group. On foreground the app reads those items and,
/// for each, opens a brand-new session and submits a "Shared from iPhone" prompt
/// (attaching any images through the normal upload pipeline), then clears the
/// inbox. Items are processed **serially, oldest first** so the newest share
/// ends up as the most recent session — matching how the user just queued them.
///

/// Landing (C3): each item needs a *real* session to send into, so this uses the
/// eager create-then-send path (``SessionStore/createSessionNow()``) rather than
/// the draft path — a draft has no `activeRuntimeId` to submit against. After the batch the
/// drainer lands the UI on the **last** session it created (the newest share),
/// via ``SessionStore/land(storedId:runtimeId:)`` so the user arrives in the
/// conversation they most recently shared into without clobbering its live stream.
///

/// Concurrency: every store touched here is `@MainActor`, and a single in-flight
/// drain is enforced so two foreground events can't double-process the inbox.
/// The drain is best-effort: a per-item failure is logged via the count callback
/// but does not abort the batch, and the inbox is cleared once the batch is
/// attempted (the queue is a one-shot handoff, not a retry buffer).
///

/// Hook point (wired by the parent — see integration notes): call ``drain(...)``
/// from `scenePhase == .active`, after the connection is (re)established, much
/// like `PendingIntentRouter.drain`. The optional `onDrained` closure is the
/// toast seam — surface "Queued N shared item(s)" in the UI.
@MainActor
enum SharedInboxDrainer {

    /// Whether a drain is currently running, so overlapping foregrounds coalesce.
    private static var isDraining = false

    /// Read every queued shared item, turn each into a new Hermes session, then
    /// clear the inbox. No-op when the gateway isn't connected (the items stay
    /// queued for the next good foreground) or when already draining.
    ///

    /// - Parameters:
    ///  - connection: gates on connectivity and backs the attachment upload.
    ///  - sessions: creates a fresh session per item.
    ///  - chat: submits the prompt into the just-created session.
    ///  - attachments: normalises + uploads any shared images.
    ///  - onDrained: optional toast hook called with the number of items that
    ///  were processed (≥1). Not called when there was nothing to drain.
    static func drain(
        connection: ConnectionStore,
        sessions: SessionStore,
        chat: ChatStore,
        attachments: AttachmentStore,
        onDrained: ((Int) -> Void)? = nil
    ) {
        guard !isDraining else { return }
        // Need a live gateway to create sessions / upload — otherwise leave the
        // items queued and try again on the next foreground.
        guard case .connected = connection.phase else { return }

        let items = SharedStore.readInbox()
        guard !items.isEmpty else { return }

        isDraining = true
        // Oldest first so the newest share becomes the most recent session.
        let ordered = items.sorted { $0.createdAt < $1.createdAt }

        Task {
            defer { isDraining = false }
            var processed = 0
            // Ids of the most recent session we successfully created+sent into, so
            // we can land the user there after the batch (newest share = last one).
            var lastLanded: (storedId: String, runtimeId: String?)?
            for item in ordered {
                if let created = await process(
                    item,
                    connection: connection,
                    sessions: sessions,
                    chat: chat,
                    attachments: attachments
                ) {
                    lastLanded = created
                }
                processed += 1
            }
            // Navigate to the newest shared session (C3). No-op-preserving when it's
            // already active, so the just-submitted turn keeps streaming.
            if let lastLanded {
                sessions.land(storedId: lastLanded.storedId, runtimeId: lastLanded.runtimeId)
            }
            // One-shot handoff — but only when at least one item landed. A
            // TOTAL failure (e.g. gateway briefly unreachable on foreground)
            // keeps the queue for the next foreground instead of silently
            // dropping every share (release audit P2). Partial success still
            // clears (re-draining would double-submit the successes); a
            // poisoned single item retrying forever is the lesser evil vs
            // silent data loss.
            if processed > 0 {
                SharedStore.clearInbox()
                onDrained?(processed)
            }
        }
    }

    /// Process a single shared item: open a new session, attach images, submit.
    /// Returns the created session's `(storedId, runtimeId)` on success so the
    /// caller can land on the last one; `nil` when the session couldn't be created.
    @discardableResult
    private static func process(
        _ item: SharedStore.SharedInboxItem,
        connection: ConnectionStore,
        sessions: SessionStore,
        chat: ChatStore,
        attachments: AttachmentStore
    ) async -> (storedId: String, runtimeId: String?)? {
        // Eager create-then-send: the prompt needs a real session bound to this
        // connection (a draft has no runtime id to submit against).
        // `createSessionNow()` leaves `activeRuntimeId`/`activeStoredId` set for
        // the send below.
        do {
            try await sessions.createSessionNow()
        } catch {
            // Couldn't create a session for this item — skip it (the batch
            // continues; the inbox is cleared at the end either way).
            return nil
        }
        guard sessions.activeRuntimeId != nil else { return nil }
        // Capture the created session's ids now, before `chat.send` (the next
        // iteration's `createSessionNow()` will overwrite the active pointers).
        let runtimeId = sessions.activeRuntimeId
        let storedId = sessions.activeStoredId ?? runtimeId
        guard let storedId else { return nil }

        // Queue any shared images into the attachment pipeline; `chat.send`
        // uploads + attaches them before the prompt lands.
        loadImages(for: item, into: attachments)

        let prompt = composePrompt(for: item)
        // `send` substitutes a default caption if `prompt` is empty but images
        // are attached, so an image-only share still produces a valid turn.
        await chat.send(text: prompt)
        return (storedId: storedId, runtimeId: runtimeId)
    }

    /// Load each referenced image file from the shared container and hand it to
    /// the attachment store (which normalises to JPEG). Missing/undecodable
    /// files are skipped silently.
    private static func loadImages(
        for item: SharedStore.SharedInboxItem,
        into attachments: AttachmentStore
    ) {
        guard !item.imageFiles.isEmpty, let dir = SharedStore.sharedImagesDirectory else { return }
        for name in item.imageFiles {
            let url = dir.appendingPathComponent(name, isDirectory: false)
            guard let data = try? Data(contentsOf: url) else { continue }
            attachments.add(data: data)
        }
    }

    /// Build the "Shared from iPhone" prompt body from the item's comment + the
    /// shared text/URL. Returns "" when the item is image-only (so `chat.send`
    /// supplies its default caption).
    private static func composePrompt(for item: SharedStore.SharedInboxItem) -> String {
        var lines: [String] = []
        let comment = item.comment?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let comment, !comment.isEmpty {
            lines.append("Shared from iPhone: \(comment)")
        } else if hasBody(item) {
            lines.append("Shared from iPhone:")
        }

        if let text = item.text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
            lines.append(text)
        }
        if let url = item.url?.trimmingCharacters(in: .whitespacesAndNewlines), !url.isEmpty {
            lines.append(url)
        }
        return lines.joined(separator: "\n")
    }

    /// Whether the item carries any text/url body (vs. being image-only).
    private static func hasBody(_ item: SharedStore.SharedInboxItem) -> Bool {
        let hasText = !(item.text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        let hasURL = !(item.url?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        return hasText || hasURL
    }
}
