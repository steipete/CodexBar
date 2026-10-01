import Foundation

/// Memoizes encoded files, never filesystem metadata alone. All state is scoped to one cache URL.
final class CostUsageClaudeFragments: @unchecked Sendable {
    #if DEBUG
    @TaskLocal static var shared = CostUsageClaudeFragments()
    #else
    static let shared = CostUsageClaudeFragments()
    #endif
    private struct Fragment {
        let metadata: Data
        let rows: [CostUsageScanner.ClaudeUsageRow]?
        let data: Data
    }

    private let lock = NSLock()
    private let byteLimit: Int
    private var entries: [(url: URL, files: [Data: Fragment], cost: Int)] = []

    init(byteLimit: Int = 512 * 1024 * 1024) {
        self.byteLimit = byteLimit
    }

    func encode(_ cache: CostUsageClaudeCache, at url: URL, encoder: JSONEncoder) throws -> Data {
        try self.lock.withLock {
            do {
                return try self.assemble(cache, at: url, encoder: encoder)
            } catch {
                #if DEBUG
                CostUsageScanner.recordClaudeScanWork(.fragmentFallback)
                #endif
                return try encoder.encode(cache)
            }
        }
    }

    private func assemble(_ cache: CostUsageClaudeCache, at url: URL, encoder: JSONEncoder) throws -> Data {
        guard encoder.outputFormatting == [.sortedKeys] else {
            throw EncodingError.invalidValue(cache, .init(codingPath: [], debugDescription: "Unsupported formatting"))
        }
        let previous = self.entries.last { $0.url == url }?.files ?? [:]
        var files: [Data: Fragment] = [:]
        var cost = 0
        for (path, file) in cache.usage.files {
            let key = try encoder.encode(path)
            var metadata = file
            metadata.claudeRows = nil
            let identity = try encoder.encode(metadata)
            let fragment: Fragment
            if let old = previous[key], old.metadata == identity, Self.sameRows(old.rows, file.claudeRows) {
                fragment = old
            } else {
                fragment = try Fragment(metadata: identity, rows: file.claudeRows, data: encoder.encode(file))
                #if DEBUG
                CostUsageScanner.recordClaudeScanWork(.fragmentEncode)
                #endif
            }
            files[key] = fragment
            // Account for encoded bytes, retained row storage and strings, keys, and per-entry overhead.
            cost += fragment.data.count * 2 + identity.count + key.count + 512
                + (file.claudeRows?.count ?? 0) * MemoryLayout<CostUsageScanner.ClaudeUsageRow>.stride
        }
        // JSONWriter sorts UTF-8 on current Foundation, but older runtimes use NSString compatibility sorting.
        // Let the encoder order AND escape the actual keys; do not recreate either policy with String comparison.
        let keys = try encoder.encode(cache.usage.files.mapValues { _ in 0 })
        let body = try Self.substitute(keys) { files[$0]?.data }
        var header = cache
        header.usage.files = [:]
        let fileKey = try encoder.encode("files")
        let data = try Self.substitute(encoder.encode(header)) { $0 == fileKey ? body : nil }
        self.entries.removeAll { $0.url == url }
        if cost <= self.byteLimit, files.count <= 16384 {
            self.entries.append((url, files, cost))
        }
        while self.entries.count > 4 || self.entries.reduce(0, { $0 + $1.cost }) > self.byteLimit {
            self.entries.removeFirst()
        }
        return data
    }

    private static func sameRows(
        _ lhs: [CostUsageScanner.ClaudeUsageRow]?, _ rhs: [CostUsageScanner.ClaudeUsageRow]?) -> Bool
    {
        switch (lhs, rhs) {
        case (nil, nil): return true
        case let (lhs?, rhs?):
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
        default: return false
        }
    }

    private static func sameString(_ lhs: String?, _ rhs: String?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil): true
        case let (lhs?, rhs?): lhs.utf8.elementsEqual(rhs.utf8)
        default: false
        }
    }

    /// Replace only top-level values in encoder-produced compact objects, retaining every other byte.
    private static func substitute(_ data: Data, value: (Data) -> Data?) throws -> Data {
        enum InvalidTemplate: Error { case shape }
        guard data.first == 123, data.last == 125 else { throw InvalidTemplate.shape }
        var result = Data()
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
                if colon >= start, let replacement = value(data.subdata(in: start..<colon)) {
                    result.append(data.subdata(in: copied..<(colon + 1)))
                    result.append(replacement)
                    copied = index
                }
                start = index + 1
            }
            if byte == 123 || byte == 91 { depth += 1 }
            if byte == 125 || byte == 93 { depth -= 1 }
        }
        guard depth == 0, !quoted else { throw InvalidTemplate.shape }
        result.append(data.subdata(in: copied..<data.count))
        return result
    }
}
