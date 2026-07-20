import Foundation
import Testing
@testable import CodexBarCore

struct CostUsageJsonlScannerTests {
    @Test
    func `jsonl scanner handles lines across read chunks`() throws {
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
    func `jsonl scanner retains prefix for truncated lines`() throws {
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
        #expect(scanned[1].bytes.count == 64)
        #expect(String(data: scanned[1].bytes, encoding: .utf8) == String(repeating: "a", count: 64))
        #expect(scanned[1].wasTruncated == true)
    }

    @Test
    func `jsonl scanner retries an incomplete final record after append`() throws {
        let root = try self.makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let fileURL = root.appendingPathComponent("appending.jsonl", isDirectory: false)
        let initial = #"{"type":"message","id":"partial"#
        try initial.write(to: fileURL, atomically: true, encoding: .utf8)

        var firstPass: [String?] = []
        let resumeOffset = try CostUsageJsonl.scan(
            fileURL: fileURL,
            maxLineBytes: 1024,
            prefixBytes: 1024)
        { line in
            firstPass.append(String(bytes: line.bytes, encoding: .utf8))
        }

        #expect(firstPass.isEmpty)
        #expect(resumeOffset == 0)

        let completion = #""}"# + "\n"
        let handle = try FileHandle(forWritingTo: fileURL)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(completion.utf8))

        var secondPass: [String?] = []
        let endOffset = try CostUsageJsonl.scan(
            fileURL: fileURL,
            offset: resumeOffset,
            maxLineBytes: 1024,
            prefixBytes: 1024)
        { line in
            secondPass.append(String(bytes: line.bytes, encoding: .utf8))
        }

        #expect(secondPass == [initial + String(completion.dropLast())])
        #expect(endOffset == Int64(Data((initial + completion).utf8).count))
    }

    @Test
    func `jsonl scanner accepts a complete final record without newline`() throws {
        let root = try self.makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let fileURL = root.appendingPathComponent("final-record.jsonl", isDirectory: false)
        let record = #"{"type":"message","id":"complete"}"#
        try record.write(to: fileURL, atomically: true, encoding: .utf8)

        var scanned: [String?] = []
        let endOffset = try CostUsageJsonl.scan(
            fileURL: fileURL,
            maxLineBytes: 1024,
            prefixBytes: 1024)
        { line in
            scanned.append(String(bytes: line.bytes, encoding: .utf8))
        }

        #expect(scanned == [record])
        #expect(endOffset == Int64(Data(record.utf8).count))
    }

    @Test
    func `jsonl scanner preserves a truncated final record`() throws {
        let root = try self.makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let fileURL = root.appendingPathComponent("truncated-final-record.jsonl", isDirectory: false)
        let record = #"{"message":"\#(String(repeating: "x", count: 256))"}"#
        try record.write(to: fileURL, atomically: true, encoding: .utf8)

        var scanned: [CostUsageJsonl.Line] = []
        let endOffset = try CostUsageJsonl.scan(
            fileURL: fileURL,
            maxLineBytes: 64,
            prefixBytes: 64)
        { line in
            scanned.append(line)
        }

        #expect(scanned.count == 1)
        #expect(scanned[0].wasTruncated)
        #expect(endOffset == Int64(Data(record.utf8).count))
    }

    @Test
    func `jsonl scanner retries a truncated incomplete final record after append`() throws {
        let root = try self.makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let fileURL = root.appendingPathComponent("truncated-appending.jsonl", isDirectory: false)
        let initial = #"{"message":"\#(String(repeating: "x", count: 256))"#
        try initial.write(to: fileURL, atomically: true, encoding: .utf8)

        var firstPass: [CostUsageJsonl.Line] = []
        let resumeOffset = try CostUsageJsonl.scan(
            fileURL: fileURL,
            maxLineBytes: 64,
            prefixBytes: 64)
        { line in
            firstPass.append(line)
        }

        #expect(firstPass.isEmpty)
        #expect(resumeOffset == 0)

        let completion = #""}"# + "\n"
        let handle = try FileHandle(forWritingTo: fileURL)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(completion.utf8))

        var secondPass: [CostUsageJsonl.Line] = []
        let endOffset = try CostUsageJsonl.scan(
            fileURL: fileURL,
            offset: resumeOffset,
            maxLineBytes: 64,
            prefixBytes: 64)
        { line in
            secondPass.append(line)
        }

        #expect(secondPass.count == 1)
        #expect(secondPass[0].wasTruncated)
        #expect(endOffset == Int64(Data((initial + completion).utf8).count))
    }

    @Test
    func `jsonl scanner retries a truncated escape sequence`() throws {
        let root = try self.makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let fileURL = root.appendingPathComponent("truncated-escape.jsonl", isDirectory: false)
        let initial = #"{"message":""# + String(repeating: "x", count: 256) + #"\u12"#
        try initial.write(to: fileURL, atomically: true, encoding: .utf8)

        var firstPass: [CostUsageJsonl.Line] = []
        let resumeOffset = try CostUsageJsonl.scan(
            fileURL: fileURL,
            maxLineBytes: 64,
            prefixBytes: 64)
        { line in
            firstPass.append(line)
        }

        #expect(firstPass.isEmpty)
        #expect(resumeOffset == 0)

        let completion = #"34"}"# + "\n"
        let handle = try FileHandle(forWritingTo: fileURL)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(completion.utf8))

        var secondPass: [CostUsageJsonl.Line] = []
        let endOffset = try CostUsageJsonl.scan(
            fileURL: fileURL,
            offset: resumeOffset,
            maxLineBytes: 64,
            prefixBytes: 64)
        { line in
            secondPass.append(line)
        }

        #expect(secondPass.count == 1)
        #expect(secondPass[0].wasTruncated)
        #expect(endOffset == Int64(Data((initial + completion).utf8).count))
    }

    @Test
    func `jsonl scanner ignores nested delimiters inside strings`() throws {
        let root = try self.makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let fileURL = root.appendingPathComponent("string-delimiters.jsonl", isDirectory: false)
        let message = String(repeating: "{[", count: 64) + #""nested""#
        let recordData = try JSONEncoder().encode(["message": message])
        try recordData.write(to: fileURL)

        var scanned: [CostUsageJsonl.Line] = []
        let endOffset = try CostUsageJsonl.scan(
            fileURL: fileURL,
            maxLineBytes: 64,
            prefixBytes: 64)
        { line in
            scanned.append(line)
        }

        #expect(scanned.count == 1)
        #expect(scanned[0].wasTruncated)
        #expect(scanned[0].bytes.count == 64)
        #expect(endOffset == Int64(recordData.count))
    }

    @Test
    func `jsonl scanner commits only complete CRLF records`() throws {
        let root = try self.makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let fileURL = root.appendingPathComponent("crlf.jsonl", isDirectory: false)
        let firstRecord = #"{"id":1}"#
        let partialRecord = #"{"id":"par"#
        let initial = firstRecord + "\r\n" + partialRecord
        try initial.write(to: fileURL, atomically: true, encoding: .utf8)

        var firstPass: [String?] = []
        let resumeOffset = try CostUsageJsonl.scan(
            fileURL: fileURL,
            maxLineBytes: 1024,
            prefixBytes: 1024)
        { line in
            firstPass.append(String(bytes: line.bytes, encoding: .utf8))
        }

        #expect(firstPass == [firstRecord + "\r"])
        #expect(resumeOffset == Int64(Data((firstRecord + "\r\n").utf8).count))

        let completion = #"tial"}"# + "\r\n"
        let handle = try FileHandle(forWritingTo: fileURL)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(completion.utf8))

        var secondPass: [String?] = []
        let endOffset = try CostUsageJsonl.scan(
            fileURL: fileURL,
            offset: resumeOffset,
            maxLineBytes: 1024,
            prefixBytes: 1024)
        { line in
            secondPass.append(String(bytes: line.bytes, encoding: .utf8))
        }

        let completedRecord = partialRecord + #"tial"}"# + "\r"
        #expect(secondPass == [completedRecord])
        #expect(endOffset == Int64(Data((initial + completion).utf8).count))
    }

    @Test
    func `jsonl scanner tracks an incomplete record across read chunks`() throws {
        let root = try self.makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let fileURL = root.appendingPathComponent("multi-chunk-tail.jsonl", isDirectory: false)
        let initial = #"{"message":""# + String(repeating: "x", count: 300_000)
        try initial.write(to: fileURL, atomically: true, encoding: .utf8)

        var firstPass: [CostUsageJsonl.Line] = []
        let resumeOffset = try CostUsageJsonl.scan(
            fileURL: fileURL,
            maxLineBytes: 64,
            prefixBytes: 64)
        { line in
            firstPass.append(line)
        }

        #expect(firstPass.isEmpty)
        #expect(resumeOffset == 0)

        let completion = #""}"# + "\n"
        let handle = try FileHandle(forWritingTo: fileURL)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(completion.utf8))

        var secondPass: [CostUsageJsonl.Line] = []
        let endOffset = try CostUsageJsonl.scan(
            fileURL: fileURL,
            offset: resumeOffset,
            maxLineBytes: 64,
            prefixBytes: 64)
        { line in
            secondPass.append(line)
        }

        #expect(secondPass.count == 1)
        #expect(secondPass[0].wasTruncated)
        #expect(secondPass[0].bytes.count == 64)
        #expect(endOffset == Int64(Data((initial + completion).utf8).count))
    }

    @Test
    func `jsonl scanner retries truncated literal prefixes`() throws {
        let root = try self.makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let cases = [("tru", "e"), ("fals", "e"), ("nul", "l")]
        for (index, testCase) in cases.enumerated() {
            let fileURL = root.appendingPathComponent("literal-\(index).jsonl", isDirectory: false)
            let initial = String(repeating: " ", count: 128) + testCase.0
            try initial.write(to: fileURL, atomically: true, encoding: .utf8)

            var firstPass: [CostUsageJsonl.Line] = []
            let resumeOffset = try CostUsageJsonl.scan(
                fileURL: fileURL,
                maxLineBytes: 64,
                prefixBytes: 64)
            { line in
                firstPass.append(line)
            }

            #expect(firstPass.isEmpty)
            #expect(resumeOffset == 0)

            let completion = testCase.1 + "\n"
            let handle = try FileHandle(forWritingTo: fileURL)
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(completion.utf8))
            try handle.close()

            var secondPass: [CostUsageJsonl.Line] = []
            let endOffset = try CostUsageJsonl.scan(
                fileURL: fileURL,
                offset: resumeOffset,
                maxLineBytes: 64,
                prefixBytes: 64)
            { line in
                secondPass.append(line)
            }

            #expect(secondPass.count == 1)
            #expect(secondPass[0].wasTruncated)
            #expect(endOffset == Int64(Data((initial + completion).utf8).count))
        }
    }

    @Test
    func `jsonl scanner retries a truncated number exponent`() throws {
        let root = try self.makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let fileURL = root.appendingPathComponent("number-exponent.jsonl", isDirectory: false)
        let initial = String(repeating: "9", count: 300_000) + "e-"
        try initial.write(to: fileURL, atomically: true, encoding: .utf8)

        var firstPass: [CostUsageJsonl.Line] = []
        let resumeOffset = try CostUsageJsonl.scan(
            fileURL: fileURL,
            maxLineBytes: 64,
            prefixBytes: 64)
        { line in
            firstPass.append(line)
        }

        #expect(firstPass.isEmpty)
        #expect(resumeOffset == 0)

        let completion = "2\n"
        let handle = try FileHandle(forWritingTo: fileURL)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(completion.utf8))

        var secondPass: [CostUsageJsonl.Line] = []
        let endOffset = try CostUsageJsonl.scan(
            fileURL: fileURL,
            offset: resumeOffset,
            maxLineBytes: 64,
            prefixBytes: 64)
        { line in
            secondPass.append(line)
        }

        #expect(secondPass.count == 1)
        #expect(secondPass[0].wasTruncated)
        #expect(endOffset == Int64(Data((initial + completion).utf8).count))
    }

    @Test
    func `jsonl scanner retries a complete numeric prefix`() throws {
        let root = try self.makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let fileURL = root.appendingPathComponent("numeric-prefix.jsonl", isDirectory: false)
        let initial = "1"
        try initial.write(to: fileURL, atomically: true, encoding: .utf8)

        var firstPass: [String?] = []
        let resumeOffset = try CostUsageJsonl.scan(
            fileURL: fileURL,
            maxLineBytes: 64,
            prefixBytes: 64)
        { line in
            firstPass.append(String(bytes: line.bytes, encoding: .utf8))
        }

        #expect(firstPass.isEmpty)
        #expect(resumeOffset == 0)

        let completion = "2\n"
        let handle = try FileHandle(forWritingTo: fileURL)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(completion.utf8))

        var secondPass: [String?] = []
        let endOffset = try CostUsageJsonl.scan(
            fileURL: fileURL,
            offset: resumeOffset,
            maxLineBytes: 64,
            prefixBytes: 64)
        { line in
            secondPass.append(String(bytes: line.bytes, encoding: .utf8))
        }

        #expect(secondPass == ["12"])
        #expect(endOffset == Int64(Data((initial + completion).utf8).count))
    }

    @Test
    func `jsonl scanner retries a truncated complete numeric prefix`() throws {
        let root = try self.makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let fileURL = root.appendingPathComponent("truncated-numeric-prefix.jsonl", isDirectory: false)
        let initial = String(repeating: " ", count: 128) + "1"
        try initial.write(to: fileURL, atomically: true, encoding: .utf8)

        var firstPass: [CostUsageJsonl.Line] = []
        let resumeOffset = try CostUsageJsonl.scan(
            fileURL: fileURL,
            maxLineBytes: 64,
            prefixBytes: 64)
        { line in
            firstPass.append(line)
        }

        #expect(firstPass.isEmpty)
        #expect(resumeOffset == 0)

        let completion = "2\n"
        let handle = try FileHandle(forWritingTo: fileURL)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(completion.utf8))

        var secondPass: [CostUsageJsonl.Line] = []
        let endOffset = try CostUsageJsonl.scan(
            fileURL: fileURL,
            offset: resumeOffset,
            maxLineBytes: 64,
            prefixBytes: 64)
        { line in
            secondPass.append(line)
        }

        #expect(secondPass.count == 1)
        #expect(secondPass[0].wasTruncated)
        #expect(endOffset == Int64(Data((initial + completion).utf8).count))
    }

    @Test
    func `jsonl scanner accepts a number terminated by trailing whitespace`() throws {
        let root = try self.makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let fileURL = root.appendingPathComponent("terminated-number.jsonl", isDirectory: false)
        let record = "12 "
        try record.write(to: fileURL, atomically: true, encoding: .utf8)

        var scanned: [String?] = []
        let endOffset = try CostUsageJsonl.scan(
            fileURL: fileURL,
            maxLineBytes: 64,
            prefixBytes: 64)
        { line in
            scanned.append(String(bytes: line.bytes, encoding: .utf8))
        }

        #expect(scanned == [record])
        #expect(endOffset == Int64(Data(record.utf8).count))
    }

    @Test
    func `jsonl scanner commits complete EOF record larger than retained prefix`() throws {
        let root = try self.makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let fileURL = root.appendingPathComponent("short-prefix.jsonl", isDirectory: false)
        let record = #"{"message":"\#(String(repeating: "x", count: 128))"}"#
        try record.write(to: fileURL, atomically: true, encoding: .utf8)

        var scanned: [CostUsageJsonl.Line] = []
        let endOffset = try CostUsageJsonl.scan(
            fileURL: fileURL,
            maxLineBytes: 1024,
            prefixBytes: 64)
        { line in
            scanned.append(line)
        }

        #expect(scanned.count == 1)
        #expect(scanned[0].wasTruncated)
        #expect(scanned[0].bytes.count == 64)
        #expect(endOffset == Int64(Data(record.utf8).count))
    }

    private func makeTemporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "codexbar-cost-usage-jsonl-\(UUID().uuidString)",
            isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}
