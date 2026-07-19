import Foundation
import Testing
@testable import CodexBarCore

@Suite(.serialized)
struct CostUsageJsonlShapeBenchmarkTests {
    @Test
    func `scanner benchmark covers codex session history shape`() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "codexbar-cost-jsonl-shape-\(UUID().uuidString)",
            isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let divisor = Self.shapeDivisor()
        let plan = CodexJsonlShapePlan.localThirtyDaySample.scaled(divisor: divisor)
        let fileURL = root.appendingPathComponent("codex-shape.jsonl", isDirectory: false)
        let fixture = try CodexJsonlShapeFixture.write(plan: plan, to: fileURL)

        let maxLineBytes = 256 * 1024
        let prefixBytes = 32 * 1024

        let currentSummary = try self.summarizeScan(
            fileURL: fileURL,
            maxLineBytes: maxLineBytes,
            prefixBytes: prefixBytes,
            scanner: CostUsageJsonl.scan)
        let baselineSummary = try self.summarizeScan(
            fileURL: fileURL,
            maxLineBytes: maxLineBytes,
            prefixBytes: prefixBytes,
            scanner: self.scanWithFrontBufferBaseline)

        #expect(currentSummary.lineCount == fixture.lineCount)
        #expect(currentSummary.truncatedCount == fixture.truncatedLineCount)
        #expect(currentSummary.endOffset == fixture.byteCount)
        #expect(baselineSummary.lineCount == currentSummary.lineCount)
        #expect(baselineSummary.truncatedCount == currentSummary.truncatedCount)
        #expect(baselineSummary.endOffset == currentSummary.endOffset)

        _ = try self.summarizeScan(
            fileURL: fileURL,
            maxLineBytes: maxLineBytes,
            prefixBytes: prefixBytes,
            scanner: CostUsageJsonl.scan)
        _ = try self.summarizeScan(
            fileURL: fileURL,
            maxLineBytes: maxLineBytes,
            prefixBytes: prefixBytes,
            scanner: self.scanWithFrontBufferBaseline)

        let currentFastest = try self.fastestScanDurationNanoseconds(
            runs: 3,
            fileURL: fileURL,
            maxLineBytes: maxLineBytes,
            prefixBytes: prefixBytes,
            scanner: CostUsageJsonl.scan)
        let baselineFastest = try self.fastestScanDurationNanoseconds(
            runs: 3,
            fileURL: fileURL,
            maxLineBytes: maxLineBytes,
            prefixBytes: prefixBytes,
            scanner: self.scanWithFrontBufferBaseline)

        let currentMBps = Self.megabytesPerSecond(byteCount: fixture.byteCount, nanoseconds: currentFastest)
        let baselineMBps = Self.megabytesPerSecond(byteCount: fixture.byteCount, nanoseconds: baselineFastest)
        let speedup = Double(baselineFastest) / Double(currentFastest)
        print(
            "Codex JSONL shape benchmark: divisor=\(divisor) " +
                "bytes=\(fixture.byteCount) lines=\(fixture.lineCount) " +
                "truncated=\(fixture.truncatedLineCount) " +
                "current=\(Self.format(currentMBps))MB/s " +
                "baseline=\(Self.format(baselineMBps))MB/s " +
                "speedup=\(Self.format(speedup))x")
    }

    @Test
    func `synthetic codex rows preserve model attribution`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let day = try env.makeLocalNoon(year: 2026, month: 5, day: 18)
        let iso0 = env.isoString(for: day)
        let iso1 = env.isoString(for: day.addingTimeInterval(1))
        let iso2 = env.isoString(for: day.addingTimeInterval(2))
        let model = "openai/gpt-5.5"
        let turnContext: [String: Any] = [
            "type": "turn_context",
            "timestamp": iso0,
            "payload": [
                "model": model,
                "instructions": "synthetic",
            ],
        ]
        let firstTokenCount = self.tokenCountWithoutModel(
            timestamp: iso1,
            input: 100,
            cached: 40,
            output: 10)
        let secondTokenCount = self.tokenCountWithoutModel(
            timestamp: iso2,
            input: 50,
            cached: 20,
            output: 5)
        let fileURL = try env.writeCodexSessionFile(
            day: day,
            filename: "synthetic-attribution.jsonl",
            contents: env.jsonl([turnContext, firstTokenCount, secondTokenCount]))

        let parsed = CostUsageScanner.parseCodexFile(
            fileURL: fileURL,
            range: CostUsageScanner.CostUsageDayRange(since: day, until: day))
        let dayKey = CostUsageScanner.CostUsageDayRange.dayKey(from: day)

        #expect(parsed.days[dayKey]?["gpt-5.5"] == [150, 60, 15])
        #expect(parsed.days[dayKey]?["gpt-5"] == nil)
    }

    private static func shapeDivisor() -> Int {
        let value = ProcessInfo.processInfo.environment["CODEXBAR_COST_JSONL_SHAPE_DIVISOR"] ?? "20"
        return max(1, Int(value) ?? 20)
    }

    private static func megabytesPerSecond(byteCount: Int64, nanoseconds: UInt64) -> Double {
        let seconds = Double(nanoseconds) / 1_000_000_000
        guard seconds > 0 else { return 0 }
        return (Double(byteCount) / 1_000_000) / seconds
    }

    private static func format(_ value: Double) -> String {
        String(format: "%.1f", value)
    }

    private func tokenCountWithoutModel(timestamp: String, input: Int, cached: Int, output: Int) -> [String: Any] {
        [
            "type": "event_msg",
            "timestamp": timestamp,
            "payload": [
                "type": "token_count",
                "info": [
                    "last_token_usage": [
                        "input_tokens": input,
                        "cached_input_tokens": cached,
                        "output_tokens": output,
                    ],
                ],
            ],
        ]
    }

    private func summarizeScan(
        fileURL: URL,
        maxLineBytes: Int,
        prefixBytes: Int,
        scanner: JsonlShapeScanner) throws -> JsonlShapeScanSummary
    {
        var lineCount = 0
        var truncatedCount = 0
        let endOffset = try scanner(fileURL, 0, maxLineBytes, prefixBytes) { line in
            lineCount += 1
            if line.wasTruncated {
                truncatedCount += 1
            }
        }

        return JsonlShapeScanSummary(
            lineCount: lineCount,
            truncatedCount: truncatedCount,
            endOffset: endOffset)
    }

    private func fastestScanDurationNanoseconds(
        runs: Int,
        fileURL: URL,
        maxLineBytes: Int,
        prefixBytes: Int,
        scanner: JsonlShapeScanner) throws -> UInt64
    {
        var fastest = UInt64.max
        for _ in 0..<runs {
            let startedAt = DispatchTime.now().uptimeNanoseconds
            _ = try self.summarizeScan(
                fileURL: fileURL,
                maxLineBytes: maxLineBytes,
                prefixBytes: prefixBytes,
                scanner: scanner)
            let elapsed = DispatchTime.now().uptimeNanoseconds - startedAt
            fastest = min(fastest, elapsed)
        }
        return fastest
    }

    @discardableResult
    private func scanWithFrontBufferBaseline(
        fileURL: URL,
        offset: Int64 = 0,
        maxLineBytes: Int,
        prefixBytes: Int,
        onLine: (CostUsageJsonl.Line) -> Void) throws
        -> Int64
    {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }

        let startOffset = max(0, offset)
        if startOffset > 0 {
            try handle.seek(toOffset: UInt64(startOffset))
        }

        var buffer = Data()
        buffer.reserveCapacity(64 * 1024)

        var current = Data()
        current.reserveCapacity(4 * 1024)
        var lineBytes = 0
        var truncated = false
        var bytesRead: Int64 = 0

        func flushLine() {
            guard lineBytes > 0 else { return }
            onLine(.init(bytes: current, wasTruncated: truncated))
            current.removeAll(keepingCapacity: true)
            lineBytes = 0
            truncated = false
        }

        while true {
            let chunk = try handle.read(upToCount: 256 * 1024) ?? Data()
            if chunk.isEmpty {
                flushLine()
                break
            }

            bytesRead += Int64(chunk.count)
            buffer.append(chunk)

            while true {
                guard let nl = buffer.firstIndex(of: 0x0A) else { break }
                let linePart = buffer[..<nl]
                buffer.removeSubrange(...nl)

                lineBytes += linePart.count
                if !truncated {
                    if lineBytes > maxLineBytes || lineBytes > prefixBytes {
                        truncated = true
                        current.removeAll(keepingCapacity: true)
                    } else {
                        current.append(contentsOf: linePart)
                    }
                }

                flushLine()
            }
        }

        return startOffset + bytesRead
    }
}

private typealias JsonlShapeScanner = (
    _ fileURL: URL,
    _ offset: Int64,
    _ maxLineBytes: Int,
    _ prefixBytes: Int,
    _ onLine: (CostUsageJsonl.Line) -> Void) throws -> Int64

private struct JsonlShapeScanSummary: Equatable {
    let lineCount: Int
    let truncatedCount: Int
    let endOffset: Int64
}

private struct CodexJsonlShapePlan {
    static let localThirtyDaySample = CodexJsonlShapePlan(
        totalLines: 145_797,
        relevantLines: 57063,
        tokenCountWithoutModelLines: 22235,
        turnContextLines: 1935,
        longTurnContextLines: 207,
        linesOver32KiB: 2584,
        linesOver256KiB: 697)

    let totalLines: Int
    let relevantLines: Int
    let tokenCountWithoutModelLines: Int
    let turnContextLines: Int
    let longTurnContextLines: Int
    let linesOver32KiB: Int
    let linesOver256KiB: Int

    func scaled(divisor: Int) -> CodexJsonlShapePlan {
        CodexJsonlShapePlan(
            totalLines: self.scaled(self.totalLines, divisor: divisor),
            relevantLines: self.scaled(self.relevantLines, divisor: divisor),
            tokenCountWithoutModelLines: self.scaled(self.tokenCountWithoutModelLines, divisor: divisor),
            turnContextLines: self.scaled(self.turnContextLines, divisor: divisor),
            longTurnContextLines: self.scaled(self.longTurnContextLines, divisor: divisor),
            linesOver32KiB: self.scaled(self.linesOver32KiB, divisor: divisor),
            linesOver256KiB: self.scaled(self.linesOver256KiB, divisor: divisor))
    }

    private func scaled(_ value: Int, divisor: Int) -> Int {
        max(1, Int((Double(value) / Double(divisor)).rounded()))
    }
}

private struct CodexJsonlShapeFixture {
    let byteCount: Int64
    let lineCount: Int
    let truncatedLineCount: Int

    static func write(plan: CodexJsonlShapePlan, to fileURL: URL) throws -> CodexJsonlShapeFixture {
        FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: fileURL)
        defer { try? handle.close() }

        var byteCount: Int64 = 0
        var lineCount = 0

        func writeLine(_ line: String) throws {
            let data = Data((line + "\n").utf8)
            try handle.write(contentsOf: data)
            byteCount += Int64(data.count)
            lineCount += 1
        }

        let longTurnContextCount = min(plan.longTurnContextLines, plan.turnContextLines)
        let shortTurnContextCount = plan.turnContextLines - longTurnContextCount
        let largeIrrelevantOver256Count = plan.linesOver256KiB
        let largeIrrelevantOver32Count = max(
            0,
            plan.linesOver32KiB - longTurnContextCount - largeIrrelevantOver256Count)
        let otherRelevantCount = max(
            0,
            plan.relevantLines - plan.tokenCountWithoutModelLines - plan.turnContextLines)
        let writtenBeforeSmallIrrelevant = plan.tokenCountWithoutModelLines
            + shortTurnContextCount
            + longTurnContextCount
            + otherRelevantCount
            + largeIrrelevantOver32Count
            + largeIrrelevantOver256Count
        let smallIrrelevantCount = max(0, plan.totalLines - writtenBeforeSmallIrrelevant)

        try self.writeRepeated(
            count: plan.tokenCountWithoutModelLines,
            line: self.tokenCountWithoutModelLine,
            writer: writeLine)
        try self.writeRepeated(
            count: shortTurnContextCount,
            line: self.turnContextLine(fillerBytes: 2048),
            writer: writeLine)
        try self.writeRepeated(
            count: longTurnContextCount,
            line: self.turnContextLine(fillerBytes: 40 * 1024),
            writer: writeLine)
        try self.writeRepeated(
            count: otherRelevantCount,
            line: self.taskStartedLine,
            writer: writeLine)
        try self.writeRepeated(
            count: largeIrrelevantOver32Count,
            line: self.irrelevantLine(fillerBytes: 64 * 1024),
            writer: writeLine)
        try self.writeRepeated(
            count: largeIrrelevantOver256Count,
            line: self.irrelevantLine(fillerBytes: 300 * 1024),
            writer: writeLine)
        try self.writeRepeated(
            count: smallIrrelevantCount,
            line: self.irrelevantLine(fillerBytes: 512),
            writer: writeLine)

        return CodexJsonlShapeFixture(
            byteCount: byteCount,
            lineCount: lineCount,
            truncatedLineCount: longTurnContextCount + largeIrrelevantOver32Count + largeIrrelevantOver256Count)
    }

    private static let tokenCountWithoutModelLine =
        #"{"type":"event_msg","timestamp":"2026-05-18T00:00:00Z","payload":{"type":"token_count","info":"#
            + #"{"last_token_usage":{"input_tokens":100,"cached_input_tokens":40,"output_tokens":10}}}}"#

    private static let taskStartedLine =
        #"{"type":"event_msg","timestamp":"2026-05-18T00:00:00Z","payload":"#
            + #"{"type":"task_started","turn_id":"turn-0001"}}"#

    private static func turnContextLine(fillerBytes: Int) -> String {
        #"{"type":"turn_context","timestamp":"2026-05-18T00:00:00Z","payload":"#
            + #"{"model":"openai/gpt-5.5","instructions":""#
            + String(repeating: "x", count: fillerBytes)
            + #""}}"#
    }

    private static func irrelevantLine(fillerBytes: Int) -> String {
        #"{"type":"response_item","payload":""# + String(repeating: "x", count: fillerBytes) + #""}"#
    }

    private static func writeRepeated(
        count: Int,
        line: String,
        writer: (String) throws -> Void) throws
    {
        for _ in 0..<count {
            try writer(line)
        }
    }
}
