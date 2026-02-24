import Foundation
import Testing
@testable import CodexBarCore

@Suite(.serialized)
struct CostUsageJsonlPerformanceTests {
    @Test
    func scannerBenchmarkBeatsFrontBufferBaseline() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "codexbar-cost-usage-bench-\(UUID().uuidString)",
            isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let fileURL = root.appendingPathComponent("scanner-benchmark.jsonl", isDirectory: false)
        let lineCount = 20000
        let line = #"{"type":"assistant","message":{"usage":{"input_tokens":1,"output_tokens":2}}}"#
        let fixture = makeBenchmarkFixture(line: line, lineCount: lineCount)
        try fixture.write(to: fileURL)

        let maxLineBytes = 8192
        let prefixBytes = 8192

        let currentSummary = try summarizeScan(
            fileURL: fileURL,
            maxLineBytes: maxLineBytes,
            prefixBytes: prefixBytes,
            scanner: CostUsageJsonl.scan)
        let baselineSummary = try summarizeScan(
            fileURL: fileURL,
            maxLineBytes: maxLineBytes,
            prefixBytes: prefixBytes,
            scanner: scanWithFrontBufferBaseline)

        #expect(currentSummary == baselineSummary)
        #expect(currentSummary.lineCount == lineCount)
        #expect(currentSummary.truncatedCount == 0)

        // Warm up both code paths before timing.
        _ = try summarizeScan(
            fileURL: fileURL,
            maxLineBytes: maxLineBytes,
            prefixBytes: prefixBytes,
            scanner: CostUsageJsonl.scan)
        _ = try summarizeScan(
            fileURL: fileURL,
            maxLineBytes: maxLineBytes,
            prefixBytes: prefixBytes,
            scanner: scanWithFrontBufferBaseline)

        let currentFastest = try fastestScanDurationNanoseconds(
            runs: 3,
            fileURL: fileURL,
            maxLineBytes: maxLineBytes,
            prefixBytes: prefixBytes,
            scanner: CostUsageJsonl.scan)
        let baselineFastest = try fastestScanDurationNanoseconds(
            runs: 3,
            fileURL: fileURL,
            maxLineBytes: maxLineBytes,
            prefixBytes: prefixBytes,
            scanner: scanWithFrontBufferBaseline)

        let speedup = Double(baselineFastest) / Double(currentFastest)
        #expect(speedup >= 5.0)
    }
}

private struct JsonlScanSummary: Equatable {
    let lineCount: Int
    let truncatedCount: Int
    let payloadByteCount: Int
    let endOffset: Int64
}

private typealias JsonlScanner = (
    _ fileURL: URL,
    _ offset: Int64,
    _ maxLineBytes: Int,
    _ prefixBytes: Int,
    _ onLine: (CostUsageJsonl.Line) -> Void) throws -> Int64

private func makeBenchmarkFixture(line: String, lineCount: Int) -> Data {
    let lineBytes = Data(line.utf8)
    var data = Data()
    data.reserveCapacity((lineBytes.count + 1) * lineCount)
    for _ in 0..<lineCount {
        data.append(lineBytes)
        data.append(0x0A)
    }
    return data
}

private func summarizeScan(
    fileURL: URL,
    maxLineBytes: Int,
    prefixBytes: Int,
    scanner: JsonlScanner) throws -> JsonlScanSummary
{
    var lineCount = 0
    var truncatedCount = 0
    var payloadByteCount = 0

    let endOffset = try scanner(fileURL, 0, maxLineBytes, prefixBytes) { line in
        lineCount += 1
        payloadByteCount += line.bytes.count
        if line.wasTruncated {
            truncatedCount += 1
        }
    }

    return JsonlScanSummary(
        lineCount: lineCount,
        truncatedCount: truncatedCount,
        payloadByteCount: payloadByteCount,
        endOffset: endOffset)
}

private func fastestScanDurationNanoseconds(
    runs: Int,
    fileURL: URL,
    maxLineBytes: Int,
    prefixBytes: Int,
    scanner: JsonlScanner) throws -> UInt64
{
    var fastest = UInt64.max
    for _ in 0..<runs {
        let startedAt = DispatchTime.now().uptimeNanoseconds
        _ = try summarizeScan(
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
