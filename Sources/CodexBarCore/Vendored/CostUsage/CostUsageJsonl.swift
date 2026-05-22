import Foundation

enum CostUsageJsonl {
    struct Line {
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

        func appendSegment(_ bytes: UnsafePointer<UInt8>, count: Int) {
            guard count > 0 else { return }
            lineBytes += count
            if current.count < prefixBytes {
                let appendCount = min(prefixBytes - current.count, count)
                if appendCount > 0 {
                    current.append(bytes, count: appendCount)
                }
            }
            if lineBytes > maxLineBytes || lineBytes > prefixBytes {
                truncated = true
            }
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
            chunk.withUnsafeBytes { rawBuffer in
                guard let base = rawBuffer.bindMemory(to: UInt8.self).baseAddress else { return }
                var segmentStart = 0
                var index = 0
                while index < rawBuffer.count {
                    if base[index] == 0x0A {
                        appendSegment(base.advanced(by: segmentStart), count: index - segmentStart)
                        flushLine()
                        segmentStart = index + 1
                    }
                    index += 1
                }
                if segmentStart < rawBuffer.count {
                    appendSegment(base.advanced(by: segmentStart), count: rawBuffer.count - segmentStart)
                }
            }
        }

        return startOffset + bytesRead
    }
}
