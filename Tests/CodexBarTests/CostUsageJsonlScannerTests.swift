import Foundation
import Testing
@testable import CodexBarCore

@Suite
struct CostUsageJsonlScannerTests {
    @Test
    func jsonlScannerHandlesLinesAcrossReadChunks() throws {
        let root = try self.makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let fileURL = root.appendingPathComponent("large-lines.jsonl", isDirectory: false)
        let largeLine = String(repeating: "x", count: 300_000)
        let contents = "\(largeLine)\nsmall\n"
        try contents.write(to: fileURL, atomically: true, encoding: .utf8)

        var scanned: [(count: Int, truncated: Bool)] = []
        let endOffset = try CostUsageJsonl.scan(
            fileURL: fileURL,
            maxLineBytes: 400_000,
            prefixBytes: 400_000)
        { line in
            scanned.append((line.bytes.count, line.wasTruncated))
        }

        #expect(endOffset == Int64(Data(contents.utf8).count))
        #expect(scanned.count == 2)
        #expect(scanned[0].count == 300_000)
        #expect(scanned[0].truncated == false)
        #expect(scanned[1].count == 5)
        #expect(scanned[1].truncated == false)
    }

    @Test
    func jsonlScannerMarksPrefixLimitedLinesAsTruncated() throws {
        let root = try self.makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let fileURL = root.appendingPathComponent("truncated-lines.jsonl", isDirectory: false)
        let shortLine = "ok"
        let longLine = String(repeating: "a", count: 2000)
        let contents = "\(shortLine)\n\(longLine)\n"
        try contents.write(to: fileURL, atomically: true, encoding: .utf8)

        var scanned: [CostUsageJsonl.Line] = []
        _ = try CostUsageJsonl.scan(
            fileURL: fileURL,
            maxLineBytes: 10000,
            prefixBytes: 64)
        { line in
            scanned.append(line)
        }

        #expect(scanned.count == 2)
        #expect(String(data: scanned[0].bytes, encoding: .utf8) == "ok")
        #expect(scanned[0].wasTruncated == false)
        #expect(scanned[1].bytes.isEmpty)
        #expect(scanned[1].wasTruncated == true)
    }

    private func makeTemporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "codexbar-cost-usage-jsonl-\(UUID().uuidString)",
            isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}
