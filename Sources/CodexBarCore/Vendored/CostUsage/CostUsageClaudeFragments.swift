import Foundation

/// Memoizes encoded file locations, never filesystem metadata alone. All state is scoped to one cache URL.
final class CostUsageClaudeFragments: @unchecked Sendable {
    #if DEBUG
    @TaskLocal static var shared = CostUsageClaudeFragments()
    #else
    static let shared = CostUsageClaudeFragments()
    #endif
    private struct Fragment {
        let metadata: Data
        let rows: [CostUsageScanner.ClaudeUsageRow]?
        let range: Range<Int>
    }

    private let lock = NSLock()
    private let byteLimit: Int
    private var entries: [(url: URL, stamp: CostUsageClaudeFileStamp, files: [Data: Fragment], cost: Int)] = []

    init(byteLimit: Int = 512 * 1024 * 1024) {
        self.byteLimit = byteLimit
    }

    func evict(at url: URL) {
        let url = url.standardizedFileURL.resolvingSymlinksInPath()
        self.lock.withLock { self.entries.removeAll { $0.url == url } }
    }

    func write(
        _ cache: CostUsageClaudeCache,
        at url: URL,
        encoder: JSONEncoder,
        output: (Data?) throws -> Void,
        commit: () throws -> CostUsageClaudeFileStamp?) rethrows -> CostUsageClaudeFileStamp?
    {
        try self.lock.withLock {
            var files: [Data: Fragment] = [:]
            var cost = 0
            do {
                guard encoder.outputFormatting == [.sortedKeys] else { throw CocoaError(.fileWriteUnknown) }
                let previous = self.entries.last { $0.url == url }
                // Writers replace by rename, so the mapped old inode stays valid throughout this save.
                let mapped = previous?.stamp == CostUsageClaudeFileStamp.read(at: url)
                    ? try? Data(contentsOf: url, options: .alwaysMapped) : nil
                let reusable = previous?.stamp == CostUsageClaudeFileStamp.read(at: url) ? mapped : nil
                // Encoder-owned templates preserve Foundation's key ordering and escaping.
                let keys = try encoder.encode(cache.usage.files.mapValues { _ in 0 })
                var header = cache
                header.usage.files = [:]
                let envelope = try encoder.encode(header)
                let fileKey = try encoder.encode("files")
                var offset = 0
                func append(_ data: Data) throws {
                    try output(data)
                    offset += data.count
                }
                try Self.substitute(envelope, output: append) { key in
                    guard key == fileKey else { return false }
                    try Self.substitute(keys, output: append) { key in
                        let path = try JSONDecoder().decode(String.self, from: key)
                        guard let file = cache.usage.files[path] else { throw CocoaError(.fileWriteUnknown) }
                        var metadata = file
                        metadata.claudeRows = nil
                        let identity = try encoder.encode(metadata)
                        let start = offset
                        if let reusable, let old = previous?.files[key], old.metadata == identity,
                           old.range.upperBound <= reusable.count, Self.sameRows(old.rows, file.claudeRows)
                        {
                            try append(reusable[old.range])
                        } else {
                            let data = try encoder.encode(file)
                            #if DEBUG
                            CostUsageScanner.recordClaudeScanWork(.fragmentEncode)
                            Self.observeBytesForTesting?(
                                data.count,
                                keys.count + envelope.count + fileKey.count)
                            #endif
                            try append(data)
                        }
                        files[key] = Fragment(metadata: identity, rows: file.claudeRows, range: start..<offset)
                        // Preserve the conservative retention budget, including row string storage.
                        cost += (offset - start) * 2 + identity.count + key.count + 512
                            + (file.claudeRows?.count ?? 0) * MemoryLayout<CostUsageScanner.ClaudeUsageRow>.stride
                        return true
                    }
                    return true
                }
            } catch {
                #if DEBUG
                CostUsageScanner.recordClaudeScanWork(.fragmentFallback)
                #endif
                files = [:]
                cost = 0
                guard let data = try? encoder.encode(cache), (try? output(nil)) != nil,
                      (try? output(data)) != nil else { return nil }
            }
            guard let stamp = try commit() else { return nil }
            self.entries.removeAll { $0.url == url }
            if cost <= self.byteLimit, files.count <= 16384 {
                self.entries.append((url, stamp, files, cost))
            }
            while self.entries.count > 4 || self.entries.reduce(0, { $0 + $1.cost }) > self.byteLimit {
                self.entries.removeFirst()
            }
            return stamp
        }
    }

    #if DEBUG
    @TaskLocal static var observeBytesForTesting: (@Sendable (Int, Int) -> Void)?
    #endif

    private static func sameRows(
        _ lhs: [CostUsageScanner.ClaudeUsageRow]?, _ rhs: [CostUsageScanner.ClaudeUsageRow]?) -> Bool
    {
        guard let lhs, let rhs else { return lhs == nil && rhs == nil }
        guard lhs.count == rhs.count else { return false }
        // Array value semantics make shared, retained storage an exact identity, including Unicode bytes.
        if lhs.withUnsafeBufferPointer({ left in
            rhs.withUnsafeBufferPointer { left.baseAddress == $0.baseAddress }
        }) { return true }
        // Equatable covers scalar fields; every String field also needs a byte-exact check.
        return zip(lhs, rhs).allSatisfy { left, right in
            left == right
                && Self.sameString(left.dayKey, right.dayKey)
                && Self.sameString(left.model, right.model)
                && Self.sameString(left.sessionId, right.sessionId)
                && Self.sameString(left.messageId, right.messageId)
                && Self.sameString(left.requestId, right.requestId)
        }
    }

    private static func sameString(_ lhs: String?, _ rhs: String?) -> Bool {
        guard let lhs, let rhs else { return lhs == nil && rhs == nil }
        return lhs.utf8.elementsEqual(rhs.utf8)
    }

    /// Replace only top-level values in encoder-produced compact objects, retaining every other byte.
    private static func substitute(
        _ data: Data, output: (Data) throws -> Void, value: (Data) throws -> Bool) throws
    {
        enum InvalidTemplate: Error { case shape }
        guard data.first == 123, data.last == 125 else { throw InvalidTemplate.shape }
        var depth = 0, start = 1, colon = 0, copied = 0
        var quoted = false, escaped = false
        for (index, byte) in data.enumerated() {
            if quoted {
                switch byte {
                case _ where escaped: escaped = false
                case 92: escaped = true
                case 34: quoted = false
                default: break
                }
                continue
            }
            if byte == 34 { quoted = true }
            if byte == 58, depth == 1 { colon = index }
            if depth == 1, byte == 44 || byte == 125 {
                if colon >= start {
                    try output(data[copied..<(colon + 1)])
                    copied = try value(data.subdata(in: start..<colon)) ? index : colon + 1
                }
                start = index + 1
            }
            if byte == 123 || byte == 91 { depth += 1 }
            if byte == 125 || byte == 93 { depth -= 1 }
        }
        guard depth == 0, !quoted else { throw InvalidTemplate.shape }
        try output(data[copied..<data.count])
    }
}
