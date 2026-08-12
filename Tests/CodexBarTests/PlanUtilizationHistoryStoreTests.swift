import Foundation
import Testing
@testable import CodexBar

struct PlanUtilizationHistoryStoreTests {
    @Test
    func `identical provider history keeps the existing file`() throws {
        let fixture = Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directoryURL) }
        let buckets = Self.makeBuckets(usedPercent: 12)

        fixture.store.save([.codex: buckets])
        try FileManager.default.setAttributes(
            [.modificationDate: fixture.sentinelDate],
            ofItemAtPath: fixture.fileURL.path)
        let originalData = try Data(contentsOf: fixture.fileURL)

        fixture.store.save([.codex: buckets])

        #expect(try Data(contentsOf: fixture.fileURL) == originalData)
        #expect(try Self.modificationDate(of: fixture.fileURL) == fixture.sentinelDate)
    }

    @Test
    func `changed provider history replaces the existing file`() throws {
        let fixture = Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directoryURL) }

        fixture.store.save([.codex: Self.makeBuckets(usedPercent: 12)])
        try FileManager.default.setAttributes(
            [.modificationDate: fixture.sentinelDate],
            ofItemAtPath: fixture.fileURL.path)
        let originalData = try Data(contentsOf: fixture.fileURL)

        fixture.store.save([.codex: Self.makeBuckets(usedPercent: 34)])

        #expect(try Data(contentsOf: fixture.fileURL) != originalData)
        #expect(try Self.modificationDate(of: fixture.fileURL) != fixture.sentinelDate)
    }

    @Test
    func `empty provider history removes the existing file`() {
        let fixture = Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directoryURL) }

        fixture.store.save([.codex: Self.makeBuckets(usedPercent: 12)])
        #expect(FileManager.default.fileExists(atPath: fixture.fileURL.path))

        fixture.store.save([:])

        #expect(!FileManager.default.fileExists(atPath: fixture.fileURL.path))
    }

    private static func makeFixture() -> (
        directoryURL: URL,
        fileURL: URL,
        sentinelDate: Date,
        store: PlanUtilizationHistoryStore)
    {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("PlanUtilizationHistoryStoreTests-\(UUID().uuidString)", isDirectory: true)
        return (
            directoryURL: directoryURL,
            fileURL: directoryURL.appendingPathComponent("codex.json"),
            sentinelDate: Date(timeIntervalSince1970: 1_000_000_000),
            store: PlanUtilizationHistoryStore(directoryURL: directoryURL))
    }

    private static func makeBuckets(usedPercent: Double) -> PlanUtilizationHistoryBuckets {
        PlanUtilizationHistoryBuckets(unscoped: [
            PlanUtilizationSeriesHistory(
                name: .session,
                windowMinutes: 300,
                entries: [
                    PlanUtilizationHistoryEntry(
                        capturedAt: Date(timeIntervalSince1970: 1_700_000_000),
                        usedPercent: usedPercent,
                        resetsAt: nil),
                ]),
        ])
    }

    private static func modificationDate(of fileURL: URL) throws -> Date {
        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        return try #require(attributes[.modificationDate] as? Date)
    }
}
