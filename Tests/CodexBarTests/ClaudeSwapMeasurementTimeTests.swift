import Foundation
import Testing
@testable import CodexBarCore

struct ClaudeSwapMeasurementTimeTests {
    private let now = Date(timeIntervalSince1970: 1_788_777_000)

    @Test
    func `cached measurements keep the source time across refreshes`() throws {
        let list = try self.list(fetchedAt: "2026-09-07T08:54:23.123456+00:00")
        let expected = try #require(ISO8601DateFormatter().date(from: "2026-09-07T08:54:23Z"))
        let first = try #require(ClaudeSwapAccountProjection.accountSnapshots(from: list, now: self.now).first)
        let later = try #require(ClaudeSwapAccountProjection.accountSnapshots(
            from: list,
            previousAccounts: [first],
            now: self.now.addingTimeInterval(300)).first)

        for account in [first, later] {
            let snapshot = try #require(account.snapshot)
            #expect(abs(snapshot.updatedAt.timeIntervalSince(expected) - 0.123456) < 0.001)
            #expect(snapshot.primary?.usedPercent == 100)
            #expect(account.id.opaqueID == "1")
        }

        let unavailable = try self.list(fetchedAt: nil, usageStatus: "unavailable", hasUsage: false)
        let retained = try #require(ClaudeSwapAccountProjection.accountSnapshots(
            from: unavailable,
            previousAccounts: [later],
            now: self.now.addingTimeInterval(600)).first)
        #expect(retained.snapshot?.updatedAt == first.snapshot?.updatedAt)
    }

    @Test
    func `missing or malformed optional timestamps preserve valid usage`() throws {
        for fetchedAt in [nil, "not-a-timestamp", 42, true] as [Any?] {
            let list = try self.list(fetchedAt: fetchedAt)
            let account = try #require(ClaudeSwapAccountProjection.accountSnapshots(from: list, now: self.now).first)
            #expect(account.snapshot?.updatedAt == self.now)
            #expect(account.snapshot?.primary?.usedPercent == 100)
            #expect(account.error == nil)
        }
    }

    private func list(
        fetchedAt: Any?,
        usageStatus: String = "ok",
        hasUsage: Bool = true) throws -> ClaudeSwapAccountList
    {
        var row: [String: Any] = [
            "number": 1,
            "active": true,
            "email": "fixture@example.invalid",
            "usageStatus": usageStatus,
        ]
        row["usageFetchedAt"] = fetchedAt
        if hasUsage {
            row["usage"] = ["fiveHour": ["pct": 100, "resetsAt": "2026-09-08T12:00:00Z"]]
        }
        return try ClaudeSwapListParser.parse(JSONSerialization.data(withJSONObject: [
            "schemaVersion": 1,
            "activeAccountNumber": 1,
            "accounts": [row],
        ]))
    }
}
