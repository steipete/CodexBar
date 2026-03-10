import Foundation

enum CostUsageJsonl {
    struct Line: Sendable {
        let bytes: Data
        let wasTruncated: Bool
    }

    @discardableResult
    static func scan(
        fileURL: URL,
        offset: Int64 = 0,
        maxLineBytes: Int,
        prefixBytes: Int,
        onLine: (Line) -> Void) throws
        -> Int64
    {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }

        let startOffset = max(0, offset)
        if startOffset > 0 {
            try handle.seek(toOffset: UInt64(startOffset))
        }

        var current = Data()
        current.reserveCapacity(4 * 1024)
        var lineBytes = 0
        var truncated = false
        var bytesRead: Int64 = 0

        func appendSegment(_ segment: Data.SubSequence) {
            guard !segment.isEmpty else { return }
            lineBytes += segment.count
            guard !truncated else { return }
            if lineBytes > maxLineBytes || lineBytes > prefixBytes {
                truncated = true
                current.removeAll(keepingCapacity: true)
                return
            }
            current.append(contentsOf: segment)
        }

        func flushLine() {
            guard lineBytes > 0 else { return }
            let line = Line(bytes: current, wasTruncated: truncated)
            onLine(line)
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
            var segmentStart = chunk.startIndex
            while let nl = chunk[segmentStart...].firstIndex(of: 0x0A) {
                appendSegment(chunk[segmentStart..<nl])
                flushLine()
                segmentStart = chunk.index(after: nl)
            }
            if segmentStart < chunk.endIndex {
                appendSegment(chunk[segmentStart..<chunk.endIndex])
            }
        }

        return startOffset + bytesRead
    }
}
