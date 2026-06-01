import Foundation
#if os(macOS)
import SweetCookieKit
#endif

#if os(macOS)
enum DevinSessionImporter {
    nonisolated(unsafe) static var importSessionOverrideForTesting:
        ((BrowserDetection, String?, ((String) -> Void)?) -> SessionInfo?)?

    private static let storageOrigin = "https://app.devin.ai"
    private static let externalOrgPrefix = "last-internal-org-for-external-org-v1-"
    private static let rawOrgSlugKey = "__codexbar_devin_org_slug"
    private static let rawInternalOrgIDKey = "__codexbar_devin_internal_org_id"
    private static let defaultBrowsers: [Browser] = [
        .brave,
        .chrome,
        .chromeBeta,
        .chromeCanary,
        .edge,
        .edgeBeta,
        .edgeCanary,
        .arc,
        .arcBeta,
        .arcCanary,
        .dia,
        .vivaldi,
        .chromium,
    ]

    struct SessionInfo: Equatable {
        let accessToken: String
        let refreshToken: String?
        let auth0: Auth0Session?
        let organization: String?
        let internalOrganizationID: String?
        let sourceLabel: String
    }

    struct Auth0Session: Equatable {
        let tokenEndpoint: URL
        let clientID: String
        let audience: String?
        let scope: String?
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
        if let override = self.importSessionOverrideForTesting {
            return override(browserDetection, organizationOverride, logger)
        }

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
        if let override = self.importSessionOverrideForTesting {
            return override(browserDetection, organizationOverride, logger).map { [$0] } ?? []
        }

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
            log("Found Devin session in \(candidate.label)")
            sessions.append(session)
        }

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
        guard let tokenInfo = self.auth0TokenInfo(from: storage) else {
            return nil
        }
        let organizationInfo = self.organizationInfo(from: storage, organizationOverride: organizationOverride)
        return SessionInfo(
            accessToken: tokenInfo.accessToken,
            refreshToken: tokenInfo.refreshToken,
            auth0: tokenInfo.auth0,
            organization: organizationInfo.organization,
            internalOrganizationID: organizationInfo.internalOrganizationID,
            sourceLabel: sourceLabel)
    }

    static func accessToken(from storage: [String: String]) -> String? {
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

    private struct Auth0TokenInfo {
        let accessToken: String
        let refreshToken: String?
        let auth0: Auth0Session?
    }

    private static func auth0TokenInfo(from storage: [String: String]) -> Auth0TokenInfo? {
        for (key, value) in storage where self.isAuth0StorageKey(key) {
            guard let json = self.jsonObject(from: value),
                  let accessToken = self.findAccessToken(in: json)
            else {
                continue
            }
            let refreshToken = self.findRefreshToken(in: json)
            return Auth0TokenInfo(
                accessToken: accessToken,
                refreshToken: refreshToken,
                auth0: self.auth0Session(fromKey: key, accessToken: accessToken))
        }

        for value in storage.values {
            guard let json = self.jsonObject(from: value),
                  let accessToken = self.findAccessToken(in: json)
            else {
                continue
            }
            return Auth0TokenInfo(
                accessToken: accessToken,
                refreshToken: self.findRefreshToken(in: json),
                auth0: self.auth0Session(fromKey: nil, accessToken: accessToken))
        }

        return nil
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
        let order = ProviderDefaults.metadata[.devin]?.browserCookieOrder ?? Browser.defaultImportOrder
        let browsers = order.cookieImportCandidates(using: browserDetection)
        let installedBrowsers = browsers.isEmpty
            ? self.defaultBrowsers.browsersWithProfileData(using: browserDetection)
            : browsers.browsersWithProfileData(using: browserDetection)
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

        let rawInfo = self.rawOrganizationInfo(from: levelDBURL)
        if let slug = rawInfo.slug, storage[self.rawOrgSlugKey] == nil {
            storage[self.rawOrgSlugKey] = slug
        }
        if let internalOrgID = rawInfo.internalOrgID, storage[self.rawInternalOrgIDKey] == nil {
            storage[self.rawInternalOrgIDKey] = internalOrgID
        }

        return storage
    }

    private static func jsonObject(from raw: String) -> Any? {
        guard let data = raw.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
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

    private static func findRefreshToken(in object: Any) -> String? {
        if let dictionary = object as? [String: Any] {
            if let value = dictionary["refresh_token"] as? String, self.looksLikeToken(value) {
                return value
            }
            for value in dictionary.values {
                if let found = self.findRefreshToken(in: value) {
                    return found
                }
            }
        }

        if let array = object as? [Any] {
            for value in array {
                if let found = self.findRefreshToken(in: value) {
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

    private static func isAuth0StorageKey(_ key: String) -> Bool {
        key.contains("auth0spajs@@::")
    }

    private static func isExternalOrgStorageKey(_ key: String) -> Bool {
        key.contains(self.externalOrgPrefix)
    }

    private static func isUsefulStorageKey(_ key: String) -> Bool {
        self.isAuth0StorageKey(key) ||
            self.isExternalOrgStorageKey(key) ||
            key.contains("post-auth-v") ||
            key.contains("member-info-v") ||
            key.contains("feature-flags-cache:org-")
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
                ?? (key == self.rawInternalOrgIDKey ? self.cleanedOrgID(value) : nil)
            let slug = self.cleanedSlug(
                (key == self.rawOrgSlugKey ? value : nil) ??
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

    private static func auth0Session(fromKey key: String?, accessToken: String) -> Auth0Session? {
        guard let issuer = self.jwtIssuer(accessToken),
              let tokenEndpoint = URL(string: issuer
                  .trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/oauth/token")
        else {
            return nil
        }

        let parts = key.flatMap(self.auth0CacheKeyParts)
        guard let clientID = parts?.clientID else { return nil }
        return Auth0Session(
            tokenEndpoint: tokenEndpoint,
            clientID: clientID,
            audience: parts?.audience == "default" ? nil : parts?.audience,
            scope: parts?.scope)
    }

    private static func auth0CacheKeyParts(_ raw: String) -> (clientID: String, audience: String?, scope: String?)? {
        guard let range = raw.range(of: "auth0spajs@@::") else { return nil }
        let key = raw[range.lowerBound...].trimmingCharacters(in: CharacterSet(charactersIn: "\u{0000}\u{0001}"))
        let parts = key.split(separator: "::", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 2, !parts[1].isEmpty else { return nil }
        return (
            clientID: parts[1],
            audience: parts.count >= 3 && !parts[2].isEmpty ? parts[2] : nil,
            scope: parts.count >= 4 && !parts[3].isEmpty ? parts[3] : nil)
    }

    private static func jwtIssuer(_ token: String) -> String? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2,
              let data = self.base64URLDecode(String(parts[1])),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let issuer = object["iss"] as? String,
              !issuer.isEmpty
        else {
            return nil
        }
        return issuer
    }

    private static func base64URLDecode(_ raw: String) -> Data? {
        var value = raw.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        let padding = (4 - value.count % 4) % 4
        value.append(String(repeating: "=", count: padding))
        return Data(base64Encoded: value)
    }

    private static func externalOrgSlug(from key: String) -> String {
        guard let range = key.range(of: self.externalOrgPrefix) else { return key }
        return String(key[range.upperBound...])
    }

    private static func cleanedOrgID(_ raw: String) -> String? {
        let value = self.decodedStorageValue(raw)
        guard value.hasPrefix("org-") else { return nil }
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
        guard !value.isEmpty, value != "null", !value.hasPrefix("org-") else { return nil }
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
        guard let range = key.range(of: "org-") else { return nil }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-"))
        let orgID = String(key[range.lowerBound...].prefix { character in
            character.unicodeScalars.allSatisfy { allowed.contains($0) }
        })
        return self.cleanedOrgID(orgID)
    }

    private static func rawOrganizationInfo(from levelDBURL: URL) -> (slug: String?, internalOrgID: String?) {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: levelDBURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles])
        else {
            return (nil, nil)
        }

        var slug: String?
        var internalOrgID: String?
        for entry in entries where entry.pathExtension == "ldb" || entry.pathExtension == "log" {
            guard let data = try? Data(contentsOf: entry) else { continue }
            guard let text = String(bytes: data, encoding: .utf8) else { continue }
            if slug == nil {
                slug = self.firstRawMatch(
                    in: text,
                    pattern: #"org_name-([A-Za-z0-9][A-Za-z0-9_-]*)"#)
                    ?? self.firstRawMatch(in: text, pattern: #""org_name"\s*:\s*"([^"]+)""#)
                    ?? self.firstRawMatch(in: text, pattern: #""orgName"\s*:\s*"([^"]+)""#)
            }
            if internalOrgID == nil {
                internalOrgID = self.cleanedOrgID(self.firstRawMatch(
                    in: text,
                    pattern: #"(org-[A-Za-z0-9]+)"#))
            }
            if slug != nil, internalOrgID != nil {
                break
            }
        }
        return (self.cleanedSlug(slug), internalOrgID)
    }

    private static func firstRawMatch(in text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              match.numberOfRanges >= 2,
              let matchRange = Range(match.range(at: 1), in: text)
        else {
            return nil
        }
        return String(text[matchRange])
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
