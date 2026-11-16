#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// Persistent per-conversation SQLite scan cache and retained complete snapshot for Antigravity local history.
struct AntigravityLocalScanCache: Codable {
    struct FileStamp: Codable, Equatable, Sendable {
        let identity: String
        let size: Int64
        let modifiedSeconds: Int64
        let modifiedNanoseconds: Int64
        let changedSeconds: Int64
        let changedNanoseconds: Int64

        static func read(at url: URL) -> Self? {
            var info = stat()
            guard url.path.withCString({ stat($0, &info) }) == 0 else { return nil }
            guard info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), info.st_size >= 0 else { return nil }
            #if os(Linux)
            let modified = info.st_mtim
            let changed = info.st_ctim
            #else
            let modified = info.st_mtimespec
            let changed = info.st_ctimespec
            #endif
            return Self(
                identity: "\(info.st_dev):\(info.st_ino)",
                size: Int64(info.st_size),
                modifiedSeconds: Int64(modified.tv_sec),
                modifiedNanoseconds: Int64(modified.tv_nsec),
                changedSeconds: Int64(changed.tv_sec),
                changedNanoseconds: Int64(changed.tv_nsec))
        }
    }

    struct WALFingerprint: Codable, Equatable, Sendable {
        let stamp: FileStamp
        let headerPrefix: Data?

        static func read(at walURL: URL) -> Self? {
            guard let stamp = FileStamp.read(at: walURL) else { return nil }
            guard let handle = try? FileHandle(forReadingFrom: walURL) else { return nil }
            defer { try? handle.close() }
            let header = (try? handle.read(upToCount: 32)) ?? Data()
            return Self(stamp: stamp, headerPrefix: header)
        }
    }

    struct SHMFingerprint: Codable, Equatable, Sendable {
        let identity: String
        let size: Int64

        static func read(at shmURL: URL) -> Self? {
            guard let stamp = FileStamp.read(at: shmURL) else { return nil }
            // Read-only SQLite opens update read marks in -shm without modifying database content,
            // so track inode identity and size rather than -shm timestamps.
            return Self(identity: stamp.identity, size: stamp.size)
        }
    }

    struct DatabaseFingerprint: Codable, Equatable, Sendable {
        let resolvedPath: String
        let main: FileStamp
        let wal: WALFingerprint?
        let shm: SHMFingerprint?

        static func current(for url: URL) -> Self? {
            let resolved = url.resolvingSymlinksInPath()
            guard let main = FileStamp.read(at: resolved) else { return nil }
            let walURL = URL(fileURLWithPath: resolved.path + "-wal")
            let wal: WALFingerprint?
            if FileManager.default.fileExists(atPath: walURL.path) {
                guard let readWAL = WALFingerprint.read(at: walURL) else { return nil }
                wal = readWAL
            } else {
                wal = nil
            }
            let shmURL = URL(fileURLWithPath: resolved.path + "-shm")
            let shm: SHMFingerprint?
            if FileManager.default.fileExists(atPath: shmURL.path) {
                guard let readSHM = SHMFingerprint.read(at: shmURL) else { return nil }
                shm = readSHM
            } else {
                shm = nil
            }
            return Self(resolvedPath: resolved.path, main: main, wal: wal, shm: shm)
        }

        var latestModifiedTimestamp: (seconds: Int64, nanoseconds: Int64) {
            guard let walStamp = self.wal?.stamp else {
                return (self.main.modifiedSeconds, self.main.modifiedNanoseconds)
            }
            if walStamp.modifiedSeconds != self.main.modifiedSeconds {
                return walStamp.modifiedSeconds > self.main.modifiedSeconds
                    ? (walStamp.modifiedSeconds, walStamp.modifiedNanoseconds)
                    : (self.main.modifiedSeconds, self.main.modifiedNanoseconds)
            }
            return walStamp.modifiedNanoseconds >= self.main.modifiedNanoseconds
                ? (walStamp.modifiedSeconds, walStamp.modifiedNanoseconds)
                : (self.main.modifiedSeconds, self.main.modifiedNanoseconds)
        }
    }

    struct CachedEvent: Codable, Equatable, Sendable {
        let session: String
        let row: Int64
        let newInput: Int
        let cacheRead: Int
        let output: Int
        let reasoning: Int
        let cacheWrite: Int
        let responseID: String?
        let modelID: Int?
        let botID: String?
        let timestampMs: Int64
        let model: String?
        let label: String?
        let stepUUID: String?

        init?(event: AntigravityLocalReader.Event) {
            guard let usage = event.turn.usage, let timestampMs = event.turn.timestampMs else { return nil }
            self.session = event.session
            self.row = event.row
            self.newInput = usage.newInput
            self.cacheRead = usage.cacheRead
            self.output = usage.output
            self.reasoning = usage.reasoning
            self.cacheWrite = event.cacheWrite
            self.responseID = usage.responseID
            self.modelID = usage.modelID
            self.botID = usage.botID
            self.timestampMs = timestampMs
            self.model = event.turn.model
            self.label = event.turn.label
            self.stepUUID = event.turn.stepUUID
        }

        func makeEvent() -> AntigravityLocalReader.Event? {
            let usage = AntigravityProtoReader.ParsedUsage(
                newInput: self.newInput,
                cacheRead: self.cacheRead,
                output: self.output,
                reasoning: self.reasoning,
                responseID: self.responseID,
                modelID: self.modelID,
                botID: self.botID)
            let turn = AntigravityProtoReader.ParsedTurn(
                usage: usage,
                timestampMs: self.timestampMs,
                model: self.model,
                label: self.label,
                stepUUID: self.stepUUID)
            return AntigravityLocalReader.Event(
                session: self.session,
                row: self.row,
                turn: turn,
                cacheWrite: self.cacheWrite)
        }
    }

    struct CachedDatabaseEntry: Codable, Equatable, Sendable {
        let fingerprint: DatabaseFingerprint
        let containsHistorySource: Bool
        let events: [CachedEvent]
    }

    struct RetainedCompleteReport: Codable, Sendable {
        let updatedAtUnixMs: Int64
        let timeZoneIdentifier: String
        let estimateCost: Bool
        let report: CostUsageDailyReport
    }

    var version: Int
    var scope: String
    var databases: [String: CachedDatabaseEntry] = [:]
    var retainedComplete: RetainedCompleteReport?
}

enum AntigravityLocalScanCacheIO {
    /// Bump when Antigravity local parsing semantics or stored event layout changes.
    static let cacheVersion = 2
    private static let maximumEntryBytes = 64 * 1024 * 1024
    private static let maximumIndexBytes = 16 * 1024 * 1024
    static let defaultMaximumReplayBytes = 128 * 1024 * 1024

    private struct IndexFile: Codable {
        let version: Int
        let scope: String
        let databaseKeys: [String]
        let retainedComplete: AntigravityLocalScanCache.RetainedCompleteReport?
    }

    private struct DatabaseFragment: Codable {
        let version: Int
        let scope: String
        let key: String
        let entry: AntigravityLocalScanCache.CachedDatabaseEntry
    }

    static func resolvedCacheRoot(explicitCacheRoot: URL?, environment: [String: String]) -> URL {
        if let explicitCacheRoot {
            return explicitCacheRoot
        }
        if let rawHome = environment["HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !rawHome.isEmpty
        {
            let envHome = URL(fileURLWithPath: rawHome, isDirectory: true)
                .standardizedFileURL.resolvingSymlinksInPath().path
            let currentHome = FileManager.default.homeDirectoryForCurrentUser
                .standardizedFileURL.resolvingSymlinksInPath().path
            if envHome != currentHome {
                return URL(fileURLWithPath: rawHome, isDirectory: true)
                    .appendingPathComponent(".cache/codexbar", isDirectory: true)
            }
        }
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches", isDirectory: true)
        return caches.appendingPathComponent("CodexBar", isDirectory: true)
    }

    static func cacheFileURL(cacheRoot: URL, scope: String) -> URL {
        let digest = self.scopeDigest(scope)
        return cacheRoot
            .appendingPathComponent("cost-usage", isDirectory: true)
            .appendingPathComponent("antigravity-scan-v\(Self.cacheVersion)-\(digest).json", isDirectory: false)
    }

    static func fragmentsDirectoryURL(cacheRoot: URL, scope: String) -> URL {
        let digest = self.scopeDigest(scope)
        return cacheRoot
            .appendingPathComponent("cost-usage", isDirectory: true)
            .appendingPathComponent("antigravity-scan-v\(Self.cacheVersion)-\(digest).fragments", isDirectory: true)
    }

    static func replayCheckpointURL(cacheRoot: URL, scope: String) -> URL {
        let digest = self.scopeDigest(scope)
        return cacheRoot
            .appendingPathComponent("cost-usage", isDirectory: true)
            .appendingPathComponent("antigravity-replay-v\(Self.cacheVersion)-\(digest).json", isDirectory: false)
    }

    static func loadReplayCheckpointData(cacheRoot: URL, scope: String) -> Data? {
        let url = self.replayCheckpointURL(cacheRoot: cacheRoot, scope: scope)
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size <= Self.maximumEntryBytes
        else { return nil }
        return try? Data(contentsOf: url)
    }

    static func replayChunksDirectoryURL(cacheRoot: URL, scope: String) -> URL {
        let digest = self.scopeDigest(scope)
        return cacheRoot
            .appendingPathComponent("cost-usage", isDirectory: true)
            .appendingPathComponent("antigravity-replay-v\(Self.cacheVersion)-\(digest).chunks", isDirectory: true)
    }

    static func loadReplayChunkData(cacheRoot: URL, scope: String, index: Int) -> Data? {
        let url = self.replayChunksDirectoryURL(cacheRoot: cacheRoot, scope: scope)
            .appendingPathComponent("chunk-\(index).json", isDirectory: false)
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size <= Self.maximumEntryBytes
        else { return nil }
        return try? Data(contentsOf: url)
    }

    @discardableResult
    static func saveShardedReplayCheckpoint(
        indexData: Data,
        chunksData: [Data],
        cacheRoot: URL,
        scope: String) -> Bool
    {
        guard indexData.count <= self.maximumEntryBytes,
              chunksData.allSatisfy({ $0.count <= Self.maximumEntryBytes })
        else { return false }
        let indexURL = self.replayCheckpointURL(cacheRoot: cacheRoot, scope: scope)
        let chunksDir = self.replayChunksDirectoryURL(cacheRoot: cacheRoot, scope: scope)
        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(
                at: indexURL.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            try fileManager.createDirectory(at: chunksDir, withIntermediateDirectories: true)
            var activeNames = Set<String>()
            for (idx, chunkData) in chunksData.enumerated() {
                let name = "chunk-\(idx).json"
                activeNames.insert(name)
                try chunkData.write(
                    to: chunksDir.appendingPathComponent(name, isDirectory: false),
                    options: [.atomic])
            }
            try indexData.write(to: indexURL, options: [.atomic])
            if let existing = try? fileManager.contentsOfDirectory(
                at: chunksDir,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles])
            {
                for url in existing where url.pathExtension == "json" && !activeNames.contains(url.lastPathComponent) {
                    try? fileManager.removeItem(at: url)
                }
            }
            return true
        } catch {
            return false
        }
    }

    static func removeReplayCheckpoint(cacheRoot: URL, scope: String) {
        let url = self.replayCheckpointURL(cacheRoot: cacheRoot, scope: scope)
        let chunksDir = self.replayChunksDirectoryURL(cacheRoot: cacheRoot, scope: scope)
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.removeItem(at: chunksDir)
    }

    private static func scopeDigest(_ scope: String) -> String {
        SHA256.hash(data: Data(scope.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func fragmentFileName(for key: String) -> String {
        let digest = SHA256.hash(data: Data(key.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return "\(digest).json"
    }

    struct IndexSnapshot {
        let indexedKeys: Set<String>
        let retainedComplete: AntigravityLocalScanCache.RetainedCompleteReport?
        let legacyDatabases: [String: AntigravityLocalScanCache.CachedDatabaseEntry]?
    }

    static func loadIndex(cacheRoot: URL, scope: String) -> IndexSnapshot {
        let url = self.cacheFileURL(cacheRoot: cacheRoot, scope: scope)
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size <= Self.maximumEntryBytes,
              let data = try? Data(contentsOf: url)
        else {
            return IndexSnapshot(indexedKeys: [], retainedComplete: nil, legacyDatabases: nil)
        }

        if let index = try? JSONDecoder().decode(IndexFile.self, from: data),
           index.version == Self.cacheVersion,
           index.scope == scope
        {
            guard data.count <= Self.maximumIndexBytes else {
                return IndexSnapshot(indexedKeys: [], retainedComplete: nil, legacyDatabases: nil)
            }
            return IndexSnapshot(
                indexedKeys: Set(index.databaseKeys),
                retainedComplete: index.retainedComplete,
                legacyDatabases: nil)
        }

        guard let decoded = try? JSONDecoder().decode(AntigravityLocalScanCache.self, from: data),
              decoded.version == Self.cacheVersion,
              decoded.scope == scope
        else {
            return IndexSnapshot(indexedKeys: [], retainedComplete: nil, legacyDatabases: nil)
        }
        return IndexSnapshot(
            indexedKeys: Set(decoded.databases.keys),
            retainedComplete: decoded.retainedComplete,
            legacyDatabases: decoded.databases)
    }

    static func fragmentFileSize(cacheRoot: URL, scope: String, key: String) -> Int? {
        let fragmentURL = self.fragmentsDirectoryURL(cacheRoot: cacheRoot, scope: scope)
            .appendingPathComponent(self.fragmentFileName(for: key), isDirectory: false)
        return try? fragmentURL.resourceValues(forKeys: [.fileSizeKey]).fileSize
    }

    static func loadFragment(
        cacheRoot: URL,
        scope: String,
        key: String) -> AntigravityLocalScanCache.CachedDatabaseEntry?
    {
        let fragmentURL = self.fragmentsDirectoryURL(cacheRoot: cacheRoot, scope: scope)
            .appendingPathComponent(self.fragmentFileName(for: key), isDirectory: false)
        guard let fragmentSize = try? fragmentURL.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              fragmentSize <= Self.maximumEntryBytes,
              let fragmentData = try? Data(contentsOf: fragmentURL),
              fragmentData.count <= Self.maximumEntryBytes,
              let fragment = try? JSONDecoder().decode(DatabaseFragment.self, from: fragmentData),
              fragment.version == Self.cacheVersion,
              fragment.scope == scope,
              fragment.key == key,
              self.fitsEntryEncodingBudget(key: key, entry: fragment.entry)
        else {
            return nil
        }
        return fragment.entry
    }

    @discardableResult
    static func saveIncremental(
        scope: String,
        activeKeys: Set<String>,
        updatedEntries: [String: AntigravityLocalScanCache.CachedDatabaseEntry],
        retainedComplete: AntigravityLocalScanCache.RetainedCompleteReport?,
        cacheRoot: URL) -> Bool
    {
        let indexURL = self.cacheFileURL(cacheRoot: cacheRoot, scope: scope)
        let fragmentsDir = self.fragmentsDirectoryURL(cacheRoot: cacheRoot, scope: scope)
        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(at: indexURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fileManager.createDirectory(at: fragmentsDir, withIntermediateDirectories: true)
        } catch {
            return false
        }

        let encoder = JSONEncoder()
        for (key, entry) in updatedEntries {
            guard self.fitsEntryEncodingBudget(key: key, entry: entry) else { return false }
            let fragment = DatabaseFragment(version: Self.cacheVersion, scope: scope, key: key, entry: entry)
            guard let fragmentData = try? encoder.encode(fragment),
                  fragmentData.count <= Self.maximumEntryBytes
            else { return false }
            let fragmentURL = fragmentsDir.appendingPathComponent(
                self.fragmentFileName(for: key),
                isDirectory: false)
            do {
                try fragmentData.write(to: fragmentURL, options: [.atomic])
            } catch {
                return false
            }
        }

        let index = IndexFile(
            version: Self.cacheVersion,
            scope: scope,
            databaseKeys: activeKeys.sorted(),
            retainedComplete: retainedComplete)
        guard let indexData = try? encoder.encode(index),
              indexData.count <= Self.maximumIndexBytes
        else { return false }
        do {
            try indexData.write(to: indexURL, options: [.atomic])
        } catch {
            return false
        }

        let activeFragmentNames = Set(activeKeys.map { self.fragmentFileName(for: $0) })
        if let existing = try? fileManager.contentsOfDirectory(
            at: fragmentsDir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles])
        {
            for url in existing
                where url.pathExtension == "json" && !activeFragmentNames.contains(url.lastPathComponent)
            {
                try? fileManager.removeItem(at: url)
            }
        }
        return true
    }

    static func fitsEntryEncodingBudget(
        key: String,
        entry: AntigravityLocalScanCache.CachedDatabaseEntry,
        maximumBytes: Int = maximumEntryBytes) -> Bool
    {
        var remaining = maximumBytes
        func charge(_ overhead: Int, strings: [String?]) -> Bool {
            guard remaining >= overhead else { return false }
            remaining -= overhead
            for string in strings {
                guard let string else { continue }
                let bytes = string.utf8.count.multipliedReportingOverflow(by: 6)
                guard !bytes.overflow, bytes.partialValue <= remaining else { return false }
                remaining -= bytes.partialValue
            }
            return true
        }
        guard charge(512, strings: [
            key,
            entry.fingerprint.resolvedPath,
            entry.fingerprint.main.identity,
            entry.fingerprint.wal?.stamp.identity,
            entry.fingerprint.shm?.identity,
        ]) else { return false }
        for event in entry.events {
            guard charge(256, strings: [
                event.session,
                event.responseID,
                event.botID,
                event.model,
                event.label,
                event.stepUUID,
            ]) else { return false }
        }
        return true
    }
}
