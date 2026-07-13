import Foundation
#if os(macOS)
import SweetCookieKit
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
        let detailedUsageState: DeepSeekDetailedUsageState

        init(
            profiles: [DeepSeekPlatformProfile],
            selectedSummary: DeepSeekUsageSummary?,
            selectedBalance: DeepSeekUsageSnapshot? = nil,
            detailedUsageState: DeepSeekDetailedUsageState)
        {
            self.profiles = profiles
            self.selectedSummary = selectedSummary
            self.selectedBalance = selectedBalance
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
        let candidates = self.importTokens(browserDetection: browserDetection, logger: logger)
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
        logger: (@Sendable (String) -> Void)? = nil) -> [TokenInfo]
    {
        let log: (String) -> Void = { message in logger?("[deepseek-storage] \(message)") }
        let installedBrowsers = [Browser.chrome].browsersWithProfileData(using: browserDetection)
        let roots = ChromiumProfileLocator.roots(
            for: installedBrowsers,
            homeDirectories: BrowserCookieClient.defaultHomeDirectories())

        var results: [TokenInfo] = []
        for root in roots {
            guard !Task.isCancelled else { return results }
            for candidate in self.localStorageCandidates(
                root: root.url,
                browserID: root.browser.rawValue,
                labelPrefix: root.labelPrefix)
            {
                guard !Task.isCancelled else { return results }
                log("Checking \(candidate.id)")
                let entries = SweetCookieKit.ChromiumLocalStorageReader.readEntries(
                    for: "https://platform.deepseek.com",
                    in: candidate.url,
                    logger: log)
                guard let entry = entries.first(where: { $0.key == "userToken" }),
                      let token = self.extractUserToken(from: entry.value)
                else {
                    log("No DeepSeek userToken found in \(candidate.id)")
                    continue
                }

                log("Found DeepSeek platform token in \(candidate.id)")
                results.append(TokenInfo(id: candidate.id, token: token, sourceLabel: candidate.label))
            }
        }

        if results.isEmpty {
            log("No DeepSeek userToken found in Chrome local storage")
        }
        return results
    }

    private struct LocalStorageCandidate {
        let id: String
        let label: String
        let url: URL
    }

    private static func localStorageCandidates(
        root: URL,
        browserID: String,
        labelPrefix: String) -> [LocalStorageCandidate]
    {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles])
        else { return [] }

        let profileNames = self.chromeProfileNames(root: root)
        return entries.compactMap { directory in
            guard let isDirectory = try? directory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory,
                  isDirectory
            else { return nil }
            let name = directory.lastPathComponent
            guard name == "Default" || name.hasPrefix("Profile ") || name.hasPrefix("user-") else {
                return nil
            }
            let levelDB = directory.appendingPathComponent("Local Storage").appendingPathComponent("leveldb")
            guard FileManager.default.fileExists(atPath: levelDB.path) else { return nil }

            let displayName = profileNames[name]?.trimmingCharacters(in: .whitespacesAndNewlines)
            let label = if let displayName, !displayName.isEmpty, displayName != name {
                "\(labelPrefix) — \(displayName)"
            } else {
                "\(labelPrefix) \(name)"
            }
            return LocalStorageCandidate(
                id: "\(browserID):\(name)",
                label: label,
                url: levelDB)
        }
        .sorted { $0.label.localizedStandardCompare($1.label) == .orderedAscending }
    }

    private static func chromeProfileNames(root: URL) -> [String: String] {
        let localStateURL = root.appendingPathComponent("Local State")
        guard let data = try? Data(contentsOf: localStateURL),
              let rootObject = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let profile = rootObject["profile"] as? [String: Any],
              let infoCache = profile["info_cache"] as? [String: Any]
        else { return [:] }

        return infoCache.reduce(into: [:]) { result, entry in
            guard let info = entry.value as? [String: Any] else { return }
            let name = (info["gaia_given_name"] as? String) ?? (info["name"] as? String)
            guard let name else { return }
            result[entry.key] = name
        }
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

        var outcomes = await self.validate(
            candidates: candidatesToValidate,
            logger: logger,
            validate: validate)
        guard !Task.isCancelled else {
            return Resolution(profiles: [], selectedSummary: nil, detailedUsageState: .unavailable)
        }
        await self.record(outcomes: outcomes, cache: cache, now: now)

        var statusByID = self.resolvedStatuses(candidates: candidates, lookups: lookups, outcomes: outcomes)
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
                if case .unavailable = result.outcome { return true }
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
                detailedUsageState: sessionData.detailedUsageState)
        }
        return Resolution(profiles: profiles, selectedSummary: nil, detailedUsageState: .unavailable)
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
