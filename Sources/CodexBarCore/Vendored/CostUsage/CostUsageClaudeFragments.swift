import Crypto
import Foundation

/// Immutable project shards; the manifest rename is the only commit point.
final class CostUsageClaudeFragments: @unchecked Sendable {
    #if DEBUG
    @TaskLocal static var shared = CostUsageClaudeFragments()
    @TaskLocal static var beforeManifestForTesting: (@Sendable () throws -> Void)?
    #else
    static let shared = CostUsageClaudeFragments()
    #endif

    private struct Manifest: Codable {
        var format = 1
        var header: Data
        var shards: [String: Shard]
    }

    private struct Shard: Codable, Equatable {
        let digest: String
        let bytes: Int
    }

    private struct Snapshot {
        let stamp: CostUsageClaudeFileStamp
        let manifest: Manifest
        let values: Any
        let header: Any
        var cost: Int {
            self.manifest.header.count + self.manifest.shards.values.reduce(0) { $0 + $1.bytes }
        }

        let contentID: UUID?
    }

    private let lock = NSLock()
    private let byteLimit: Int
    private var entries: [(url: URL, snapshot: Snapshot)] = []

    init(byteLimit: Int = 512 * 1024 * 1024) { self.byteLimit = byteLimit }

    func evict(at url: URL) {
        let url = url.standardizedFileURL.resolvingSymlinksInPath()
        self.lock.withLock { self.entries.removeAll { $0.url == url } }
    }

    func currentStamp(contentID: UUID, at url: URL) -> CostUsageClaudeFileStamp? {
        self.lock.withLock {
            guard let snapshot = self.entries.last(where: { $0.url == url })?.snapshot,
                  snapshot.contentID == contentID, snapshot.stamp == CostUsageClaudeFileStamp.read(at: url)
            else { return nil }
            return snapshot.stamp
        }
    }

    func load<Header: Codable, Value: Codable>(
        at url: URL,
        legacy: (Data) throws -> (Header, [String: Value])) throws -> (Header, [String: Value])
    {
        try self.lock.withLock {
            if let snapshot = self.entries.last(where: { $0.url == url })?.snapshot,
               snapshot.stamp == CostUsageClaudeFileStamp.read(at: url),
               let header = snapshot.header as? Header, let values = snapshot.values as? [String: Value]
            {
                return (header, values)
            }
            return try Self.withFileLock(at: url) {
                guard let data = CostUsageClaudeCacheIO.read(at: url, options: .mappedIfSafe) else {
                    throw CocoaError(.fileReadNoSuchFile)
                }
                #if DEBUG
                if Header.self == CostUsageClaudeCache.self { CostUsageScanner.recordClaudeScanWork(.cacheDecode) }
                #endif
                let decoder = JSONDecoder()
                decoder.userInfo[CostUsageRowStringPool.key] = CostUsageRowStringPool()
                guard let manifest = try? decoder.decode(Manifest.self, from: data) else {
                    return try legacy(data)
                }
                guard manifest.format == 1 else { throw CocoaError(.fileReadCorruptFile) }
                let header = try decoder.decode(Header.self, from: manifest.header)
                var values: [String: Value] = [:]
                for descriptor in manifest.shards.values {
                    let reference = descriptor.digest
                    guard reference.count == 64, reference.allSatisfy(\.isHexDigit),
                          let shard = CostUsageClaudeCacheIO.read(
                              at: Self.directory(at: url).appendingPathComponent(reference + ".json"),
                              options: .mappedIfSafe), shard.count == descriptor.bytes, Self.digest(shard) == reference
                    else { throw CocoaError(.fileReadCorruptFile) }
                    let decoded = try decoder.decode([String: Value].self, from: shard)
                    for (path, value) in decoded {
                        guard values.updateValue(value, forKey: path) == nil else {
                            throw CocoaError(.fileReadCorruptFile)
                        }
                    }
                }
                if let stamp = CostUsageClaudeFileStamp.read(at: url) {
                    self.remember(
                        url,
                        Snapshot(
                            stamp: stamp,
                            manifest: manifest,
                            values: values,
                            header: header,
                            contentID: (header as? CostUsageClaudeCache)?.contentID))
                }
                return (header, values)
            }
        }
    }

    func save<Value: Codable & Equatable>(
        header: some Encodable,
        values: [String: Value],
        at url: URL,
        contentID: UUID? = nil,
        checkCancellation: CostUsageScanner.CancellationCheck? = nil) throws -> CostUsageClaudeFileStamp?
    {
        try self.lock.withLock {
            try Self.withFileLock(at: url) {
                try checkCancellation?()
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys]
                let previous = self.entries.last { $0.url == url }?.snapshot
                let current = previous?.stamp == CostUsageClaudeFileStamp.read(at: url) ? previous : nil
                let oldValues = current?.values as? [String: Value] ?? [:]
                var groups: [Data: [String]] = [:]
                var oldCounts: [Data: Int] = [:]
                func parent(_ path: String) -> Data {
                    let end = path.lastIndex(of: "/") ?? path.startIndex
                    return Data(path[..<end].utf8)
                }
                for path in oldValues.keys {
                    oldCounts[parent(path), default: 0] += 1
                }
                // Group only by lexical parent; this must never change source discovery or follow symlinks.
                for path in values.keys {
                    groups[parent(path), default: []].append(path)
                }
                var manifest = try Manifest(header: encoder.encode(header), shards: [:])
                for (parent, paths) in groups {
                    let key = Self.digest(parent)
                    let same = oldCounts[parent] == paths.count && paths.allSatisfy { path in
                        guard let index = oldValues.index(forKey: path) else { return false }
                        return oldValues[index].key.utf8.elementsEqual(path.utf8)
                            && oldValues[index].value == values[path]
                    }
                    if same, let reference = current?.manifest.shards[key] {
                        manifest.shards[key] = reference
                    } else {
                        let group = paths.reduce(into: [String: Value]()) { $0[$1] = values[$1] }
                        let data = try encoder.encode(group)
                        let reference = Self.digest(data)
                        let target = Self.directory(at: url).appendingPathComponent(reference + ".json")
                        let old = (current?.manifest.shards[key]).map {
                            Self.directory(at: url).appendingPathComponent($0.digest + ".json")
                        }
                        try Self.write(data, at: target, replacing: old)
                        manifest.shards[key] = Shard(digest: reference, bytes: data.count)
                        #if DEBUG
                        for _ in paths {
                            CostUsageScanner.recordClaudeScanWork(.fragmentEncode)
                        }
                        #endif
                    }
                }
                let data = try encoder.encode(manifest)
                try checkCancellation?()
                #if DEBUG
                try Self.beforeManifestForTesting?()
                #endif
                if current?.manifest.header != manifest.header || current?.manifest.shards != manifest.shards {
                    try Self.write(data, at: url)
                    #if DEBUG
                    CostUsageScanner.recordClaudeScanWork(.artifactWrite)
                    #endif
                }
                guard let stamp = CostUsageClaudeFileStamp.read(at: url) else { return nil }
                self.remember(url, Snapshot(
                    stamp: stamp, manifest: manifest, values: values, header: header, contentID: contentID))
                // Readers hold the same lock, so no reader can still need the previous manifest's shards.
                let retained = Set(manifest.shards.values.map { $0.digest + ".json" })
                for name in (try? FileManager.default.contentsOfDirectory(atPath: Self.directory(at: url).path)) ?? []
                    where name.count == 69 && name.hasSuffix(".json") && name.dropLast(5).allSatisfy(\.isHexDigit)
                    && !retained.contains(name)
                {
                    try? FileManager.default.removeItem(at: Self.directory(at: url).appendingPathComponent(name))
                }
                return stamp
            }
        }
    }

    private func remember(_ url: URL, _ snapshot: Snapshot) {
        self.entries.removeAll { $0.url == url }
        self.entries.append((url, snapshot))
        while self.entries.count > 8 || self.entries.reduce(0, { $0 + $1.snapshot.cost * 3 }) > self.byteLimit {
            self.entries.removeFirst()
        }
    }

    private static func directory(at url: URL) -> URL { url.appendingPathExtension("fragments") }

    private static func withFileLock<T>(at url: URL, _ body: () throws -> T) throws -> T {
        let directory = Self.directory(at: url)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let descriptor = open(
            directory.appendingPathComponent("lock").path,
            O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC,
            mode_t(0o600))
        guard descriptor >= 0 else { throw CocoaError(.fileWriteUnknown) }
        defer { close(descriptor) }
        while flock(descriptor, LOCK_EX) != 0 {
            guard errno == EINTR else { throw CocoaError(.fileWriteUnknown) }
        }
        defer { _ = flock(descriptor, LOCK_UN) }
        return try body()
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func write(_ data: Data, at url: URL, replacing source: URL? = nil) throws {
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".claude-cache-\(UUID()).tmp")
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard let writer = CostUsageClaudeArtifactWriter(temporaryURL: temporary, replacing: source ?? url) else {
            throw CocoaError(.fileWriteUnknown)
        }
        _ = try writer.append(data)
        try writer.finish()
        guard rename(temporary.path, url.path) == 0 else { throw CocoaError(.fileWriteUnknown) }
    }
}
