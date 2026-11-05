import Foundation
import Testing
@testable import CodexBarCore

struct QuotaFeedPublicationTests {
    private let now = Date(timeIntervalSince1970: 1_767_268_800)

    @Test(arguments: [false, true])
    func `publication clears a removed reset after atomic feed replacement`(explicitNull: Bool) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("quota.json")
        let reader = QuotaFeedReader()
        let initialReset = self.now.addingTimeInterval(3600)
        try self.feed(reset: initialReset).write(to: file, options: .atomic)
        let previous = try reader.fetch(path: file.path, now: self.now)
            .backfillingResetTimesForProvider(.quotafeed, from: nil, now: self.now)
        #expect(previous.primary?.resetsAt == initialReset)

        let refreshedAt = self.now.addingTimeInterval(60)
        try self.feed(used: 30, observedAt: refreshedAt, explicitNull: explicitNull)
            .write(to: file, options: .atomic)
        let current = try reader.fetch(path: file.path, now: refreshedAt)
        // Ensure this fixture would revive the future date under the old publication behavior.
        #expect(current.backfillingResetTimes(from: previous, now: refreshedAt).primary?.resetsAt == initialReset)
        let published = current.backfillingResetTimesForProvider(.quotafeed, from: previous, now: refreshedAt)
        #expect(published.primary?.resetsAt == nil)
        #expect(published.primary?.resetDescription == nil)
        #expect(published.primary?.windowMinutes == nil)
        #expect(published.primary?.usedPercent == 30)
        #expect(published.updatedAt == refreshedAt)
        #expect(published.details[0].rows.last?.value == "70.00")

        // A later explicit reset must still be published, even with an older reset in cache.
        let nextReset = initialReset.addingTimeInterval(3600)
        try self.feed(used: 35, observedAt: refreshedAt, reset: nextReset).write(to: file, options: .atomic)
        let next = try reader.fetch(path: file.path, now: refreshedAt)
            .backfillingResetTimesForProvider(.quotafeed, from: previous, now: refreshedAt)
        #expect(next.primary?.resetsAt == nextReset)
        #expect(next.primary?.usedPercent == 35)
    }

    @Test
    func `other providers retain their existing reset publication policies`() throws {
        let reset = self.now.addingTimeInterval(3600)
        let previous = try QuotaFeedSnapshot.decode(self.feed(reset: reset), now: self.now).usageSnapshot()
        let current = try QuotaFeedSnapshot.decode(self.feed(), now: self.now).usageSnapshot()
        #expect(current.backfillingResetTimesForProvider(.codex, from: previous, now: self.now)
            .primary?.resetsAt == reset)
        #expect(current.backfillingResetTimesForProvider(.langdock, from: previous, now: self.now)
            .primary?.resetsAt == nil)
    }

    @Test
    func `zero allocation does not restore a cached quota window or reset`() throws {
        let previous = try QuotaFeedSnapshot.decode(
            self.feed(reset: self.now.addingTimeInterval(3600)), now: self.now).usageSnapshot()
        let current = try QuotaFeedSnapshot.decode(self.feed(limit: 0), now: self.now).usageSnapshot()
            .backfillingResetTimesForProvider(.quotafeed, from: previous, now: self.now)
        #expect(current.primary == nil)
    }

    private func feed(
        used: Double = 25,
        limit: Double = 100,
        observedAt: Date? = nil,
        reset: Date? = nil,
        explicitNull: Bool = false) throws -> Data
    {
        let formatter = ISO8601DateFormatter()
        var object: [String: Any] = [
            "version": 1, "observedAt": formatter.string(from: observedAt ?? self.now),
            "used": used, "limit": limit,
        ]
        if let reset {
            object["resetsAt"] = formatter.string(from: reset)
        } else if explicitNull {
            object["resetsAt"] = NSNull()
        }
        return try JSONSerialization.data(withJSONObject: object)
    }
}
