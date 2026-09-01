import Foundation

// MARK: - Cache structures (mirrors PiSessionCostCache pattern, simplified for Muse)

enum MuseSessionCostCacheIO {
    private static let artifactVersion = 1

    private static func defaultCacheRoot() -> URL {
        // Prefer the standard Caches directory, but fall back to a sandbox-allowed temp location
        // when running under the `muse.bash` Managed sandbox (which denies writes to ~/Library/Caches).
        if let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first {
            let codexRoot = root.appendingPathComponent("CodexBar", isDirectory: true)
            // Probe writability; `isWritableFile` is more reliable than trying to create and catching.
            if FileManager.default.isWritableFile(atPath: root.path) || FileManager.default.isWritableFile(atPath: codexRoot.path) || FileManager.default.fileExists(atPath: codexRoot.path) {
                return codexRoot
            }
            // Try to create the directory as a probe; if it succeeds, use it, otherwise fall back.
            if (try? FileManager.default.createDirectory(at: codexRoot, withIntermediateDirectories: true)) != nil,
               FileManager.default.isWritableFile(atPath: codexRoot.path) {
                return codexRoot
            }
        }
        // Fallback for sandboxed shells (e.g., `muse.bash`): use the process temp directory.
        return FileManager.default.temporaryDirectory.appendingPathComponent("CodexBar", isDirectory: true)
    }

    static func cacheFileURL(cacheRoot: URL? = nil) -> URL {
        let root = cacheRoot ?? self.defaultCacheRoot()
        return root
            .appendingPathComponent("cost-usage", isDirectory: true)
            .appendingPathComponent("muse-sessions-v\(Self.artifactVersion).json", isDirectory: false)
    }

    static func load(cacheRoot: URL? = nil) -> MuseSessionCostCache {
        let urls: [URL] = {
            if let cacheRoot {
                return [self.cacheFileURL(cacheRoot: cacheRoot)]
            }
            // Try default, then fallback temp for sandboxed shells
            let defaultURL = self.cacheFileURL(cacheRoot: nil)
            let fallbackURL = self.cacheFileURL(cacheRoot: FileManager.default.temporaryDirectory.appendingPathComponent("CodexBar", isDirectory: true))
            return [defaultURL, fallbackURL]
        }()
        for url in urls {
            if let data = try? Data(contentsOf: url),
               let decoded = try? JSONDecoder().decode(MuseSessionCostCache.self, from: data),
               decoded.version == Self.artifactVersion {
                return decoded
            }
        }
        return MuseSessionCostCache(version: Self.artifactVersion)
    }

    static func save(cache: MuseSessionCostCache, cacheRoot: URL? = nil, calendar: Calendar = .current) {
        var cache = cache
        cache.timeZoneIdentifier = calendar.timeZone.identifier
        let urls: [URL] = {
            if let cacheRoot {
                return [self.cacheFileURL(cacheRoot: cacheRoot)]
            }
            let defaultURL = self.cacheFileURL(cacheRoot: nil)
            let fallbackURL = self.cacheFileURL(cacheRoot: FileManager.default.temporaryDirectory.appendingPathComponent("CodexBar", isDirectory: true))
            return [defaultURL, fallbackURL]
        }()
        let data = (try? JSONEncoder().encode(cache)) ?? Data()
        var saved = false
        for url in urls {
            let dir = url.deletingLastPathComponent()
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let tmp = dir.appendingPathComponent(".tmp-\(UUID().uuidString).json", isDirectory: false)
            do {
                try data.write(to: tmp, options: [.atomic])
                if FileManager.default.fileExists(atPath: url.path) {
                    _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
                } else {
                    try FileManager.default.moveItem(at: tmp, to: url)
                }
                saved = true
                break
            } catch {
                try? FileManager.default.removeItem(at: tmp)
                continue
            }
        }
        if !saved {
            // Last resort: try workspace temp atomically
            let fallback = FileManager.default.temporaryDirectory.appendingPathComponent("CodexBar/cost-usage/muse-sessions-v\(Self.artifactVersion).json")
            try? FileManager.default.createDirectory(at: fallback.deletingLastPathComponent(), withIntermediateDirectories: true)
            let tmpFallback = fallback.deletingLastPathComponent().appendingPathComponent(".tmp-\(UUID().uuidString).json", isDirectory: false)
            if let _ = try? data.write(to: tmpFallback, options: [.atomic]) {
                if FileManager.default.fileExists(atPath: fallback.path) {
                    _ = try? FileManager.default.replaceItemAt(fallback, withItemAt: tmpFallback)
                } else {
                    try? FileManager.default.moveItem(at: tmpFallback, to: fallback)
                }
            }
        }
    }

    static func clear(cacheRoot: URL? = nil) {
        let url = self.cacheFileURL(cacheRoot: cacheRoot)
        try? FileManager.default.removeItem(at: url)
    }
}

struct MuseSessionCostCache: Codable {
    var version: Int
    var lastScanUnixMs: Int64 = 0
    var timeZoneIdentifier: String?
    // dayKey -> model -> packed usage
    var days: [String: [String: MusePackedUsage]] = [:]
    // file path -> per-file usage
    var files: [String: MuseSessionFileUsage] = [:]

    init(version: Int = 1) {
        self.version = version
    }
}

struct MuseSessionFileUsage: Codable, Equatable {
    var mtimeUnixMs: Int64
    var size: Int64
    var parsedBytes: Int64
    var prefixFingerprint: String? // hash of first 4K for same-path replacement detection
    var contributions: [String: [String: MusePackedUsage]] // day -> model -> usage
    var entryCount: Int
}

struct MusePackedUsage: Codable, Equatable {
    var inputTokens: Int = 0
    var cacheReadTokens: Int = 0
    var outputTokens: Int = 0
    var reasoningTokens: Int = 0
    var totalTokens: Int = 0
    var requestCount: Int = 0

    var isZero: Bool {
        self.totalTokens == 0 && self.requestCount == 0
    }

    static func +(lhs: MusePackedUsage, rhs: MusePackedUsage) -> MusePackedUsage {
        MusePackedUsage(
            inputTokens: lhs.inputTokens + rhs.inputTokens,
            cacheReadTokens: lhs.cacheReadTokens + rhs.cacheReadTokens,
            outputTokens: lhs.outputTokens + rhs.outputTokens,
            reasoningTokens: lhs.reasoningTokens + rhs.reasoningTokens,
            totalTokens: lhs.totalTokens + rhs.totalTokens,
            requestCount: lhs.requestCount + rhs.requestCount)
    }

    static func -(lhs: MusePackedUsage, rhs: MusePackedUsage) -> MusePackedUsage {
        MusePackedUsage(
            inputTokens: lhs.inputTokens - rhs.inputTokens,
            cacheReadTokens: lhs.cacheReadTokens - rhs.cacheReadTokens,
            outputTokens: lhs.outputTokens - rhs.outputTokens,
            reasoningTokens: lhs.reasoningTokens - rhs.reasoningTokens,
            totalTokens: lhs.totalTokens - rhs.totalTokens,
            requestCount: lhs.requestCount - rhs.requestCount)
    }
}
