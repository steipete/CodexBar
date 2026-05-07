import Foundation

public struct ProviderStorageFootprint: Sendable, Equatable {
    public struct Component: Sendable, Equatable, Identifiable {
        public let id: String
        public let path: String
        public let totalBytes: Int64

        public init(path: String, totalBytes: Int64) {
            self.id = path
            self.path = path
            self.totalBytes = totalBytes
        }

        public var name: String {
            let url = URL(fileURLWithPath: self.path)
            let last = url.lastPathComponent
            if last.isEmpty { return self.path }
            return last
        }
    }

    public let provider: UsageProvider
    public let totalBytes: Int64
    public let paths: [String]
    public let missingPaths: [String]
    public let unreadablePaths: [String]
    public let components: [Component]
    public let updatedAt: Date

    public init(
        provider: UsageProvider,
        totalBytes: Int64,
        paths: [String],
        missingPaths: [String],
        unreadablePaths: [String],
        components: [Component] = [],
        updatedAt: Date)
    {
        self.provider = provider
        self.totalBytes = totalBytes
        self.paths = paths
        self.missingPaths = missingPaths
        self.unreadablePaths = unreadablePaths
        self.components = components
        self.updatedAt = updatedAt
    }

    public var hasLocalData: Bool {
        self.totalBytes > 0
    }

    public var cleanupRecommendations: [ProviderStorageRecommendation] {
        ProviderStorageRecommendation.recommendations(for: self)
    }

    public func replacingProvider(_ provider: UsageProvider) -> ProviderStorageFootprint {
        ProviderStorageFootprint(
            provider: provider,
            totalBytes: self.totalBytes,
            paths: self.paths,
            missingPaths: self.missingPaths,
            unreadablePaths: self.unreadablePaths,
            components: self.components,
            updatedAt: self.updatedAt)
    }
}

public struct ProviderStorageRecommendation: Sendable, Equatable, Identifiable {
    public enum RiskLevel: String, Sendable {
        case informational
        case manualCleanup
    }

    public let id: String
    public let provider: UsageProvider
    public let path: String
    public let bytes: Int64
    public let title: String
    public let riskLevel: RiskLevel
    public let consequence: String
    public let sortPriority: Int

    public init(
        provider: UsageProvider,
        path: String,
        bytes: Int64,
        title: String,
        riskLevel: RiskLevel,
        consequence: String,
        sortPriority: Int)
    {
        self.id = path
        self.provider = provider
        self.path = path
        self.bytes = bytes
        self.title = title
        self.riskLevel = riskLevel
        self.consequence = consequence
        self.sortPriority = sortPriority
    }

    public static func recommendations(for footprint: ProviderStorageFootprint) -> [ProviderStorageRecommendation] {
        let candidates: [ProviderStorageRecommendation] = footprint.components.compactMap { component in
            switch footprint.provider {
            case .claude:
                self.claudeRecommendation(for: component)
            case .codex:
                self.codexRecommendation(for: component, roots: footprint.paths)
            default:
                nil
            }
        }

        return candidates.sorted { lhs, rhs in
            if lhs.sortPriority == rhs.sortPriority {
                if lhs.bytes == rhs.bytes {
                    return lhs.path.localizedCaseInsensitiveCompare(rhs.path) == .orderedAscending
                }
                return lhs.bytes > rhs.bytes
            }
            return lhs.sortPriority < rhs.sortPriority
        }
    }

    private static func claudeRecommendation(
        for component: ProviderStorageFootprint.Component)
        -> ProviderStorageRecommendation?
    {
        switch component.name {
        case "projects":
            self.make(
                provider: .claude,
                component: component,
                title: "Manual cleanup: past sessions",
                consequence: "Clearing removes past resume, continue, and rewind history.",
                priority: 10)
        case "file-history":
            self.make(
                provider: .claude,
                component: component,
                title: "Manual cleanup: file checkpoints",
                consequence: "Clearing removes checkpoint restore data for previous edits.",
                priority: 20)
        case "plans":
            self.make(
                provider: .claude,
                component: component,
                title: "Manual cleanup: saved plans",
                consequence: "Clearing removes old plan-mode files.",
                priority: 30)
        case "debug":
            self.make(
                provider: .claude,
                component: component,
                title: "Manual cleanup: debug logs",
                consequence: "Clearing removes past debug logs.",
                priority: 40)
        case "paste-cache", "image-cache":
            self.make(
                provider: .claude,
                component: component,
                title: "Manual cleanup: attachment cache",
                consequence: "Clearing removes cached large pastes or attached images.",
                priority: 50)
        case "session-env":
            self.make(
                provider: .claude,
                component: component,
                title: "Manual cleanup: session metadata",
                consequence: "Clearing removes per-session environment metadata.",
                priority: 60)
        case "shell-snapshots":
            self.make(
                provider: .claude,
                component: component,
                title: "Manual cleanup: shell snapshots",
                consequence: "Clearing removes leftover runtime shell snapshot files.",
                priority: 70)
        case "todos":
            self.make(
                provider: .claude,
                component: component,
                title: "Manual cleanup: legacy todos",
                consequence: "Clearing removes legacy per-session task lists.",
                priority: 80)
        default:
            nil
        }
    }

    private static func codexRecommendation(
        for component: ProviderStorageFootprint.Component,
        roots: [String])
        -> ProviderStorageRecommendation?
    {
        guard self.path(component.path, isContainedIn: roots) else { return nil }

        return switch component.name {
        case "sessions":
            self.make(
                provider: .codex,
                component: component,
                title: "Manual cleanup: sessions",
                consequence: "Clearing removes past Codex session history.",
                priority: 10)
        case "archived_sessions":
            self.make(
                provider: .codex,
                component: component,
                title: "Manual cleanup: archived sessions",
                consequence: "Clearing removes archived Codex session history.",
                priority: 20)
        case "cache", "caches", "Cache", "Caches":
            self.make(
                provider: .codex,
                component: component,
                title: "Manual cleanup: cache",
                consequence: "Clearing removes provider-owned cached data.",
                priority: 30)
        case "log", "logs", "debug":
            self.make(
                provider: .codex,
                component: component,
                title: "Manual cleanup: logs",
                consequence: "Clearing removes local diagnostic logs.",
                priority: 40)
        case let name where name.hasPrefix("logs_") && name.hasSuffix(".sqlite"):
            self.make(
                provider: .codex,
                component: component,
                title: "Manual cleanup: logs",
                consequence: "Clearing removes local diagnostic logs.",
                priority: 40)
        case "file-history":
            self.make(
                provider: .codex,
                component: component,
                title: "Manual cleanup: file history",
                consequence: "Clearing removes local edit checkpoint history.",
                priority: 50)
        case "paste-cache", "image-cache", "session-env", "shell-snapshots", "shell_snapshots", "tmp", "temp", ".tmp":
            self.make(
                provider: .codex,
                component: component,
                title: "Manual cleanup: temporary data",
                consequence: "Clearing removes local temporary provider data.",
                priority: 60)
        default:
            nil
        }
    }

    private static func make(
        provider: UsageProvider,
        component: ProviderStorageFootprint.Component,
        title: String,
        consequence: String,
        priority: Int)
        -> ProviderStorageRecommendation
    {
        ProviderStorageRecommendation(
            provider: provider,
            path: component.path,
            bytes: component.totalBytes,
            title: title,
            riskLevel: .manualCleanup,
            consequence: consequence,
            sortPriority: priority)
    }

    private static func path(_ path: String, isContainedIn roots: [String]) -> Bool {
        let standardizedPath = URL(fileURLWithPath: path).standardizedFileURL.path
        return roots.contains { root in
            let standardizedRoot = URL(fileURLWithPath: root, isDirectory: true).standardizedFileURL.path
            return standardizedPath == standardizedRoot || standardizedPath.hasPrefix(standardizedRoot + "/")
        }
    }
}

public enum ProviderStoragePathCatalog {
    public static func candidatePaths(
        for provider: UsageProvider,
        environment: [String: String],
        managedCodexAccounts: [ManagedCodexAccount] = [],
        fileManager: FileManager = .default)
        -> [String]
    {
        let home = fileManager.homeDirectoryForCurrentUser

        func homePath(_ relativePath: String) -> String {
            home.appendingPathComponent(relativePath, isDirectory: true).path
        }

        let candidates: [String] = switch provider {
        case .codex:
            [CodexHomeScope.ambientHomeURL(env: environment, fileManager: fileManager).path] +
                managedCodexAccounts.map(\.managedHomePath)
        case .claude:
            [
                homePath(".claude"),
                homePath(".config/claude"),
                home
                    .appendingPathComponent("Library/Application Support/CodexBar/ClaudeProbe", isDirectory: true)
                    .path,
            ]
        case .gemini:
            [
                homePath(".gemini"),
                homePath(".config/gemini"),
            ]
        case .opencode, .opencodego:
            [
                homePath(".config/opencode"),
            ]
        case .copilot:
            [
                homePath(".config/github-copilot"),
            ]
        default:
            []
        }

        return Self.uniqueStandardizedPaths(candidates)
    }

    private static func uniqueStandardizedPaths(_ paths: [String]) -> [String] {
        var seen: Set<String> = []
        var result: [String] = []
        for path in paths {
            let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let standardized = URL(fileURLWithPath: trimmed, isDirectory: true).standardizedFileURL.path
            guard seen.insert(standardized).inserted else { continue }
            result.append(standardized)
        }
        return result
    }
}

public struct ProviderStorageScanner: @unchecked Sendable {
    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    public func scan(
        provider: UsageProvider,
        candidatePaths: [String],
        now: Date = Date())
        -> ProviderStorageFootprint
    {
        var totalBytes: Int64 = 0
        var existingPaths: [String] = []
        var missingPaths: [String] = []
        var unreadablePaths: [String] = []
        var components: [ProviderStorageFootprint.Component] = []

        for path in candidatePaths {
            if Task.isCancelled { break }
            var isDirectory: ObjCBool = false
            guard self.fileManager.fileExists(atPath: path, isDirectory: &isDirectory) else {
                missingPaths.append(path)
                continue
            }

            existingPaths.append(path)
            let url = URL(fileURLWithPath: path, isDirectory: isDirectory.boolValue)
            let result = self.sizeOfItem(at: url)
            if Task.isCancelled { break }
            totalBytes += result.bytes
            unreadablePaths.append(contentsOf: result.unreadablePaths)
            components.append(contentsOf: self.components(for: url, isDirectory: isDirectory.boolValue))
        }

        return ProviderStorageFootprint(
            provider: provider,
            totalBytes: totalBytes,
            paths: existingPaths,
            missingPaths: missingPaths,
            unreadablePaths: unreadablePaths,
            components: components.sorted { lhs, rhs in
                if lhs.totalBytes == rhs.totalBytes {
                    return lhs.path.localizedCaseInsensitiveCompare(rhs.path) == .orderedAscending
                }
                return lhs.totalBytes > rhs.totalBytes
            },
            updatedAt: now)
    }

    private func components(for url: URL, isDirectory: Bool) -> [ProviderStorageFootprint.Component] {
        if Task.isCancelled { return [] }
        guard isDirectory else {
            let result = self.sizeOfItem(at: url)
            return result.bytes > 0 ? [.init(path: url.path, totalBytes: result.bytes)] : []
        }

        let keys: [URLResourceKey] = [
            .isDirectoryKey,
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .fileSizeKey,
        ]
        guard let children = try? self.fileManager.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: keys,
            options: [])
        else {
            return []
        }

        return children.compactMap { childURL in
            if Task.isCancelled { return nil }
            let result = self.sizeOfItem(at: childURL)
            guard result.bytes > 0 else { return nil }
            return ProviderStorageFootprint.Component(path: childURL.path, totalBytes: result.bytes)
        }
    }

    private func sizeOfItem(at url: URL) -> (bytes: Int64, unreadablePaths: [String]) {
        if Task.isCancelled { return (0, []) }
        let keys: Set<URLResourceKey> = [
            .isDirectoryKey,
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .fileSizeKey,
        ]

        guard let values = try? url.resourceValues(forKeys: keys) else {
            return (0, [url.path])
        }

        if values.isSymbolicLink == true {
            return (0, [])
        }

        if values.isRegularFile == true {
            return (Int64(values.fileSize ?? 0), [])
        }

        guard values.isDirectory == true else {
            return (0, [])
        }

        let unreadableCollector = ProviderStorageUnreadablePathCollector()
        guard let enumerator = self.fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsPackageDescendants],
            errorHandler: { url, _ in
                unreadableCollector.append(url.path)
                return true
            })
        else {
            return (0, [url.path])
        }

        var totalBytes: Int64 = 0
        for case let itemURL as URL in enumerator {
            if Task.isCancelled {
                enumerator.skipDescendants()
                break
            }
            guard let itemValues = try? itemURL.resourceValues(forKeys: keys) else {
                unreadableCollector.append(itemURL.path)
                continue
            }
            if itemValues.isSymbolicLink == true {
                if itemValues.isDirectory == true {
                    enumerator.skipDescendants()
                }
                continue
            }
            if itemValues.isRegularFile == true {
                totalBytes += Int64(itemValues.fileSize ?? 0)
            }
        }
        return (totalBytes, unreadableCollector.paths)
    }
}

private final class ProviderStorageUnreadablePathCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    var paths: [String] {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.storage
    }

    func append(_ path: String) {
        self.lock.lock()
        defer { self.lock.unlock() }
        self.storage.append(path)
    }
}
