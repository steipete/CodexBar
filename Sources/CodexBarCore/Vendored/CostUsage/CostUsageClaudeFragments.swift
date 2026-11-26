import Crypto
import Foundation

/// Immutable project shards; the manifest rename is the only commit point.
final class CostUsageClaudeFragments: @unchecked Sendable {
    #if DEBUG
    @TaskLocal static var shared = CostUsageClaudeFragments()
    @TaskLocal static var beforeManifestForTesting: (@Sendable () throws -> Void)?
    @TaskLocal static var encodedHeaderStorageForTesting: (@Sendable (Data) -> Data)?
    #else
    static let shared = CostUsageClaudeFragments()
    #endif

    private struct Manifest: Codable {
        var format = 1
        var header: Data
        var headerBlocks: Shard?
        var shards: [String: Shard]
    }

    private struct Shard: Codable, Equatable {
        let digest: String
        let bytes: Int
        var blocks: [String]?
    }

    private struct Snapshot {
        let stamp: CostUsageClaudeFileStamp
        let headerBlocks: Shard?
        let headerDigest: SHA256.Digest
        let shards: [String: Shard]
        let values: Any
        var header: Any?
        let cost: Int
        let contentID: UUID?

        init(
            stamp: CostUsageClaudeFileStamp,
            manifest: Manifest,
            headerDigest: SHA256.Digest,
            values: Any,
            header: Any,
            contentID: UUID?)
        {
            self.stamp = stamp
            self.headerBlocks = manifest.headerBlocks
            self.headerDigest = headerDigest
            self.shards = manifest.shards
            self.values = values
            self.header = header
            self.cost = (manifest.headerBlocks?.bytes ?? manifest.header.count) + manifest.shards.values
                .reduce(0) { $0 + $1.bytes }
            self.contentID = contentID
        }
    }

    private let lock = NSLock()
    private let blocks: CostUsageClaudeBlocks
    private let byteLimit: Int
    private var entries: [(url: URL, snapshot: Snapshot)] = []

    init(byteLimit: Int = 512 * 1024 * 1024) {
        self.byteLimit = byteLimit
        self.blocks = CostUsageClaudeBlocks(limit: min(16 * 1024 * 1024, byteLimit / 4))
    }

    #if DEBUG
    var retainedDecodedHeaderCountForTesting: Int {
        self.lock.withLock { self.entries.count(where: { $0.snapshot.header != nil }) }
    }
    #endif

    func evict(at url: URL) {
        let url = url.standardizedFileURL.resolvingSymlinksInPath()
        self.lock.withLock { self.entries.removeAll { $0.url == url } }
    }

    /// The report memo owns decoded reports; keep only the fragment metadata needed for unchanged saves.
    func discardDecodedHeader(at url: URL) {
        self.lock.withLock {
            guard let index = self.entries.lastIndex(where: { $0.url == url }) else { return }
            self.entries[index].snapshot.header = nil
        }
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
               let cachedHeader = snapshot.header, let header = cachedHeader as? Header,
               let values = snapshot.values as? [String: Value]
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
                guard (1...2).contains(manifest.format) else { throw CocoaError(.fileReadCorruptFile) }
                let headerData = try manifest.headerBlocks.map { try self.read($0, at: url) } ?? manifest.header
                let header = try decoder.decode(Header.self, from: headerData)
                var values: [String: Value] = [:]
                for descriptor in manifest.shards.values {
                    let shard = try self.read(descriptor, at: url)
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
                            headerDigest: SHA256.hash(data: headerData),
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
        separateFile: (Value) -> Bool = { _ in false },
        checkCancellation: CostUsageScanner.CancellationCheck? = nil) throws -> CostUsageClaudeFileStamp?
    {
        try self.lock.withLock {
            try Self.withFileLock(at: url) {
                try checkCancellation?()
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys]
                let previous = self.entries.last { $0.url == url }?.snapshot
                let diskStamp = CostUsageClaudeFileStamp.read(at: url)
                let current = previous?.stamp == diskStamp ? previous : nil
                let coldSave = previous == nil && diskStamp != nil
                let oldValues = current?.values as? [String: Value] ?? [:]
                var groups: [Data: [String]] = [:]
                var oldCounts: [Data: Int] = [:]
                func parent(_ path: String) -> Data {
                    let end = path.lastIndex(of: "/") ?? path.startIndex
                    return Data(path[..<end].utf8)
                }
                /// A NUL prefix cannot collide with a filesystem parent. The manifest already accepts
                /// arbitrary shard keys; old readers can open both layouts without migration.
                func fileKey(_ path: String) -> Data { Data([0]) + Data(path.utf8) }
                for (path, value) in oldValues {
                    var group = parent(path)
                    if separateFile(value) {
                        let key = fileKey(path)
                        // Legacy manifests kept even large files in their parent shard.
                        if current?.shards[Self.digest(key)] != nil { group = key }
                    }
                    oldCounts[group, default: 0] += 1
                }
                for (path, value) in values {
                    let group = separateFile(value) ? fileKey(path) : parent(path)
                    groups[group, default: []].append(path)
                }
                var headerData = try encoder.encode(header)
                #if DEBUG
                headerData = Self.encodedHeaderStorageForTesting?(headerData) ?? headerData
                #endif
                let headerDigest = SHA256.hash(data: headerData)
                var manifest = Manifest(header: headerData, shards: [:])
                if headerData.count >= CostUsageClaudeBlocks.threshold {
                    if current?.headerDigest == headerDigest, let descriptor = current?.headerBlocks {
                        manifest.headerBlocks = descriptor
                    } else {
                        manifest.headerBlocks = try self.blockDescriptor(headerData, at: url)
                    }
                    manifest.header = Data()
                }
                for (parent, paths) in groups {
                    let key = Self.digest(parent)
                    let same = oldCounts[parent] == paths.count && paths.allSatisfy { path in
                        guard let index = oldValues.index(forKey: path) else { return false }
                        return oldValues[index].key.utf8.elementsEqual(path.utf8)
                            && oldValues[index].value == values[path]
                    }
                    if same, let reference = current?.shards[key] {
                        manifest.shards[key] = reference
                    } else {
                        let group = paths.reduce(into: [String: Value]()) { $0[$1] = values[$1] }
                        let data = try encoder.encode(group)
                        if data.count >= CostUsageClaudeBlocks.threshold {
                            manifest.shards[key] = try self.blockDescriptor(data, at: url)
                            continue
                        }
                        let reference = Self.digest(data)
                        let target = Self.directory(at: url).appendingPathComponent(reference + ".json")
                        let old = (current?.shards[key]).map {
                            Self.directory(at: url).appendingPathComponent($0.digest + ".json")
                        }
                        if !coldSave || CostUsageClaudeCacheIO.read(at: target, options: .mappedIfSafe) != data {
                            try Self.write(data, at: target, replacing: old)
                        }
                        manifest.shards[key] = Shard(digest: reference, bytes: data.count)
                        #if DEBUG
                        for _ in paths {
                            CostUsageScanner.recordClaudeScanWork(.fragmentEncode)
                        }
                        #endif
                    }
                }
                if manifest.headerBlocks != nil || manifest.shards.values.contains(where: { $0.blocks != nil }) {
                    manifest.format = 2
                }
                let data = try encoder.encode(manifest)
                try checkCancellation?()
                #if DEBUG
                try Self.beforeManifestForTesting?()
                #endif
                if current?.headerDigest != headerDigest || current?.headerBlocks != manifest.headerBlocks ||
                    current?.shards != manifest.shards,
                    !coldSave || CostUsageClaudeCacheIO.read(at: url, options: .mappedIfSafe) != data
                {
                    try Self.write(data, at: url)
                    #if DEBUG
                    CostUsageScanner.recordClaudeScanWork(.artifactWrite)
                    #endif
                }
                guard let stamp = CostUsageClaudeFileStamp.read(at: url) else { return nil }
                self.remember(url, Snapshot(
                    stamp: stamp,
                    manifest: manifest,
                    headerDigest: headerDigest,
                    values: values,
                    header: header,
                    contentID: contentID))
                // Readers hold the same lock, so no reader can still need the previous manifest's shards.
                self.clean(directory: Self.directory(at: url), manifest: manifest)
                return stamp
            }
        }
    }

    private func blockDescriptor(_ data: Data, at url: URL) throws -> Shard {
        try Shard(
            digest: Self.digest(data),
            bytes: data.count,
            blocks: self.blocks.save(data, directory: Self.directory(at: url)))
    }

    private func read(_ descriptor: Shard, at url: URL) throws -> Data {
        guard descriptor.digest.count == 64, descriptor.digest.allSatisfy(\.isHexDigit), descriptor.bytes >= 0
        else { throw CocoaError(.fileReadCorruptFile) }
        let directory = Self.directory(at: url)
        let data: Data? = if let blocks = descriptor.blocks {
            try self.blocks.load(blocks, bytes: descriptor.bytes, directory: directory)
        } else {
            CostUsageClaudeCacheIO.read(
                at: directory.appendingPathComponent(descriptor.digest + ".json"),
                options: .mappedIfSafe)
        }
        guard let data, data.count == descriptor.bytes, Self.digest(data) == descriptor.digest
        else { throw CocoaError(.fileReadCorruptFile) }
        return data
    }

    private func clean(directory: URL, manifest: Manifest) {
        let descriptors = Array(manifest.shards.values) + [manifest.headerBlocks].compactMap(\.self)
        var retained = Set<String>()
        for descriptor in descriptors {
            if let blocks = descriptor.blocks {
                for id in blocks {
                    retained.insert(id + ".block")
                }
            } else {
                retained.insert(descriptor.digest + ".json")
            }
        }
        for name in (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [] {
            let suffix = name.hasSuffix(".block") ? ".block" : ".json"
            if name.count == 64 + suffix.count, name.hasSuffix(suffix),
               name.dropLast(suffix.count).allSatisfy(\.isHexDigit), !retained.contains(name)
            {
                try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
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
        CostUsageClaudeBlocks.digest(data)
    }

    static func write(_ data: Data, at url: URL, replacing source: URL? = nil) throws {
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
