import Crypto
import Foundation

/// Immutable blocks for large encoded payloads. The enclosing fragments store owns the lock.
final class CostUsageClaudeBlocks {
    static let threshold = 128 * 1024
    private static let maximum = 64 * 1024
    private struct Cached {
        let stamp: CostUsageClaudeFileStamp
        let data: Data
    }

    private let limit: Int
    private var used = 0
    private var cached: [URL: Cached] = [:]
    private var order: [URL] = []

    init(limit: Int) { self.limit = limit }

    /// A rolling Gear hash forgets earlier bytes on overflow. After an insertion the next natural
    /// boundary realigns the unchanged suffix. The hard cap also bounds low-entropy inputs.
    private static let gear: [UInt64] = (0..<256).map { index in
        var value = UInt64(index + 1) &* 0x9E37_79B9_7F4A_7C15
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }

    private static func ranges(_ data: Data) -> [Range<Int>] {
        data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            let bytes = buffer.bindMemory(to: UInt8.self)
            let table = Self.gear
            var ranges: [Range<Int>] = []
            var start = 0
            while start < bytes.count {
                let end = min(start + Self.maximum, bytes.count)
                var index = min(start + 4096, end)
                var hash: UInt64 = 0
                while index < end {
                    hash = (hash << 1) &+ table[Int(bytes[index])]
                    index += 1
                    // High bits mix a longer preceding window, including variable fields in repetitive JSON.
                    if hash >> 51 == 0 { break }
                }
                ranges.append(start..<index)
                start = index
            }
            return ranges
        }
    }

    static func digest(_ data: Data) -> String {
        let digits = Array("0123456789abcdef".utf8)
        return String(unsafeUninitializedCapacity: 64) { output in
            var index = 0
            for byte in SHA256.hash(data: data) {
                output[index] = digits[Int(byte >> 4)]
                output[index + 1] = digits[Int(byte & 15)]
                index += 2
            }
            return index
        }
    }

    func save(_ data: Data, directory: URL) throws -> [String] {
        try Self.ranges(data).map { range in
            let block = data.subdata(in: range)
            let id = Self.digest(block)
            let url = directory.appendingPathComponent(id + ".block")
            let stamp = CostUsageClaudeFileStamp.read(at: url)
            if let stamp, self.cached[url]?.stamp == stamp { return id }
            if stamp == nil || CostUsageClaudeCacheIO.read(at: url) != block {
                try CostUsageClaudeFragments.write(block, at: url)
            }
            if let stamp = CostUsageClaudeFileStamp.read(at: url) { self.remember(block, at: url, stamp: stamp) }
            return id
        }
    }

    func load(_ ids: [String], bytes: Int, directory: URL) throws -> Data {
        var data = Data()
        for id in ids {
            guard id.utf8.count == 64, id.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })
            else { throw CocoaError(.fileReadCorruptFile) }
            let url = directory.appendingPathComponent(id + ".block")
            guard let stamp = CostUsageClaudeFileStamp.read(at: url), stamp.size > 0, stamp.size <= Self.maximum,
                  data.count <= bytes - Int(stamp.size)
            else { throw CocoaError(.fileReadCorruptFile) }
            if let hit = self.cached[url], hit.stamp == stamp {
                data.append(hit.data)
            } else {
                guard let block = CostUsageClaudeCacheIO.read(at: url), block.count == stamp.size,
                      Self.digest(block) == id else { throw CocoaError(.fileReadCorruptFile) }
                self.remember(block, at: url, stamp: stamp)
                data.append(block)
            }
        }
        guard data.count == bytes else { throw CocoaError(.fileReadCorruptFile) }
        return data
    }

    private func remember(_ data: Data, at url: URL, stamp: CostUsageClaudeFileStamp) {
        if let prior = self.cached.removeValue(forKey: url) {
            self.used -= prior.data.count
            self.order.removeAll { $0 == url }
        }
        guard data.count <= self.limit else { return }
        while self.used + data.count > self.limit, let oldest = self.order.first {
            self.order.removeFirst()
            self.used -= self.cached.removeValue(forKey: oldest)?.data.count ?? 0
        }
        self.cached[url] = Cached(stamp: stamp, data: data)
        self.order.append(url)
        self.used += data.count
    }
}
