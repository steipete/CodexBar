import Foundation
#if os(macOS)
import SweetCookieKit
#endif

#if os(macOS)
enum DevinSessionImporter {
    #if DEBUG
    final class ImportSessionOverrideStore: @unchecked Sendable {
        let importSession: (BrowserDetection, String?, ((String) -> Void)?) -> SessionInfo?

        init(importSession: @escaping (BrowserDetection, String?, ((String) -> Void)?) -> SessionInfo?) {
            self.importSession = importSession
        }
    }

    @TaskLocal private static var taskImportSessionOverrideStore: ImportSessionOverrideStore?

    static func withImportSessionOverrideForTesting<T>(
        _ override: ((BrowserDetection, String?, ((String) -> Void)?) -> SessionInfo?)?,
        operation: () async throws -> T) async rethrows -> T
    {
        try await self.$taskImportSessionOverrideStore.withValue(override.map(ImportSessionOverrideStore.init)) {
            try await operation()
        }
    }
    #endif

    private static let storageOrigin = "https://app.devin.ai"
    private static let externalOrgPrefix = "last-internal-org-for-external-org-v1-"

    struct SessionInfo: Equatable {
        let accessToken: String
        let organization: String?
        let internalOrganizationID: String?
        let sourceLabel: String
    }

    static func importSessions(
        browserDetection: BrowserDetection,
        candidates: [ChromiumLocalStorageDiscovery.Candidate]? = nil,
        organizationOverride: String? = nil,
        logger: ((String) -> Void)? = nil) throws -> [SessionInfo]
    {
        #if DEBUG
        if let override = self.taskImportSessionOverrideStore?.importSession {
            return override(browserDetection, organizationOverride, logger).map { [$0] } ?? []
        }
        #endif

        let log: (String) -> Void = { msg in logger?("[devin-storage] \(msg)") }
        let candidates = candidates ?? ChromiumLocalStorageDiscovery
            .candidates(browsers: self.localStorageBrowsers(browserDetection: browserDetection))
        if !candidates.isEmpty {
            log("Chrome local storage candidates: \(candidates.count)")
        }

        var sessions: [SessionInfo] = []
        var unreadableStorage = false
        for candidate in candidates {
            let storage: [String: String]
            do {
                storage = try self.readLocalStorage(from: candidate.url, logger: log)
            } catch {
                unreadableStorage = true
                log("Could not read Chrome local storage in \(candidate.label)")
                continue
            }
            guard let session = self.session(
                from: storage,
                organizationOverride: organizationOverride,
                sourceLabel: candidate.label)
            else {
                continue
            }
            log(
                "Found Devin session in \(candidate.label); " +
                    "organization=\(session.organization != nil), internalOrganizationID=" +
                    "\(session.internalOrganizationID != nil)")
            sessions.append(session)
        }
        sessions = self.rankSessions(self.deduplicateSessions(sessions))

        if sessions.isEmpty {
            if unreadableStorage { throw DevinUsageError.browserStorageUnreadable }
            log("No Devin session found in browser local storage")
        }
        return sessions
    }

    static func session(
        from storage: [String: String],
        organizationOverride: String? = nil,
        sourceLabel: String) -> SessionInfo?
    {
        guard let accessToken = self.accessToken(from: storage) else {
            return nil
        }
        let organizationInfo = self.organizationInfo(from: storage, organizationOverride: organizationOverride)
        return SessionInfo(
            accessToken: accessToken,
            organization: organizationInfo.organization,
            internalOrganizationID: organizationInfo.internalOrganizationID,
            sourceLabel: sourceLabel)
    }

    static func accessToken(from storage: [String: String]) -> String? {
        func firstToken(matching matches: (String) -> Bool, parse: (Any) -> String?) -> String? {
            for (key, value) in storage where matches(key) {
                if let json = self.jsonObject(from: value), let token = parse(json) {
                    return token
                }
            }
            return nil
        }
        return firstToken(matching: self.isAuth1StorageKey, parse: self.findAuth1Token)
            ?? firstToken(matching: self.isAuth0StorageKey, parse: self.findAccessToken)
            ?? firstToken(matching: { _ in true }, parse: self.findAccessToken)
    }

    static func deduplicateSessions(_ sessions: [SessionInfo]) -> [SessionInfo] {
        var order: [String] = []
        var bestByToken: [String: SessionInfo] = [:]
        for session in sessions {
            if let existing = bestByToken[session.accessToken] {
                if self.organizationScore(session) > self.organizationScore(existing) {
                    bestByToken[session.accessToken] = session
                }
            } else {
                order.append(session.accessToken)
                bestByToken[session.accessToken] = session
            }
        }
        return order.compactMap { bestByToken[$0] }
    }

    static func rankSessions(_ sessions: [SessionInfo]) -> [SessionInfo] {
        sessions.enumerated()
            .sorted { lhs, rhs in
                let lhsScore = self.organizationScore(lhs.element)
                let rhsScore = self.organizationScore(rhs.element)
                return lhsScore == rhsScore ? lhs.offset < rhs.offset : lhsScore > rhsScore
            }
            .map(\.element)
    }

    private static func organizationScore(_ session: SessionInfo) -> Int {
        (session.organization == nil ? 0 : 1) + (session.internalOrganizationID == nil ? 0 : 2)
    }

    static func organizationInfo(
        from storage: [String: String],
        organizationOverride: String?) -> (organization: String?, internalOrganizationID: String?)
    {
        let override = DevinUsageFetcher.normalizedOrganization(organizationOverride)
        if let override, let internalOrgID = self.orgID(fromNormalizedOrganization: override) {
            return (override, internalOrgID)
        }
        let overrideSlug = override.flatMap(self.slug(fromNormalizedOrganization:))
        var firstInternalOrgID: String?

        for (key, value) in storage where self.isExternalOrgStorageKey(key) {
            let suffix = self.externalOrgSlug(from: key)
            let orgID = self.cleanedOrgID(value)
            if firstInternalOrgID == nil {
                firstInternalOrgID = orgID
            }
            if let overrideSlug, suffix == overrideSlug {
                return (override, orgID)
            }
            if override == nil, suffix != "null" {
                return ("org/\(suffix)", orgID)
            }
        }

        if let inferred = self.inferredOrganizationInfo(from: storage, override: override) {
            return inferred
        }

        if let override {
            return (override, nil)
        }

        return (firstInternalOrgID.map { "organizations/\($0)" }, firstInternalOrgID)
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

    static func localStorageBrowsers(browserDetection: BrowserDetection) -> [Browser] {
        let order = ProviderDefaults.metadata[.devin]?.browserCookieOrder ?? [.chrome]
        return order.browsersWithProfileData(using: browserDetection)
    }

    static func readLocalStorage(from levelDBURL: URL, logger: ((String) -> Void)? = nil) throws -> [String: String] {
        let entries = SweetCookieKit.ChromiumLocalStorageReader.readEntries(
            for: self.storageOrigin,
            in: levelDBURL,
            logger: logger)
        let textEntries = SweetCookieKit.ChromiumLocalStorageReader.readTextEntries(
            in: levelDBURL,
            logger: logger)
        let storage = self.localStorageValues(from: entries, textEntries: textEntries)
        if self.accessToken(from: storage) == nil {
            // The best-effort reader swallows I/O errors; distinguish an inaccessible store from a sign-out.
            let files = try FileManager.default.contentsOfDirectory(
                at: levelDBURL,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles])
            for file in files where ["ldb", "log"].contains(file.pathExtension.lowercased()) {
                let handle = try FileHandle(forReadingFrom: file)
                try handle.close()
            }
        }
        return storage
    }

    static func localStorageValues(
        from entries: [SweetCookieKit.ChromiumLocalStorageEntry],
        textEntries: [SweetCookieKit.ChromiumLevelDBTextEntry]) -> [String: String]
    {
        var storage: [String: String] = [:]
        for entry in entries {
            storage[entry.key] = self.decodedStorageValue(entry.value)
        }
        for entry in textEntries {
            guard let key = self.localStorageKey(fromRawKey: entry.key),
                  self.isUsefulStorageKey(key), storage[key] == nil
            else { continue }
            storage[key] = self.decodedStorageValue(entry.value)
        }

        return storage
    }

    private static func localStorageKey(fromRawKey raw: String) -> String? {
        guard let separator = raw.firstIndex(of: "\u{0000}") else { return nil }
        var origin = String(raw[..<separator])
        if origin.hasPrefix("_") { origin.removeFirst() }
        origin = String(origin.split(separator: "^", maxSplits: 1).first ?? "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard origin == self.storageOrigin || origin == "app.devin.ai" else { return nil }
        return String(raw[raw.index(after: separator)...]).trimmingCharacters(in: .controlCharacters)
    }

    private static func jsonObject(from raw: String) -> Any? {
        guard let data = raw.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }

    private static func findAuth1Token(in object: Any) -> String? {
        guard let dictionary = object as? [String: Any],
              let token = dictionary["token"] as? String
        else {
            return nil
        }
        let value = token.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.hasPrefix("auth1_") && value.count > 20 ? value : nil
    }

    private static func findAccessToken(in object: Any) -> String? {
        if let dictionary = object as? [String: Any] {
            for key in ["access_token", "accessToken"] {
                if let value = dictionary[key] as? String,
                   self.looksLikeToken(value)
                {
                    return value
                }
            }
            for value in dictionary.values {
                if let found = self.findAccessToken(in: value) {
                    return found
                }
            }
        }

        if let array = object as? [Any] {
            for value in array {
                if let found = self.findAccessToken(in: value) {
                    return found
                }
            }
        }

        return nil
    }

    private static func looksLikeToken(_ raw: String) -> Bool {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.count > 20 && (value.hasPrefix("eyJ") || value.contains("."))
    }

    private static func isAuth1StorageKey(_ key: String) -> Bool {
        key.hasSuffix("auth1_session")
    }

    private static func isAuth0StorageKey(_ key: String) -> Bool {
        key.contains("auth0spajs@@::")
    }

    private static func isExternalOrgStorageKey(_ key: String) -> Bool {
        key.contains(self.externalOrgPrefix)
    }

    private static func isUsefulStorageKey(_ key: String) -> Bool {
        self.isAuth1StorageKey(key) ||
            self.isAuth0StorageKey(key) ||
            self.isExternalOrgStorageKey(key) ||
            key.contains("post-auth-v") ||
            key.contains("member-info-v") ||
            key.contains("feature-flags-cache:org-") ||
            key.contains("feature-flags-cache:org_")
    }

    private static func inferredOrganizationInfo(
        from storage: [String: String],
        override: String?) -> (organization: String?, internalOrganizationID: String?)?
    {
        let overrideSlug = override.flatMap(self.slug(fromNormalizedOrganization:))
        let candidates = storage.keys.sorted().flatMap { key in
            self.organizationCandidates(
                in: storage[key].flatMap(self.jsonObject(from:)),
                keyContext: OrganizationCandidate(
                    slug: self.cleanedSlug(self.slugFromPostAuthKey(key)),
                    internalOrganizationID: self.internalOrgIDFromStorageKey(key)))
        }

        if let overrideSlug {
            let matching = candidates.filter { $0.slug == overrideSlug }
            if let candidate = matching.first(where: { $0.internalOrganizationID != nil }) ?? matching.first {
                return (override, candidate.internalOrganizationID)
            }
        }
        guard override == nil else { return nil }

        let candidate = candidates.first { $0.slug != nil && $0.internalOrganizationID != nil }
            ?? candidates.first { $0.slug != nil }
            ?? candidates.first
        if let slug = candidate?.slug {
            return ("org/\(slug)", candidate?.internalOrganizationID)
        }
        if let internalOrgID = candidate?.internalOrganizationID {
            return ("organizations/\(internalOrgID)", internalOrgID)
        }

        return nil
    }

    private static func externalOrgSlug(from key: String) -> String {
        guard let range = key.range(of: self.externalOrgPrefix) else { return key }
        return String(key[range.upperBound...])
    }

    private static func cleanedOrgID(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let value = self.decodedStorageValue(raw)
        guard DevinUsageFetcher.isInternalOrganizationID(value) else { return nil }
        return value
    }

    private static func cleanedSlug(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let value = self.decodedStorageValue(raw)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value != "null", !DevinUsageFetcher.isInternalOrganizationID(value) else {
            return nil
        }
        if value.hasPrefix("org/") {
            return String(value.dropFirst(4))
        }
        return value
    }

    private static func slugFromPostAuthKey(_ key: String) -> String? {
        guard let range = key.range(of: "-org_name-") else { return nil }
        return String(key[range.upperBound...])
    }

    private static func internalOrgIDFromStorageKey(_ key: String) -> String? {
        guard let range = key.range(of: #"org[-_][A-Za-z0-9]{8,}"#, options: .regularExpression) else {
            return nil
        }
        return self.cleanedOrgID(String(key[range]))
    }

    private struct OrganizationCandidate {
        let slug: String?
        let internalOrganizationID: String?

        var isEmpty: Bool {
            self.slug == nil && self.internalOrganizationID == nil
        }
    }

    private static func organizationCandidates(
        in object: Any?,
        keyContext: OrganizationCandidate? = nil) -> [OrganizationCandidate]
    {
        let dictionary = object as? [String: Any] ?? [:]
        let slug = ["orgName", "org_name", "externalOrgId", "external_org_id"]
            .compactMap { self.cleanedSlug(dictionary[$0] as? String) }.first
        let internalOrgID = ["internalOrgId", "internal_org_id", "org_id", "orgId"]
            .compactMap { self.cleanedOrgID(dictionary[$0] as? String) }.first
        let conflictsWithKey =
            (slug != nil && keyContext?.slug != nil && slug != keyContext?.slug) ||
            (internalOrgID != nil && keyContext?.internalOrganizationID != nil &&
                internalOrgID != keyContext?.internalOrganizationID)
        let direct = OrganizationCandidate(
            slug: slug ?? (conflictsWithKey ? nil : keyContext?.slug),
            internalOrganizationID: internalOrgID ?? (conflictsWithKey ? nil : keyContext?.internalOrganizationID))
        var candidates = direct.isEmpty ? [] : [direct]
        if conflictsWithKey, let keyContext, !keyContext.isEmpty {
            candidates.append(keyContext)
        }

        // Child objects have their own organization identity; never complete a pair across records.
        let children = object as? [Any] ?? dictionary.keys.sorted().compactMap { dictionary[$0] }
        for child in children {
            candidates.append(contentsOf: self.organizationCandidates(in: child))
        }
        return candidates
    }

    private static func slug(fromNormalizedOrganization organization: String) -> String? {
        guard organization.hasPrefix("org/") else { return nil }
        return String(organization.dropFirst(4))
    }

    private static func orgID(fromNormalizedOrganization organization: String) -> String? {
        guard organization.hasPrefix("organizations/") else { return nil }
        return String(organization.dropFirst("organizations/".count))
    }
}
#endif
