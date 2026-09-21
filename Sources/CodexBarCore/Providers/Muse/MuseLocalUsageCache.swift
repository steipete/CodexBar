import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// Per-file scan cache for Muse session logs.
///
/// Completed files retain their events with device/inode identity and precise modification/change
/// timestamps. Root and timezone changes require a fresh scan; numeric totals never imply pricing.
struct MuseLocalUsageCache: Codable {
    struct DayTotals: Codable, Equatable {
        var inputTokens: Int
        var outputTokens: Int
        var cacheReadTokens: Int
        var cacheWriteTokens: Int
        var reasoningTokens: Int
        var totalTokens: Int
        var requestCount: Int
        var models: [String: Int]

        init(
            inputTokens: Int = 0,
            outputTokens: Int = 0,
            cacheReadTokens: Int = 0,
            cacheWriteTokens: Int = 0,
            reasoningTokens: Int = 0,
            totalTokens: Int = 0,
            requestCount: Int = 0,
            models: [String: Int] = [:])
        {
            self.inputTokens = inputTokens
            self.outputTokens = outputTokens
            self.cacheReadTokens = cacheReadTokens
            self.cacheWriteTokens = cacheWriteTokens
            self.reasoningTokens = reasoningTokens
            self.totalTokens = totalTokens
            self.requestCount = requestCount
            self.models = models
        }
    }

    /// One recorded turn, kept per event rather than pre-aggregated per file.
    ///
    /// Aggregating a file's turns before caching would make overlap unresolvable: a log holding one
    /// already-counted event alongside unique ones could only be taken whole or dropped whole, and
    /// dropping it would silently under-report. Per-event rows let deduplication skip exactly the
    /// repeated ids and keep the rest.
    struct Event: Codable, Equatable {
        var id: String
        var day: String
        var model: String
        var inputTokens: Int
        var outputTokens: Int
        var cacheReadTokens: Int
        var cacheWriteTokens: Int
        var reasoningTokens: Int
        var totalTokens: Int

        var isValid: Bool {
            !self.id.isEmpty && !self.model.isEmpty && self.inputTokens >= 0 && self.outputTokens >= 0
                && self.cacheReadTokens >= 0 && self.cacheReadTokens <= self.inputTokens
                && self.cacheWriteTokens >= 0 && self.cacheWriteTokens <= self.inputTokens
                && self.reasoningTokens >= 0 && self.reasoningTokens <= self.outputTokens
                && MuseLocalUsageReader.checkedAdd(self.inputTokens, self.outputTokens) == self.totalTokens
        }
    }

    struct FileStamp: Codable, Equatable {
        let identity: String
        let size: Int64
        let modifiedSeconds: Int64
        let modifiedNanoseconds: Int64
        let changedSeconds: Int64
        let changedNanoseconds: Int64

        static func read(at url: URL) -> Self? {
            var info = stat()
            guard url.path.withCString({ fstatat(AT_FDCWD, $0, &info, AT_SYMLINK_NOFOLLOW) }) == 0 else { return nil }
            return Self.make(info)
        }

        static func read(descriptor: Int32) -> Self? {
            var info = stat()
            guard fstat(descriptor, &info) == 0 else { return nil }
            return Self.make(info)
        }

        private static func make(_ info: stat) -> Self? {
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

    struct FileEntry: Codable {
        var stamp: FileStamp?
        var events: [Event]
        var isComplete: Bool
    }

    var version: Int
    var timeZoneIdentifier: String?
    var calendarIdentifier: String?
    var sessionsRoot: String?
    var sinceDayKey: String?
    var untilDayKey: String?
    var files: [String: FileEntry] = [:]
}

enum MuseLocalUsageCacheIO {
    /// Artifact schema version; bump when the parser or the stored shape changes.
    private static let artifactVersion = 4
    private static let maximumBytes = 64 * 1024 * 1024

    private static func defaultCacheRoot() -> URL {
        let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        return root.appendingPathComponent("CodexBar", isDirectory: true)
    }

    static func cacheFileURL(cacheRoot: URL? = nil) -> URL {
        let root = cacheRoot ?? self.defaultCacheRoot()
        return root
            .appendingPathComponent("cost-usage", isDirectory: true)
            .appendingPathComponent("muse-sessions-v\(Self.artifactVersion).json", isDirectory: false)
    }

    static func load(
        sessionsRoot: URL,
        cacheRoot: URL? = nil,
        calendar: Calendar = .current,
        sinceDayKey: String? = nil,
        untilDayKey: String? = nil) -> MuseLocalUsageCache
    {
        let url = self.cacheFileURL(cacheRoot: cacheRoot)
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size <= self.maximumBytes,
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(MuseLocalUsageCache.self, from: data),
              decoded.version == Self.artifactVersion,
              // Day keys are timezone-dependent, so a moved machine must rebucket from scratch.
              decoded.timeZoneIdentifier == calendar.timeZone.identifier,
              decoded.calendarIdentifier == String(describing: calendar.identifier),
              decoded.sessionsRoot == sessionsRoot.standardizedFileURL.path,
              decoded.sinceDayKey == sinceDayKey, decoded.untilDayKey == untilDayKey,
              self.fitsEncodingBudget(decoded)
        else {
            return MuseLocalUsageCache(version: Self.artifactVersion)
        }
        return decoded
    }

    static func save(
        cache: MuseLocalUsageCache,
        sessionsRoot: URL,
        cacheRoot: URL? = nil,
        calendar: Calendar = .current,
        sinceDayKey: String? = nil,
        untilDayKey: String? = nil,
        maximumBytes: Int = maximumBytes)
    {
        let url = self.cacheFileURL(cacheRoot: cacheRoot)
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        var cache = cache
        cache.timeZoneIdentifier = calendar.timeZone.identifier
        cache.calendarIdentifier = String(describing: calendar.identifier)
        cache.sessionsRoot = sessionsRoot.standardizedFileURL.path
        cache.sinceDayKey = sinceDayKey
        cache.untilDayKey = untilDayKey
        guard self.fitsEncodingBudget(cache, maximumBytes: maximumBytes),
              let data = try? JSONEncoder().encode(cache), data.count <= maximumBytes
        else { return }
        try? data.write(to: url, options: [.atomic])
    }

    /// Conservative JSON upper bound, including worst-case string escaping, checked before encoding allocates Data.
    static func fitsEncodingBudget(_ cache: MuseLocalUsageCache, maximumBytes: Int = maximumBytes) -> Bool {
        var remaining = maximumBytes
        func charge(_ overhead: Int, strings: [String]) -> Bool {
            guard remaining >= overhead else { return false }
            remaining -= overhead
            for string in strings {
                let bytes = string.utf8.count.multipliedReportingOverflow(by: 6)
                guard !bytes.overflow, bytes.partialValue <= remaining else { return false }
                remaining -= bytes.partialValue
            }
            return true
        }
        guard charge(1024, strings: [
            cache.sessionsRoot ?? "", cache.timeZoneIdentifier ?? "", cache.calendarIdentifier ?? "",
            cache.sinceDayKey ?? "", cache.untilDayKey ?? "",
        ]) else { return false }
        for (path, file) in cache.files {
            guard charge(1024, strings: [path, file.stamp?.identity ?? ""]) else { return false }
            for event in file.events {
                guard charge(512, strings: [event.id, event.day, event.model]) else { return false }
            }
        }
        return true
    }
}
