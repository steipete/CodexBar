import AdaptiveReplayKit
import Foundation
import Testing

struct AdaptiveRefreshTraceWriterTests {
    @Test
    func `writer stops at its byte limit without leaving a partial record`() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("adaptive-refresh-writer-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }

        let timestamp = Date(timeIntervalSince1970: 2_000_000_000)
        let record = AdaptiveRefreshTraceRecord.menuOpen(timestamp: timestamp)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let lineBytes = try encoder.encode(record).count + 1
        let writer = AdaptiveRefreshTraceWriter(
            fileURL: url,
            maxBytes: UInt64(lineBytes * 2))

        writer.append(record)
        writer.append(record)
        writer.append(record)
        _ = writer.currentURL() // Drain the writer queue before reading the file.

        let data = try Data(contentsOf: url)
        let records = try AdaptiveRefreshTraceParser.parse(contentsOf: url)
        #expect(data.count == lineBytes * 2)
        #expect(records == [record, record])
    }

    @Test
    func `writer skips a single record larger than its byte limit`() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("adaptive-refresh-writer-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = AdaptiveRefreshTraceWriter(fileURL: url, maxBytes: 1)

        writer.append(.menuOpen(timestamp: Date(timeIntervalSince1970: 2_000_000_000)))
        _ = writer.currentURL()

        #expect(!FileManager.default.fileExists(atPath: url.path))
    }
}
