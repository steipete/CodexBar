import Foundation
#if os(macOS)
import SweetCookieKit
#endif

#if os(macOS)
enum WindsurfDevinSessionImporter {
    #if DEBUG
    final class ImportSessionsOverrideStore: @unchecked Sendable {
        let importSessions: (BrowserDetection, ((String) -> Void)?) -> [SessionInfo]

        init(importSessions: @escaping (BrowserDetection, ((String) -> Void)?) -> [SessionInfo]) {
            self.importSessions = importSessions
        }
    }

    @TaskLocal private static var taskImportSessionsOverrideStore: ImportSessionsOverrideStore?
    @TaskLocal private static var taskImportPreferredSessionsOverrideStore: ImportSessionsOverrideStore?
    @TaskLocal private static var taskImportFallbackSessionsOverrideStore: ImportSessionsOverrideStore?

    static func withImportSessionsOverrideForTesting<T>(
        _ override: ((BrowserDetection, ((String) -> Void)?) -> [SessionInfo])?,
        operation: () async throws -> T) async rethrows -> T
    {
        try await self.$taskImportSessionsOverrideStore.withValue(override.map(ImportSessionsOverrideStore.init)) {
            try await operation()
        }
    }

    static func withImportPreferredSessionsOverrideForTesting<T>(
        _ override: ((BrowserDetection, ((String) -> Void)?) -> [SessionInfo])?,
        operation: () async throws -> T) async rethrows -> T
    {
        try await self.$taskImportPreferredSessionsOverrideStore.withValue(
            override.map(ImportSessionsOverrideStore.init))
        {
            try await operation()
        }
    }

    static func withImportFallbackSessionsOverrideForTesting<T>(
        _ override: ((BrowserDetection, ((String) -> Void)?) -> [SessionInfo])?,
        operation: () async throws -> T) async rethrows -> T
    {
        try await self.$taskImportFallbackSessionsOverrideStore.withValue(
            override.map(ImportSessionsOverrideStore.init))
        {
            try await operation()
        }
    }
    #endif
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
        logger: ((String) -> Void)? = nil,
        localStorage: BrowserLocalStorageAPI = .live) -> [SessionInfo]
    {
        #if DEBUG
        if let override = self.taskImportSessionsOverrideStore?.importSessions {
            return override(browserDetection, logger)
        }
        #endif

        let log: (String) -> Void = { msg in logger?("[windsurf-storage] \(msg)") }
        let preferredSessions = self.importSessions(
            browserDetection: browserDetection,
            browsers: self.defaultPreferredBrowsers,
            logger: log)
        if !preferredSessions.isEmpty {
            return preferredSessions
        }

        log("No Windsurf devin session found in Chrome; trying fallback Chromium browsers, then Firefox")
        let sessions = self.importFallbackStorageSessions(
            browserDetection: browserDetection,
            logger: log,
            localStorage: localStorage)

        if sessions.isEmpty {
            log("No Windsurf devin session found in browser local storage")
        }

        return sessions
    }

    static func importPreferredSessions(
        browserDetection: BrowserDetection,
        logger: ((String) -> Void)? = nil) -> [SessionInfo]
    {
        #if DEBUG
        if let override = self.taskImportPreferredSessionsOverrideStore?.importSessions {
            return override(browserDetection, logger)
        }
        #endif
        let log: (String) -> Void = { msg in logger?("[windsurf-storage] \(msg)") }
        return self.importSessions(
            browserDetection: browserDetection,
            browsers: self.defaultPreferredBrowsers,
            logger: log)
    }

    static func importFallbackSessions(
        browserDetection: BrowserDetection,
        logger: ((String) -> Void)? = nil,
        localStorage: BrowserLocalStorageAPI = .live) -> [SessionInfo]
    {
        #if DEBUG
        if let override = self.taskImportFallbackSessionsOverrideStore?.importSessions {
            return override(browserDetection, logger)
        }
        #endif
        let log: (String) -> Void = { msg in logger?("[windsurf-storage] \(msg)") }
        return self.importFallbackStorageSessions(
            browserDetection: browserDetection,
            logger: log,
            localStorage: localStorage)
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

    private static func importFallbackStorageSessions(
        browserDetection: BrowserDetection,
        logger: @escaping (String) -> Void,
        localStorage: BrowserLocalStorageAPI) -> [SessionInfo]
    {
        let chromiumSessions = self.importSessions(
            browserDetection: browserDetection,
            browsers: self.fallbackBrowsersExcluding(self.defaultPreferredBrowsers),
            logger: logger)
        return self.fallbackSessions(
            after: chromiumSessions,
            browserDetection: browserDetection,
            logger: logger,
            localStorage: localStorage)
    }

    private static func fallbackSessions(
        after chromiumSessions: [SessionInfo],
        browserDetection: BrowserDetection,
        logger: @escaping (String) -> Void,
        localStorage: BrowserLocalStorageAPI) -> [SessionInfo]
    {
        let firefoxSessions = self.importFirefoxSessions(
            browserDetection: browserDetection,
            logger: logger,
            localStorage: localStorage)
        return self.deduplicateSessions(chromiumSessions + firefoxSessions)
    }

    #if DEBUG
    static func _fallbackSessionsForTesting(
        chromiumSessions: [SessionInfo],
        browserDetection: BrowserDetection,
        localStorage: BrowserLocalStorageAPI) -> [SessionInfo]
    {
        self.fallbackSessions(
            after: chromiumSessions,
            browserDetection: browserDetection,
            logger: { _ in },
            localStorage: localStorage)
    }
    #endif

    private static func importFirefoxSessions(
        browserDetection: BrowserDetection,
        logger: @escaping (String) -> Void,
        localStorage: BrowserLocalStorageAPI = .live) -> [SessionInfo]
    {
        var sessions: [SessionInfo] = []
        for origin in self.localStorageOrigins {
            let profiles = localStorage.profiles(
                for: origin.absoluteString,
                browsers: [.firefox],
                using: browserDetection,
                logger: { _ in })
            for profile in profiles {
                var storage: [String: String] = [:]
                for entry in profile.entries where Self.targetKeys.contains(entry.key) && storage[entry.key] == nil {
                    storage[entry.key] = self.decodedStorageValue(entry.value)
                }
                guard let session = self.session(
                    from: storage,
                    sourceLabel: self.sourceLabel(profile.label, suffix: origin.host))
                else { continue }
                logger("Found Windsurf devin session in \(profile.id)")
                sessions.append(session)
            }
        }
        return self.deduplicateSessions(sessions)
    }

    private static func importSessions(
        browserDetection: BrowserDetection,
        browsers: [Browser],
        logger: @escaping (String) -> Void) -> [SessionInfo]
    {
        var sessions: [SessionInfo] = []
        let candidates = ChromiumLocalStorageDiscovery.candidates(
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
