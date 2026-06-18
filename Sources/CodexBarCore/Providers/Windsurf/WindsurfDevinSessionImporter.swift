import Foundation
#if os(macOS)
import SweetCookieKit
#endif

#if os(macOS)
enum WindsurfDevinSessionImporter {
    nonisolated(unsafe) static var importSessionsOverrideForTesting:
        ((BrowserDetection, ((String) -> Void)?) -> [SessionInfo])?
    nonisolated(unsafe) static var importPreferredSessionsOverrideForTesting:
        ((BrowserDetection, ((String) -> Void)?) -> [SessionInfo])?
    nonisolated(unsafe) static var importFallbackSessionsOverrideForTesting:
        ((BrowserDetection, ((String) -> Void)?) -> [SessionInfo])?
    static let defaultPreferredBrowsers: [Browser] = [.chrome]
    static let fallbackBrowsers: [Browser] = [
        .chromeBeta,
        .chromeCanary,
        .edge,
        .edgeBeta,
        .edgeCanary,
        .brave,
        .braveBeta,
        .braveNightly,
        .vivaldi,
        .arc,
        .arcBeta,
        .arcCanary,
        .dia,
        .chatgptAtlas,
        .chromium,
        .helium,
    ]

    struct SessionInfo: Equatable {
        let session: WindsurfDevinSessionAuth
        let sourceLabel: String
    }

    static func importSessions(
        browserDetection: BrowserDetection,
        logger: ((String) -> Void)? = nil) -> [SessionInfo]
    {
        if let override = self.importSessionsOverrideForTesting {
            return override(browserDetection, logger)
        }

        let log: (String) -> Void = { msg in logger?("[windsurf-storage] \(msg)") }
        let preferredSessions = self.importSessions(
            browserDetection: browserDetection,
            browsers: self.defaultPreferredBrowsers,
            logger: log)
        if !preferredSessions.isEmpty {
            return preferredSessions
        }

        log("No Windsurf devin session found in Chrome; trying fallback Chromium browsers")
        let sessions = self.importSessions(
            browserDetection: browserDetection,
            browsers: self.fallbackBrowsersExcluding(self.defaultPreferredBrowsers),
            logger: log)

        if sessions.isEmpty {
            log("No Windsurf devin session found in browser local storage")
        }

        return sessions
    }

    static func importPreferredSessions(
        browserDetection: BrowserDetection,
        logger: ((String) -> Void)? = nil) -> [SessionInfo]
    {
        if let override = self.importPreferredSessionsOverrideForTesting {
            return override(browserDetection, logger)
        }
        let log: (String) -> Void = { msg in logger?("[windsurf-storage] \(msg)") }
        return self.importSessions(
            browserDetection: browserDetection,
            browsers: self.defaultPreferredBrowsers,
            logger: log)
    }

    static func importFallbackSessions(
        browserDetection: BrowserDetection,
        logger: ((String) -> Void)? = nil) -> [SessionInfo]
    {
        if let override = self.importFallbackSessionsOverrideForTesting {
            return override(browserDetection, logger)
        }
        let log: (String) -> Void = { msg in logger?("[windsurf-storage] \(msg)") }
        return self.importSessions(
            browserDetection: browserDetection,
            browsers: self.fallbackBrowsersExcluding(self.defaultPreferredBrowsers),
            logger: log)
    }

    static func fallbackBrowsersExcluding(_ preferredBrowsers: [Browser]) -> [Browser] {
        let preferred = Set(preferredBrowsers)
        return self.fallbackBrowsers.filter { !preferred.contains($0) }
    }

    static func deduplicateSessions(_ sessions: [SessionInfo]) -> [SessionInfo] {
        var deduplicated: [SessionInfo] = []
        var seenSessionTokens = Set<String>()

        for session in sessions {
            guard seenSessionTokens.insert(session.session.sessionToken).inserted else { continue }
            deduplicated.append(session)
        }

        return deduplicated
    }

    static func session(from storage: [String: String], sourceLabel: String) -> SessionInfo? {
        guard let sessionToken = storage["devin_session_token"],
              let auth1Token = storage["devin_auth1_token"],
              let accountID = storage["devin_account_id"],
              let primaryOrgID = storage["devin_primary_org_id"]
        else {
            return nil
        }

        return SessionInfo(
            session: WindsurfDevinSessionAuth(
                sessionToken: sessionToken,
                auth1Token: auth1Token,
                accountID: accountID,
                primaryOrgID: primaryOrgID),
            sourceLabel: sourceLabel)
    }

    static func decodedStorageValue(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }

        if let data = trimmed.data(using: .utf8),
           let decoded = try? JSONDecoder().decode(String.self, from: data)
        {
            return decoded.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    struct LocalStorageCandidate {
        let label: String
        let url: URL
    }

    struct LocalStorageSnapshot: Equatable {
        let storage: [String: String]
        let sourceSuffix: String?
    }

    typealias LocalStorageOriginEntries = (
        origin: URL,
        entries: [SweetCookieKit.ChromiumLocalStorageEntry])

    static let localStorageOrigins = [
        URL(string: "https://app.devin.ai")!,
        URL(string: "https://windsurf.com")!,
    ]

    private static func importSessions(
        browserDetection: BrowserDetection,
        browsers: [Browser],
        logger: @escaping (String) -> Void) -> [SessionInfo]
    {
        var sessions: [SessionInfo] = []
        let candidates = self.chromeLocalStorageCandidates(
            browserDetection: browserDetection,
            browsers: browsers)
        if !candidates.isEmpty {
            logger("Chrome local storage candidates: \(candidates.count)")
        }

        for candidate in candidates {
            let snapshots = self.readLocalStorageSnapshots(from: candidate.url, logger: logger)
            for snapshot in snapshots {
                let sourceLabel = self.sourceLabel(candidate.label, suffix: snapshot.sourceSuffix)
                guard let session = self.session(from: snapshot.storage, sourceLabel: sourceLabel) else { continue }
                logger("Found Windsurf devin session in \(sourceLabel)")
                sessions.append(session)
            }
        }

        return self.deduplicateSessions(sessions)
    }

    static func chromeLocalStorageCandidates(
        browserDetection: BrowserDetection,
        browsers: [Browser]) -> [LocalStorageCandidate]
    {
        let installedBrowsers = browsers.browsersWithProfileData(using: browserDetection)
        let roots = ChromiumProfileLocator
            .roots(for: installedBrowsers, homeDirectories: BrowserCookieClient.defaultHomeDirectories())
            .map { (url: $0.url, labelPrefix: $0.labelPrefix) }

        var candidates: [LocalStorageCandidate] = []
        for root in roots {
            candidates.append(contentsOf: self.chromeProfileLocalStorageDirs(
                root: root.url,
                labelPrefix: root.labelPrefix))
        }
        return candidates
    }

    private static func chromeProfileLocalStorageDirs(root: URL, labelPrefix: String) -> [LocalStorageCandidate] {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles])
        else { return [] }

        let profileDirs = entries.filter { url in
            guard let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory), isDir else {
                return false
            }
            let name = url.lastPathComponent
            return name == "Default" || name.hasPrefix("Profile ") || name.hasPrefix("user-")
        }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }

        return profileDirs.compactMap { dir in
            let levelDBURL = dir.appendingPathComponent("Local Storage").appendingPathComponent("leveldb")
            guard FileManager.default.fileExists(atPath: levelDBURL.path) else { return nil }
            let label = "\(labelPrefix) \(dir.lastPathComponent)"
            return LocalStorageCandidate(label: label, url: levelDBURL)
        }
    }

    private static func readLocalStorageSnapshots(
        from levelDBURL: URL,
        logger: ((String) -> Void)? = nil) -> [LocalStorageSnapshot]
    {
        let originEntries = Self.localStorageOrigins.map { origin in
            let entries = SweetCookieKit.ChromiumLocalStorageReader.readEntries(
                for: origin.absoluteString,
                in: levelDBURL,
                logger: logger)
            return (origin: origin, entries: entries)
        }

        let textEntries = SweetCookieKit.ChromiumLocalStorageReader.readTextEntries(
            in: levelDBURL,
            logger: logger)
        return self.localStorageSnapshots(from: originEntries, textEntries: textEntries)
    }

    static func localStorageSnapshots(
        from originEntries: [LocalStorageOriginEntries],
        textEntries: [SweetCookieKit.ChromiumLevelDBTextEntry]) -> [LocalStorageSnapshot]
    {
        var snapshots = self.localStorageSnapshots(from: originEntries)
        let textStorage = self.storage(from: textEntries)
        if textStorage.count == Self.targetKeys.count {
            snapshots.append(LocalStorageSnapshot(storage: textStorage, sourceSuffix: nil))
        }

        return snapshots
    }

    static func localStorageSnapshots(from originEntries: [LocalStorageOriginEntries]) -> [LocalStorageSnapshot] {
        originEntries.compactMap { originEntry in
            let storage = self.storage(from: originEntry.entries)
            guard storage.count == Self.targetKeys.count else { return nil }
            return LocalStorageSnapshot(
                storage: storage,
                sourceSuffix: originEntry.origin.host ?? originEntry.origin.absoluteString)
        }
    }

    private static func storage(
        from entries: [SweetCookieKit.ChromiumLocalStorageEntry]) -> [String: String]
    {
        var storage: [String: String] = [:]
        for entry in entries where storage[entry.key] == nil && Self.targetKeys.contains(entry.key) {
            storage[entry.key] = self.decodedStorageValue(entry.value)
        }
        return storage
    }

    private static func storage(
        from entries: [SweetCookieKit.ChromiumLevelDBTextEntry]) -> [String: String]
    {
        var storage: [String: String] = [:]
        for entry in entries {
            guard storage[entry.key] == nil, Self.targetKeys.contains(entry.key) else { continue }
            storage[entry.key] = self.decodedStorageValue(entry.value)
        }

        return storage
    }

    private static func sourceLabel(_ label: String, suffix: String?) -> String {
        guard let suffix else { return label }
        return "\(label) (\(suffix))"
    }

    private static let targetKeys: Set<String> = [
        "devin_session_token",
        "devin_auth1_token",
        "devin_account_id",
        "devin_primary_org_id",
    ]
}
#endif
