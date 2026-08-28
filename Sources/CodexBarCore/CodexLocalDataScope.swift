import Foundation

/// Resolves all local Codex sources as one scope. A managed Codex home must
/// never silently borrow an ambient state database or cache identity.
struct CodexLocalDataScope: Sendable, Equatable {
    let identifier: String
    let codexHome: URL
    let sessionsRoot: URL
    let archivedSessionsRoot: URL
    let stateDatabaseURL: URL

    static func resolve(options: CostUsageScanner.Options) -> CodexLocalDataScope {
        if let sessionsRoot = options.codexSessionsRoot?.standardizedFileURL,
           sessionsRoot.lastPathComponent == "sessions"
        {
            let home = sessionsRoot.deletingLastPathComponent()
            return self.make(home: home)
        }

        let environment = ProcessInfo.processInfo.environment
        if let sqliteHome = Self.nonEmpty(environment["CODEX_SQLITE_HOME"]) {
            let home = URL(fileURLWithPath: sqliteHome, isDirectory: true).standardizedFileURL
            return self.make(home: home)
        }
        if let codexHome = Self.nonEmpty(environment["CODEX_HOME"]) {
            let home = URL(fileURLWithPath: codexHome, isDirectory: true).standardizedFileURL
            return self.make(home: home)
        }
        return self.make(home: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex"))
    }

    func applying(to options: CostUsageScanner.Options) -> CostUsageScanner.Options {
        var copy = options
        copy.codexSessionsRoot = self.sessionsRoot
        copy.codexTraceDatabaseURL = copy.codexTraceDatabaseURL ?? self.stateDatabaseURL
        return copy
    }

    private static func make(home: URL) -> CodexLocalDataScope {
        let standardizedHome = home.standardizedFileURL
        return CodexLocalDataScope(
            identifier: "codex-workspaces:" + Self.scopeFingerprint(standardizedHome.path),
            codexHome: standardizedHome,
            sessionsRoot: standardizedHome.appendingPathComponent("sessions", isDirectory: true),
            archivedSessionsRoot: standardizedHome.appendingPathComponent("archived_sessions", isDirectory: true),
            stateDatabaseURL: standardizedHome.appendingPathComponent("state_5.sqlite", isDirectory: false))
    }

    /// Stable local identifier for cache partitioning. It is not a security
    /// primitive; it only prevents raw home paths from entering cache metadata.
    private static func scopeFingerprint(_ value: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }

    private static func nonEmpty(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }
}
