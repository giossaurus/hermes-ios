import XCTest
@testable import HermesMobile

/// Catch-up recovery of server-side pending approvals/clarifies
/// (`GET /approvals/pending`): the iOS half of the fix that makes a
/// background-suspend a non-event for pending approvals. Fixtures mirror the
/// real stored-record shape from the server's `approvals_pending.jsonl`
/// (`op`/`approval_id`/`kind`/`session_id`/… — extra keys ignored).
@MainActor
final class PendingApprovalsCatchUpTests: XCTestCase {

    private let runtime = "20260624_122652_cee89c"
    private let stored = "agent:main:telegram:dm:6390066869"

    // MARK: - PendingPrompt tolerant decode

    /// A full approval record decodes, keys identity off `approval_id`, and feeds
    /// the shared ``ApprovalRequestPayload`` parser (title/command surface).
    func testApprovalRecordDecodes() throws {
        let record: JSONValue = [
            "op": "add",                       // ignored
            "approval_id": "e9ced55d1a8f",
            "kind": "approval",
            "session_id": .string(runtime),
            "session_key": .string(stored),
            "stored_session_id": .string(stored),
            "title": "Approval required",
            "description": "rm -rf /tmp/x",
            "command": "rm -rf /tmp/x",
            "pattern_key": "fs.rm",
            "destructive": true,
            "question": .null,
            "created_at": 1782312345.67,
            "ttl": 300,
            "origin_pid": 3463265,             // ignored
        ]
        let prompt = try XCTUnwrap(PendingPrompt(record: record))
        XCTAssertEqual(prompt.kind, .approval)
        XCTAssertEqual(prompt.id, "e9ced55d1a8f")
        XCTAssertEqual(prompt.sessionId, runtime)
        XCTAssertEqual(prompt.storedSessionId, stored)
        XCTAssertEqual(prompt.ttl, 300)

        // The injected `id` lets the existing parser key off approval_id.
        let payload = ApprovalRequestPayload(payload: prompt.payload)
        XCTAssertEqual(payload.id, "e9ced55d1a8f")
        XCTAssertEqual(payload.command, "rm -rf /tmp/x")
    }

    /// A clarify record decodes and feeds the shared ``ClarifyRequestPayload``.
    func testClarifyRecordDecodes() throws {
        let record: JSONValue = [
            "op": "add",
            "approval_id": "cf40e363320a",
            "kind": "clarify",
            "session_id": .string(runtime),
            "stored_session_id": .string(stored),
            "title": "Hermes has a question",
            "question": "which env?",
        ]
        let prompt = try XCTUnwrap(PendingPrompt(record: record))
        XCTAssertEqual(prompt.kind, .clarify)
        let payload = ClarifyRequestPayload(payload: prompt.payload)
        XCTAssertEqual(payload.question, "which env?")
    }

    /// Missing/garbage required fields are skipped (nil), never fatal.
    func testMalformedRecordsAreSkipped() {
        let missingId: JSONValue = ["kind": "approval", "session_id": .string(runtime)]
        let missingSession: JSONValue = ["kind": "approval", "approval_id": "x"]
        let badKind: JSONValue = [
            "kind": "wat", "approval_id": "x", "session_id": .string(runtime),
        ]
        XCTAssertNil(PendingPrompt(record: missingId))
        XCTAssertNil(PendingPrompt(record: missingSession))
        XCTAssertNil(PendingPrompt(record: badKind))
    }

    // MARK: - InboxStore.catchUp

    private func approvalPrompt(id: String, createdAt: Double? = nil, ttl: Int? = nil) -> PendingPrompt {
        var record: [String: JSONValue] = [
            "approval_id": .string(id),
            "kind": "approval",
            "session_id": .string(runtime),
            "stored_session_id": .string(stored),
            "command": "rm -rf /tmp/x",
        ]
        if let createdAt { record["created_at"] = .number(createdAt) }
        if let ttl { record["ttl"] = .number(Double(ttl)) }
        return PendingPrompt(record: .object(record))!
    }

    func testCatchUpAddsPendingItems() {
        let inbox = InboxStore()
        inbox.catchUp([approvalPrompt(id: "a1"), approvalPrompt(id: "a2")])
        XCTAssertEqual(inbox.pendingCount, 2)
        XCTAssertEqual(Set(inbox.pendingItems.map(\.id)), ["a1", "a2"])
    }

    /// A recovered prompt dedups against one already received live over the WS.
    func testCatchUpDedupesAgainstLiveItem() throws {
        let inbox = InboxStore()
        let live = try XCTUnwrap(GatewayEvent(params: .object([
            "type": .string("approval.request"),
            "session_id": .string(runtime),
            "payload": .object(["id": .string("a1"), "command": .string("live")]),
        ])))
        inbox.handle(event: live)
        XCTAssertEqual(inbox.pendingCount, 1)

        inbox.catchUp([approvalPrompt(id: "a1")])
        XCTAssertEqual(inbox.pendingCount, 1, "same approval_id must not duplicate")
    }

    /// An answered/dismissed id is not resurrected by a later catch-up (the
    /// server still holds the record until ttl).
    func testCatchUpSkipsAnsweredIds() {
        let inbox = InboxStore()
        inbox.catchUp([approvalPrompt(id: "a1")])
        let item = inbox.pendingItems.first!
        inbox.dismiss(item)
        XCTAssertEqual(inbox.pendingCount, 0)

        inbox.catchUp([approvalPrompt(id: "a1")])
        XCTAssertEqual(inbox.pendingCount, 0, "dismissed id must stay cleared")
    }

    /// A record past `created_at + ttl` lands expired, not pending.
    func testCatchUpMarksStaleRecordExpired() {
        let inbox = InboxStore()
        inbox.catchUp([approvalPrompt(id: "old", createdAt: 1.0, ttl: 300)])
        XCTAssertEqual(inbox.pendingCount, 0)
        XCTAssertEqual(inbox.items.first?.state, .expired)
    }

    /// Catch-up clarifies key off `clarify:<session>`, matching the live path.
    func testCatchUpClarifyKeyedBySession() {
        let inbox = InboxStore()
        let record: JSONValue = [
            "approval_id": "cf40e363320a",
            "kind": "clarify",
            "session_id": .string(runtime),
            "question": "which env?",
        ]
        inbox.catchUp([PendingPrompt(record: record)!])
        XCTAssertEqual(inbox.pendingItems.first?.id, "clarify:\(runtime)")
    }
}
