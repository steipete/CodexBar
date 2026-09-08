import Foundation
import Testing
@testable import CodexBarCore

struct JsonlParityRow: Codable, Equatable {
    let bytes: Data
    let truncated: Bool
    let start: Int64
    let end: Int64
}

struct JsonlParityOutcome: Codable, Equatable {
    var rows: [JsonlParityRow] = []
    var committed: Int64? = nil
    var read: Int64? = nil
    var resume: Data? = nil
    var events: [String] = []
    var failure: String? = nil
    var lineCount = 0
}

enum JsonlParityError: Error { case cancelled }
func encodeJsonlParity(_ value: some Encodable) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return try encoder.encode(value)
}

func runJsonlParity(
    _ variant: JsonlParityVariant,
    _ file: URL,
    offset: Int64 = 0,
    maximum: Int = 524_288,
    prefix: Int = 524_288,
    budget: Int64? = nil,
    resume: Data? = nil,
    stopAt: Int? = nil,
    stopAfterLine: Bool = false,
    cancelAt: Int? = nil,
    cancelAfterLine: Bool = false,
    action: ((Int) throws -> Void)? = nil) -> JsonlParityOutcome
{
    var result = JsonlParityOutcome()
    var checks = 0
    var stops = 0
    let check: () throws -> Void = {
        checks += 1
        result.events.append("check:\(checks):lines:\(result.lineCount)")
        try action?(checks)
        if checks == cancelAt || (cancelAfterLine && result.lineCount > 0) { throw JsonlParityError.cancelled }
    }
    let stop: (Int64) -> Bool = { count in
        stops += 1
        result.events.append("stop:\(stops):bytes:\(count):lines:\(result.lineCount)")
        return stops == stopAt || (stopAfterLine && result.lineCount > 0)
    }
    func line(_ bytes: Data, _ truncated: Bool, _ start: Int64, _ end: Int64) {
        result.rows.append(JsonlParityRow(bytes: bytes, truncated: truncated, start: start, end: end))
        result.events.append("line:\(start):\(end)")
        result.lineCount += 1
    }
    do {
        switch variant {
        case .scalar:
            let state = try resume
                .map { try JSONDecoder().decode(FrozenScalarCostUsageJsonl.ResumeState.self, from: $0) }
            let progress = try FrozenScalarCostUsageJsonl.scanBounded(
                fileURL: file,
                offset: offset,
                maxLineBytes: maximum,
                prefixBytes: prefix,
                maxBytesToRead: budget,
                resumeState: state,
                shouldStop: stop,
                checkCancellation: check,
                onLine: { line($0.bytes, $0.wasTruncated, $0.startOffset, $0.endOffset) })
            result.committed = progress.committedOffset
            result.read = progress.readOffset
            result.resume = try progress.resumeState.map { try encodeJsonlParity($0) }
        case .production:
            let state = try resume.map { try JSONDecoder().decode(CostUsageJsonl.ResumeState.self, from: $0) }
            let progress = try CostUsageJsonl.scanBounded(
                fileURL: file,
                offset: offset,
                maxLineBytes: maximum,
                prefixBytes: prefix,
                maxBytesToRead: budget,
                resumeState: state,
                shouldStop: stop,
                checkCancellation: check,
                onLine: { line(
                    $0.bytes,
                    $0.wasTruncated,
                    $0.startOffset,
                    $0.endOffset) })
            result.committed = progress.committedOffset
            result.read = progress.readOffset
            result.resume = try progress.resumeState.map { try encodeJsonlParity($0) }
        }
    } catch {
        let value = error as NSError
        result.failure = "\(value.domain):\(value.code)"
    }
    return result
}

enum JsonlParityVariant { case scalar, production }

final class JsonlParityFixture {
    let root: URL
    let file: URL
    private(set) var comparisons = 0

    init() throws {
        self.root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexBar-jsonl-parity-" + UUID().uuidString, isDirectory: true)
        self.file = self.root.appendingPathComponent("input.jsonl")
        try FileManager.default.createDirectory(at: self.root, withIntermediateDirectories: true)
    }

    func remove() {
        try? FileManager.default.removeItem(at: self.root)
    }

    @discardableResult
    func compare(
        _ label: String,
        _ body: (JsonlParityVariant) throws -> JsonlParityOutcome) throws -> JsonlParityOutcome
    {
        let baseline = try body(.scalar)
        let candidate = try body(.production)
        try #require(baseline == candidate, "Scalar parity failed: \(label)")
        self.comparisons += 1
        return baseline
    }
}
