import Foundation

/// Retains just enough overlap to find a terminal marker split across consecutive reads.
struct StreamScanBuffer {
    private let maxNeedle: Int
    private var tail = Data()

    init(maxNeedle: Int) {
        self.maxNeedle = max(0, maxNeedle)
    }

    mutating func append(_ data: Data) -> Data {
        guard !data.isEmpty else { return Data() }
        var combined = Data()
        combined.reserveCapacity(self.tail.count + data.count)
        combined.append(self.tail)
        combined.append(data)
        if self.maxNeedle > 1 {
            if combined.count >= self.maxNeedle - 1 {
                self.tail = combined.suffix(self.maxNeedle - 1)
            } else {
                self.tail = combined
            }
        } else {
            self.tail.removeAll(keepingCapacity: true)
        }
        return combined
    }

    mutating func reset() {
        self.tail.removeAll(keepingCapacity: true)
    }

    static func lowercasedASCII(_ data: Data) -> Data {
        guard !data.isEmpty else { return data }
        var out = Data(count: data.count)
        out.withUnsafeMutableBytes { dest in
            data.withUnsafeBytes { source in
                let src = source.bindMemory(to: UInt8.self)
                let dst = dest.bindMemory(to: UInt8.self)
                for idx in 0..<src.count {
                    var byte = src[idx]
                    if byte >= 65, byte <= 90 {
                        byte += 32
                    }
                    dst[idx] = byte
                }
            }
        }
        return out
    }
}
