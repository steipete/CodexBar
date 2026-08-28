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

    struct LocalStorageCandidate {
        let label: String
        let url: URL
    }

    static func importSession(
        browserDetection: BrowserDetection,
        organizationOverride: String? = nil,
        logger: ((String) -> Void)? = nil) -> SessionInfo?
    {
        #if DEBUG
        if let override = self.taskImportSessionOverrideStore?.importSession {
            return override(browserDetection, organizationOverride, logger)
        }
        #endif

        let sessions = self.importSessions(
            browserDetection: browserDetection,
            organizationOverride: organizationOverride,
            logger: logger)
        return sessions.first
    }

    static func importSessions(
        browserDetection: BrowserDetection,
        organizationOverride: String? = nil,
        logger: ((String) -> Void)? = nil) -> [SessionInfo]
    {
        #if DEBUG
        if let override = self.taskImportSessionOverrideStore?.importSession {
            return override(browserDetection, organizationOverride, logger).map { [$0] } ?? []
        }
        #endif

        let log: (String) -> Void = { msg in logger?("[devin-storage] \(msg)") }
        let candidates = self.chromeLocalStorageCandidates(browserDetection: browserDetection)
        if !candidates.isEmpty {
            log("Chrome local storage candidates: \(candidates.count)")
        }

        var sessions: [SessionInfo] = []
        for candidate in candidates {
            let storage = self.readLocalStorage(from: candidate.url, logger: log)
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
        for (key, value) in storage where self.isAuth1StorageKey(key) {
            guard let json = self.jsonObject(from: value),
                  let token = self.findAuth1Token(in: json)
            else {
                continue
            }
            return token
        }

        for (key, value) in storage where self.isAuth0StorageKey(key) {
            guard let json = self.jsonObject(from: value),
                  let token = self.findAccessToken(in: json)
            else {
                continue
            }
            return token
        }

        for value in storage.values {
            guard let json = self.jsonObject(from: value),
                  let token = self.findAccessToken(in: json)
            else {
                continue
            }
            return token
        }

        return nil
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
            return (override, firstInternalOrgID ?? self.orgID(fromNormalizedOrganization: override))
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

    static func chromeLocalStorageCandidates(browserDetection: BrowserDetection) -> [LocalStorageCandidate] {
        let installedBrowsers = self.localStorageBrowsers(browserDetection: browserDetection)
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

    static func localStorageBrowsers(browserDetection: BrowserDetection) -> [Browser] {
        let order = ProviderDefaults.metadata[.devin]?.browserCookieOrder ?? [.chrome]
        return order.browsersWithProfileData(using: browserDetection)
    }

    private static func chromeProfileLocalStorageDirs(root: URL, labelPrefix: String) -> [LocalStorageCandidate] {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles])
        else { return [] }

        return entries.filter { url in
            guard let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory), isDir else {
                return false
            }
            let name = url.lastPathComponent
            return name == "Default" || name.hasPrefix("Profile ") || name.hasPrefix("user-")
        }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
        .compactMap { dir in
            let levelDBURL = dir.appendingPathComponent("Local Storage").appendingPathComponent("leveldb")
            guard FileManager.default.fileExists(atPath: levelDBURL.path) else { return nil }
            return LocalStorageCandidate(label: "\(labelPrefix) \(dir.lastPathComponent)", url: levelDBURL)
        }
    }

    private static func readLocalStorage(from levelDBURL: URL, logger: ((String) -> Void)?) -> [String: String] {
        var storage: [String: String] = [:]
        let entries = SweetCookieKit.ChromiumLocalStorageReader.readEntries(
            for: self.storageOrigin,
            in: levelDBURL,
            logger: logger)
        for entry in entries {
            storage[entry.key] = self.decodedStorageValue(entry.value)
        }

        let textEntries = SweetCookieKit.ChromiumLocalStorageReader.readTextEntries(
            in: levelDBURL,
            logger: logger)
        for entry in textEntries where storage[entry.key] == nil {
            if self.isUsefulStorageKey(entry.key) {
                storage[entry.key] = self.decodedStorageValue(entry.value)
            }
        }

        return storage
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
        let overrideOrgID = override.flatMap(self.orgID(fromNormalizedOrganization:))
        var fallbackSlug: String?
        var fallbackInternalOrgID: String?

        for (key, value) in storage {
            let object = self.jsonObject(from: value)
            let internalOrgID = self.cleanedOrgID(self.firstString(
                in: object,
                matching: ["internalOrgId", "internal_org_id", "org_id", "orgId"]))
                ?? self.internalOrgIDFromStorageKey(key)
            let slug = self.cleanedSlug(
                self.slugFromPostAuthKey(key) ??
                    self.firstString(in: object, matching: ["orgName", "org_name", "externalOrgId", "external_org_id"]))

            if let overrideOrgID, internalOrgID == overrideOrgID {
                return (override, internalOrgID)
            }
            if let overrideSlug, slug == overrideSlug {
                return (override, internalOrgID)
            }

            if fallbackSlug == nil, let slug {
                fallbackSlug = slug
            }
            if fallbackInternalOrgID == nil, let internalOrgID {
                fallbackInternalOrgID = internalOrgID
            }
        }

        if let override, fallbackInternalOrgID != nil {
            return (override, fallbackInternalOrgID)
        }

        if let fallbackSlug {
            return ("org/\(fallbackSlug)", fallbackInternalOrgID)
        }
        if let fallbackInternalOrgID {
            return ("organizations/\(fallbackInternalOrgID)", fallbackInternalOrgID)
        }

        return nil
    }

    private static func externalOrgSlug(from key: String) -> String {
        guard let range = key.range(of: self.externalOrgPrefix) else { return key }
        return String(key[range.upperBound...])
    }

    private static func cleanedOrgID(_ raw: String) -> String? {
        let value = self.decodedStorageValue(raw)
        guard DevinUsageFetcher.isInternalOrganizationID(value) else { return nil }
        return value
    }

    private static func cleanedOrgID(_ raw: String?) -> String? {
        guard let raw else { return nil }
        return self.cleanedOrgID(raw)
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

    private static func firstString(in object: Any?, matching keys: Set<String>) -> String? {
        if let dictionary = object as? [String: Any] {
            for (key, value) in dictionary {
                if keys.contains(key), let string = value as? String, !string.isEmpty {
                    return string
                }
                if let found = self.firstString(in: value, matching: keys) {
                    return found
                }
            }
        }

        if let array = object as? [Any] {
            for value in array {
                if let found = self.firstString(in: value, matching: keys) {
                    return found
                }
            }
        }

        return nil
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
