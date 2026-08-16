import Foundation
#if os(macOS)
import SQLite3
#endif

enum DeepSeekPlatformTokenImporter {
    struct TokenInfo: Sendable, Equatable {
        let id: String
        let token: String
        let sourceLabel: String
    }

    struct Resolution: Sendable {
        let profiles: [DeepSeekPlatformProfile]
        let selectedSummary: DeepSeekUsageSummary?
        let selectedBalance: DeepSeekUsageSnapshot?
        let selectedProfileID: String?
        let detailedUsageState: DeepSeekDetailedUsageState

        init(
            profiles: [DeepSeekPlatformProfile],
            selectedSummary: DeepSeekUsageSummary?,
            selectedBalance: DeepSeekUsageSnapshot? = nil,
            selectedProfileID: String? = nil,
            detailedUsageState: DeepSeekDetailedUsageState)
        {
            self.profiles = profiles
            self.selectedSummary = selectedSummary
            self.selectedBalance = selectedBalance
            self.selectedProfileID = selectedProfileID
            self.detailedUsageState = detailedUsageState
        }
    }

    private struct PlatformSessionData: Sendable {
        let summary: DeepSeekUsageSummary?
        let balance: DeepSeekUsageSnapshot?
        let detailedUsageState: DeepSeekDetailedUsageState
    }

    private enum ValidationOutcome: Sendable {
        case valid(PlatformSessionData)
        case invalid
        case unavailable
    }

    private struct ValidationResult: Sendable {
        let candidate: TokenInfo
        let outcome: ValidationOutcome

        var isValid: Bool {
            if case .valid = self.outcome {
                return true
            }
            return false
        }
    }

    private static let validationCache = DeepSeekPlatformValidationCache()

    static func resolveAutomaticSession(
        selectedProfileID: String?,
        requiresExplicitSelection: Bool = false,
        includePlatformBalance: Bool = false,
        includeOptionalUsage: Bool = true,
        browserDetection: BrowserDetection,
        logger: (@Sendable (String) -> Void)? = nil) async -> Resolution
    {
        #if os(macOS)
        let includeSafari = selectedProfileID?.hasPrefix("safari:") ?? false
        let candidates = self.importTokens(
            browserDetection: browserDetection,
            includeSafari: includeSafari,
            logger: logger)
        guard !Task.isCancelled else {
            return Resolution(profiles: [], selectedSummary: nil, detailedUsageState: .unavailable)
        }
        return await self.resolve(
            candidates: candidates,
            selection: DeepSeekSettingsReader.ProfileSelection(
                profileID: selectedProfileID,
                requiresExplicitSelection: requiresExplicitSelection),
            logger: logger,
            cache: self.validationCache,
            validate: { token in
                if includePlatformBalance {
                    let snapshot = try await DeepSeekUsageFetcher.fetchPlatformUsage(
                        platformToken: token,
                        includeOptionalUsage: includeOptionalUsage)
                    return PlatformSessionData(
                        summary: snapshot.usageSummary,
                        balance: snapshot,
                        detailedUsageState: snapshot.detailedUsageState)
                }
                return try await PlatformSessionData(
                    summary: DeepSeekUsageFetcher.fetchUsageSummary(platformToken: token),
                    balance: nil,
                    detailedUsageState: .available)
            })
        #else
        _ = selectedProfileID
        _ = requiresExplicitSelection
        _ = includePlatformBalance
        _ = includeOptionalUsage
        _ = browserDetection
        _ = logger
        return Resolution(profiles: [], selectedSummary: nil, detailedUsageState: .webSessionRequired)
        #endif
    }

    #if os(macOS)
    static func importTokens(
        browserDetection: BrowserDetection,
        includeSafari: Bool = false,
        logger: (@Sendable (String) -> Void)? = nil,
        localStorage: BrowserLocalStorageAPI = .live) -> [TokenInfo]
    {
        let log: @Sendable (String) -> Void = { message in logger?("[deepseek-storage] \(message)") }

        // Safari's protected container is only read when the user explicitly
        // selected a Safari profile; routine refreshes stay Chrome-only.
        let safariTokens = includeSafari ? Self.importSafariTokens(logger: log) : []
        let chromeTokens = Self.importChromiumTokens(
            browserDetection: browserDetection,
            logger: log,
            localStorage: localStorage)

        var results: [TokenInfo] = []
        results.append(contentsOf: safariTokens)
        results.append(contentsOf: chromeTokens)

        if results.isEmpty {
            log("No DeepSeek userToken found in browser local storage")
        }
        return results
    }

    private static func importChromiumTokens(
        browserDetection: BrowserDetection,
        logger: @escaping @Sendable (String) -> Void,
        localStorage: BrowserLocalStorageAPI) -> [TokenInfo]
    {
        let profiles = localStorage.profiles(
            for: "https://platform.deepseek.com",
            browsers: [.chrome],
            using: browserDetection,
            logger: logger)

        var results: [TokenInfo] = []
        for profile in profiles {
            guard !Task.isCancelled else { return results }
            guard let entry = profile.entries.first(where: { $0.key == "userToken" }),
                  let token = self.extractUserToken(from: entry.value)
            else {
                logger("No DeepSeek userToken found in \(profile.id)")
                continue
            }

            logger("Found DeepSeek platform token in \(profile.id)")
            results.append(TokenInfo(id: profile.id, token: token, sourceLabel: profile.label))
        }
        return results
    }

    /// Reads the DeepSeek `userToken` from Safari's WebKit local storage
    /// (WebsiteData/Default/<origin>/LocalStorage/localstorage.sqlite3).
    private static func importSafariTokens(
        logger: (@Sendable (String) -> Void)? = nil) -> [TokenInfo]
    {
        let log: (String) -> Void = { msg in logger?("[deepseek-safari] \(msg)") }
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library")
            .appendingPathComponent("Containers")
            .appendingPathComponent("com.apple.Safari")
            .appendingPathComponent("Data")
            .appendingPathComponent("Library")
            .appendingPathComponent("WebKit")
            .appendingPathComponent("WebsiteData")
            .appendingPathComponent("Default")

        guard FileManager.default.fileExists(atPath: root.path),
              let enumerator = FileManager.default.enumerator(
                  at: root,
                  includingPropertiesForKeys: [.isRegularFileKey],
                  options: [.skipsHiddenFiles])
        else {
            return []
        }

        var results: [TokenInfo] = []
        for case let fileURL as URL in enumerator {
            guard !Task.isCancelled else { return results }
            guard fileURL.lastPathComponent == "origin" else { continue }
            guard (try? fileURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
                continue
            }
            guard let data = try? Data(contentsOf: fileURL, options: [.mappedIfSafe]) else { continue }
            let ascii = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""
            guard ascii.contains("platform.deepseek.com") || ascii.contains("deepseek.com") else {
                continue
            }

            let storageURL = fileURL.deletingLastPathComponent()
                .appendingPathComponent("LocalStorage")
                .appendingPathComponent("localstorage.sqlite3")
            guard FileManager.default.fileExists(atPath: storageURL.path) else { continue }
            guard let token = self.readUserTokenFromSafariSQLite(dbURL: storageURL, logger: log) else {
                log("No DeepSeek userToken in Safari storage \(storageURL.path)")
                continue
            }
            let host = self.safariOriginHost(from: ascii) ?? "platform.deepseek.com"
            log("Found DeepSeek platform token in Safari (\(host))")
            results.append(TokenInfo(id: "safari:\(host)", token: token, sourceLabel: "Safari (\(host))"))
        }
        return results
    }

    private static func safariOriginHost(from ascii: String) -> String? {
        let targets = ["platform.deepseek.com", "deepseek.com"]
        for host in targets where ascii.contains(host) {
            return host
        }
        return nil
    }

    private static func readUserTokenFromSafariSQLite(
        dbURL: URL,
        logger: ((String) -> Void)? = nil) -> String?
    {
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbURL.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            if let c = sqlite3_errmsg(db) {
                logger?("Safari local storage open failed: \(String(cString: c))")
            }
            return nil
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 250)

        let tables = Self.safariTableNames(db: db, logger: logger)
        let table = tables.contains("ItemTable") ? "ItemTable"
            : (tables.contains("localstorage") ? "localstorage" : nil)
        guard let table else {
            logger?("Safari local storage missing ItemTable/localstorage tables (found: \(tables.sorted()))")
            return nil
        }

        let token = Self.safariLocalStorageValue(db: db, table: table, key: "userToken")
        guard let token, !token.isEmpty else {
            logger?("Safari local storage missing userToken")
            return nil
        }
        return self.extractUserToken(from: token)
    }

    private static func safariTableNames(db: OpaquePointer?, logger: ((String) -> Void)? = nil) -> Set<String> {
        let sql = "SELECT name FROM sqlite_master WHERE type='table'"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            if let c = sqlite3_errmsg(db) {
                logger?("Safari local storage table query failed: \(String(cString: c))")
            }
            return []
        }
        defer { sqlite3_finalize(stmt) }
        var names = Set<String>()
        while true {
            let step = sqlite3_step(stmt)
            if step == SQLITE_ROW {
                if let c = sqlite3_column_text(stmt, 0) {
                    names.insert(String(cString: c))
                }
            } else {
                if step != SQLITE_DONE, let c = sqlite3_errmsg(db) {
                    logger?("Safari local storage table query failed: \(String(cString: c))")
                }
                break
            }
        }
        return names
    }

    private static func safariLocalStorageValue(db: OpaquePointer?, table: String, key: String) -> String? {
        let sql = "SELECT value FROM \(table) WHERE key = ? LIMIT 1"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        _ = key.withCString { cString in
            sqlite3_bind_text(stmt, 1, cString, -1, transient)
        }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return Self.safariSQLiteValue(stmt: stmt, index: 0)
    }

    private static func safariSQLiteValue(stmt: OpaquePointer?, index: Int32) -> String? {
        let type = sqlite3_column_type(stmt, index)
        switch type {
        case SQLITE_TEXT:
            guard let c = sqlite3_column_text(stmt, index) else { return nil }
            return String(cString: c)
        case SQLITE_BLOB:
            guard let bytes = sqlite3_column_blob(stmt, index) else { return nil }
            let count = Int(sqlite3_column_bytes(stmt, index))
            return Self.safariValueData(Data(bytes: bytes, count: count))
        default:
            return nil
        }
    }

    private static func safariValueData(_ data: Data) -> String? {
        if let decoded = String(data: data, encoding: .utf16LittleEndian) {
            return decoded.trimmingCharacters(in: .controlCharacters)
        }
        if let decoded = String(data: data, encoding: .utf8) {
            return decoded.trimmingCharacters(in: .controlCharacters)
        }
        if let decoded = String(data: data, encoding: .isoLatin1) {
            return decoded.trimmingCharacters(in: .controlCharacters)
        }
        return nil
    }

    #endif

    private static func resolve(
        candidates: [TokenInfo],
        selection: DeepSeekSettingsReader.ProfileSelection,
        logger: (@Sendable (String) -> Void)?,
        cache: DeepSeekPlatformValidationCache,
        validate: @escaping @Sendable (String) async throws -> PlatformSessionData) async -> Resolution
    {
        guard !Task.isCancelled else {
            return Resolution(profiles: [], selectedSummary: nil, detailedUsageState: .unavailable)
        }
        guard !candidates.isEmpty else {
            return Resolution(profiles: [], selectedSummary: nil, detailedUsageState: .webSessionRequired)
        }

        let now = Date()
        var lookups: [String: DeepSeekPlatformValidationCache.Lookup] = [:]
        var candidatesToValidate: [TokenInfo] = []
        for candidate in candidates {
            guard !Task.isCancelled else {
                return Resolution(profiles: [], selectedSummary: nil, detailedUsageState: .unavailable)
            }
            let lookup = await cache.lookup(candidate: candidate, now: now)
            lookups[candidate.id] = lookup
            if lookup.freshStatus == nil || candidate.id == selection.profileID {
                candidatesToValidate.append(candidate)
            }
        }

        var outcomes: [ValidationResult] = []
        var deferredCandidates: [TokenInfo] = []
        if let selectedProfileID = selection.profileID,
           let selectedCandidate = candidatesToValidate.first(where: { $0.id == selectedProfileID })
        {
            let selectedOutcome = await self.validate(
                candidates: [selectedCandidate],
                logger: logger,
                validate: validate)
            outcomes.append(contentsOf: selectedOutcome)
            candidatesToValidate.removeAll { $0.id == selectedProfileID }

            if !Task.isCancelled, selectedOutcome.contains(where: \.isValid) {
                // The selected session is required; catalog refreshes are best-effort and must not delay it.
                self.validateInBackground(
                    candidates: candidatesToValidate,
                    logger: logger,
                    cache: cache,
                    validate: validate)
                deferredCandidates = candidatesToValidate
                candidatesToValidate = []
            }
        }

        let remainingOutcomes = await self.validate(
            candidates: candidatesToValidate,
            logger: logger,
            validate: validate)
        outcomes.append(contentsOf: remainingOutcomes)
        guard !Task.isCancelled else {
            return Resolution(profiles: [], selectedSummary: nil, detailedUsageState: .unavailable)
        }
        await self.record(outcomes: outcomes, cache: cache, now: now)

        var statusByID = self.resolvedStatuses(candidates: candidates, lookups: lookups, outcomes: outcomes)
        for candidate in deferredCandidates {
            if let lastKnownStatus = lookups[candidate.id]?.lastKnownStatus {
                statusByID[candidate.id] = lastKnownStatus
            }
        }
        var validCandidates = candidates.filter { statusByID[$0.id] == true }
        var sessionDataByID = self.sessionDataByID(outcomes: outcomes)

        if validCandidates.count == 1, sessionDataByID[validCandidates[0].id] == nil {
            let candidate = validCandidates[0]
            let refresh = await self.validate(candidates: [candidate], logger: logger, validate: validate)
            await self.record(outcomes: refresh, cache: cache, now: now)
            outcomes.append(contentsOf: refresh)
            statusByID = self.resolvedStatuses(candidates: candidates, lookups: lookups, outcomes: outcomes)
            validCandidates = candidates.filter { statusByID[$0.id] == true }
            sessionDataByID = self.sessionDataByID(outcomes: outcomes)
        }

        let profiles = validCandidates.map { DeepSeekPlatformProfile(id: $0.id, name: $0.sourceLabel) }
        guard !validCandidates.isEmpty else {
            let validationWasUnavailable = outcomes.contains { result in
                if case .unavailable = result.outcome {
                    return true
                }
                return false
            }
            return Resolution(
                profiles: [],
                selectedSummary: nil,
                detailedUsageState: validationWasUnavailable ? .unavailable : .webSessionRequired)
        }

        let selected: TokenInfo? = if selection.requiresExplicitSelection {
            nil
        } else if let selectedProfileID = selection.profileID {
            validCandidates.first(where: { $0.id == selectedProfileID })
        } else {
            validCandidates.count == 1 ? validCandidates[0] : nil
        }
        guard let selected else {
            return Resolution(
                profiles: profiles,
                selectedSummary: nil,
                detailedUsageState: .profileSelectionRequired)
        }

        if let sessionData = sessionDataByID[selected.id] {
            return Resolution(
                profiles: profiles,
                selectedSummary: sessionData.summary,
                selectedBalance: sessionData.balance,
                selectedProfileID: selected.id,
                detailedUsageState: sessionData.detailedUsageState)
        }
        return Resolution(
            profiles: profiles,
            selectedSummary: nil,
            selectedProfileID: selected.id,
            detailedUsageState: .unavailable)
    }

    private static func validate(
        candidates: [TokenInfo],
        logger: (@Sendable (String) -> Void)?,
        validate: @escaping @Sendable (String) async throws -> PlatformSessionData) async -> [ValidationResult]
    {
        let results = await withTaskGroup(of: ValidationResult.self, returning: [ValidationResult].self) { group in
            for candidate in candidates {
                group.addTask {
                    guard !Task.isCancelled else {
                        return ValidationResult(candidate: candidate, outcome: .unavailable)
                    }
                    do {
                        let summary = try await validate(candidate.token)
                        return ValidationResult(candidate: candidate, outcome: .valid(summary))
                    } catch DeepSeekUsageError.invalidPlatformToken {
                        return ValidationResult(candidate: candidate, outcome: .invalid)
                    } catch {
                        return ValidationResult(candidate: candidate, outcome: .unavailable)
                    }
                }
            }

            var results: [ValidationResult] = []
            for await result in group {
                results.append(result)
            }
            return results
        }
        for result in results {
            switch result.outcome {
            case .valid:
                logger?("[deepseek-storage] Validated \(result.candidate.id)")
            case .invalid:
                logger?("[deepseek-storage] Rejected expired session for \(result.candidate.id)")
            case .unavailable:
                logger?("[deepseek-storage] Could not validate \(result.candidate.id)")
            }
        }
        return results
    }

    private static func validateInBackground(
        candidates: [TokenInfo],
        logger: (@Sendable (String) -> Void)?,
        cache: DeepSeekPlatformValidationCache,
        validate: @escaping @Sendable (String) async throws -> PlatformSessionData)
    {
        guard !candidates.isEmpty else { return }
        Task(priority: .utility) {
            let outcomes = await self.validate(candidates: candidates, logger: logger, validate: validate)
            await self.record(outcomes: outcomes, cache: cache, now: Date())
        }
    }

    private static func resolvedStatuses(
        candidates: [TokenInfo],
        lookups: [String: DeepSeekPlatformValidationCache.Lookup],
        outcomes: [ValidationResult]) -> [String: Bool]
    {
        var statusByID = Dictionary(uniqueKeysWithValues: candidates.compactMap { candidate in
            lookups[candidate.id]?.freshStatus.map { (candidate.id, $0) }
        })
        for result in outcomes {
            switch result.outcome {
            case .valid:
                statusByID[result.candidate.id] = true
            case .invalid:
                statusByID[result.candidate.id] = false
            case .unavailable:
                if let lastKnownStatus = lookups[result.candidate.id]?.lastKnownStatus {
                    statusByID[result.candidate.id] = lastKnownStatus
                }
            }
        }
        return statusByID
    }

    private static func sessionDataByID(outcomes: [ValidationResult]) -> [String: PlatformSessionData] {
        var sessionData: [String: PlatformSessionData] = [:]
        for result in outcomes {
            guard case let .valid(value) = result.outcome else { continue }
            sessionData[result.candidate.id] = value
        }
        return sessionData
    }

    private static func record(
        outcomes: [ValidationResult],
        cache: DeepSeekPlatformValidationCache,
        now: Date) async
    {
        for result in outcomes {
            switch result.outcome {
            case .valid:
                await cache.record(candidate: result.candidate, status: true, now: now)
            case .invalid:
                await cache.record(candidate: result.candidate, status: false, now: now)
            case .unavailable:
                break
            }
        }
    }

    private static func extractUserToken(from rawValue: String) -> String? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let data = trimmed.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data)
        {
            return self.token(fromJSONObject: object)
        }

        let unquoted: String = if (trimmed.hasPrefix("\"") && trimmed.hasSuffix("\"")) ||
            (trimmed.hasPrefix("'") && trimmed.hasSuffix("'"))
        {
            String(trimmed.dropFirst().dropLast())
        } else {
            trimmed
        }
        return self.isPlausibleToken(unquoted) ? unquoted : nil
    }

    private static func token(fromJSONObject value: Any) -> String? {
        if let string = value as? String {
            return self.isPlausibleToken(string) ? string : nil
        }
        guard let dictionary = value as? [String: Any] else { return nil }
        for key in ["value", "token", "access_token", "accessToken", "userToken"] {
            guard let token = dictionary[key] as? String, self.isPlausibleToken(token) else { continue }
            return token
        }
        return nil
    }

    private static func isPlausibleToken(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count >= 20 && !trimmed.contains(where: \.isWhitespace)
    }

    static func _extractUserTokenForTesting(_ rawValue: String) -> String? {
        self.extractUserToken(from: rawValue)
    }

    static func _resolveForTesting(
        candidates: [TokenInfo],
        selectedProfileID: String?,
        requiresExplicitSelection: Bool = false,
        detailedUsageState: DeepSeekDetailedUsageState = .available,
        cache: DeepSeekPlatformValidationCache? = nil,
        validate: @escaping @Sendable (String) async throws -> DeepSeekUsageSummary) async -> Resolution
    {
        await self.resolve(
            candidates: candidates,
            selection: DeepSeekSettingsReader.ProfileSelection(
                profileID: selectedProfileID,
                requiresExplicitSelection: requiresExplicitSelection),
            logger: nil,
            cache: cache ?? DeepSeekPlatformValidationCache(validityTTL: 0),
            validate: { token in
                try await PlatformSessionData(
                    summary: validate(token),
                    balance: nil,
                    detailedUsageState: detailedUsageState)
            })
    }
}

actor DeepSeekPlatformValidationCache {
    struct Lookup: Sendable {
        let freshStatus: Bool?
        let lastKnownStatus: Bool?
    }

    private struct Entry: Sendable {
        let token: String
        let status: Bool
        let checkedAt: Date
    }

    private let validityTTL: TimeInterval
    private var entries: [String: Entry] = [:]

    init(validityTTL: TimeInterval = 30 * 60) {
        self.validityTTL = validityTTL
    }

    func lookup(candidate: DeepSeekPlatformTokenImporter.TokenInfo, now: Date) -> Lookup {
        guard let entry = self.entries[candidate.id], entry.token == candidate.token else {
            return Lookup(freshStatus: nil, lastKnownStatus: nil)
        }
        let isFresh = now.timeIntervalSince(entry.checkedAt) < self.validityTTL
        return Lookup(
            freshStatus: isFresh ? entry.status : nil,
            lastKnownStatus: entry.status)
    }

    func record(candidate: DeepSeekPlatformTokenImporter.TokenInfo, status: Bool, now: Date) {
        self.entries[candidate.id] = Entry(token: candidate.token, status: status, checkedAt: now)
    }
}
