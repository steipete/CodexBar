import Foundation

/// Keeps output collected from an untrusted child process within a fixed memory budget.
///
/// Callers must treat a failed append as a terminal condition rather than silently parsing
/// truncated output.
struct BoundedOutputBuffer: Sendable {
    static let defaultMaxBytes = 1 * 1024 * 1024

    private(set) var data = Data()
    private let maxBytes: Int

    var isEmpty: Bool {
        self.data.isEmpty
    }

    init(maxBytes: Int = Self.defaultMaxBytes) {
        self.maxBytes = max(0, maxBytes)
    }

    mutating func append(_ chunk: Data) -> Bool {
        guard chunk.count <= self.maxBytes - self.data.count else { return false }
        self.data.append(chunk)
        return true
    }

    mutating func removeAll(keepingCapacity: Bool = false) {
        self.data.removeAll(keepingCapacity: keepingCapacity)
    }
}

/// Splits newline-delimited child-process output without retaining an unbounded partial line.
final class BoundedLineBuffer: @unchecked Sendable {
    struct AppendResult: Sendable {
        let lines: [Data]
        let didExceedLimit: Bool
    }

    private let lock = NSLock()
    private let maxBytes: Int
    private var buffer = Data()

    init(maxBytes: Int = BoundedOutputBuffer.defaultMaxBytes) {
        self.maxBytes = max(0, maxBytes)
    }

    func appendAndDrainLines(_ chunk: Data) -> AppendResult {
        self.lock.lock()
        defer { self.lock.unlock() }

        var lines: [Data] = []
        var segmentStart = chunk.startIndex
        while let newline = chunk[segmentStart...].firstIndex(of: 0x0A) {
            let segment = chunk[segmentStart..<newline]
            guard segment.count <= self.maxBytes - self.buffer.count else {
                return AppendResult(lines: [], didExceedLimit: true)
            }
            self.buffer.append(segment)
            if !self.buffer.isEmpty {
                lines.append(self.buffer)
            }
            self.buffer.removeAll(keepingCapacity: true)
            segmentStart = chunk.index(after: newline)
        }

        let tail = chunk[segmentStart...]
        guard tail.count <= self.maxBytes - self.buffer.count else {
            return AppendResult(lines: [], didExceedLimit: true)
        }
        self.buffer.append(contentsOf: tail)
        return AppendResult(lines: lines, didExceedLimit: false)
    }
}
