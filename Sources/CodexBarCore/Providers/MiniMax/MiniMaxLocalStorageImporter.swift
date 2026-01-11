import Foundation
#if os(macOS)
import SweetCookieKit
#endif

#if os(macOS)
enum MiniMaxLocalStorageImporter {
    struct TokenInfo: Sendable {
        let accessToken: String
        let groupID: String?
        let sourceLabel: String
    }

    static func importAccessTokens(
        browserDetection: BrowserDetection,
        logger: ((String) -> Void)? = nil) -> [TokenInfo]
    {
        let log: (String) -> Void = { msg in logger?("[minimax-storage] \(msg)") }
        var tokens: [TokenInfo] = []

        let chromeCandidates = self.chromeLocalStorageCandidates(browserDetection: browserDetection)
        if !chromeCandidates.isEmpty {
            log("Chrome local storage candidates: \(chromeCandidates.count)")
        }

        for candidate in chromeCandidates {
            guard case let .chromeLevelDB(levelDBURL) = candidate.kind else { continue }
            let snapshot = self.readLocalStorage(from: levelDBURL, logger: log)
            if !snapshot.tokens.isEmpty {
                let groupID = snapshot.groupID ?? self.groupID(fromJWT: snapshot.tokens.first ?? "")
                if groupID != nil {
                    log("Found MiniMax group id in \(candidate.label)")
                }
                for token in snapshot.tokens {
                    let hint = token.contains(".") ? "jwt" : "opaque"
                    log("Found MiniMax access token in \(candidate.label): \(token.count) chars (\(hint))")
                    tokens.append(TokenInfo(accessToken: token, groupID: groupID, sourceLabel: candidate.label))
                }
            }
        }

        if tokens.isEmpty {
            let sessionCandidates = self.chromeSessionStorageCandidates(browserDetection: browserDetection)
            if !sessionCandidates.isEmpty {
                log("Chrome session storage candidates: \(sessionCandidates.count)")
            }
            for candidate in sessionCandidates {
                let sessionTokens = self.readSessionStorageTokens(from: candidate.url, logger: log)
                guard !sessionTokens.isEmpty else { continue }
                for token in sessionTokens {
                    let hint = token.contains(".") ? "jwt" : "opaque"
                    log("Found MiniMax access token in \(candidate.label): \(token.count) chars (\(hint))")
                    let groupID = self.groupID(fromJWT: token)
                    tokens.append(TokenInfo(accessToken: token, groupID: groupID, sourceLabel: candidate.label))
                }
            }
        }

        if tokens.isEmpty {
            let indexedCandidates = self.chromeIndexedDBCandidates(browserDetection: browserDetection)
            if !indexedCandidates.isEmpty {
                log("Chrome IndexedDB candidates: \(indexedCandidates.count)")
            }
            for candidate in indexedCandidates {
                let indexedTokens = self.readIndexedDBTokens(from: candidate.url, logger: log)
                guard !indexedTokens.isEmpty else { continue }
                for token in indexedTokens {
                    let hint = token.contains(".") ? "jwt" : "opaque"
                    log("Found MiniMax access token in \(candidate.label): \(token.count) chars (\(hint))")
                    let groupID = self.groupID(fromJWT: token)
                    tokens.append(TokenInfo(accessToken: token, groupID: groupID, sourceLabel: candidate.label))
                }
            }
        }

        if tokens.isEmpty {
            log("No MiniMax access token found in browser storage")
        }

        return tokens
    }

    static func importGroupIDs(
        browserDetection: BrowserDetection,
        logger: ((String) -> Void)? = nil) -> [String: String]
    {
        let log: (String) -> Void = { msg in logger?("[minimax-storage] \(msg)") }
        var results: [String: String] = [:]

        let chromeCandidates = self.chromeLocalStorageCandidates(browserDetection: browserDetection)
        if !chromeCandidates.isEmpty {
            log("Chrome local storage candidates: \(chromeCandidates.count)")
        }

        for candidate in chromeCandidates {
            guard case let .chromeLevelDB(levelDBURL) = candidate.kind else { continue }
            let snapshot = self.readLocalStorage(from: levelDBURL, logger: log)
            if let groupID = snapshot.groupID, results[candidate.label] == nil {
                log("Found MiniMax group id in \(candidate.label)")
                results[candidate.label] = groupID
            }
        }

        return results
    }

    // MARK: - Chrome local storage discovery

    private enum LocalStorageSourceKind: Sendable {
        case chromeLevelDB(URL)
    }

    private struct LocalStorageCandidate: Sendable {
        let label: String
        let kind: LocalStorageSourceKind
    }

    private struct SessionStorageCandidate: Sendable {
        let label: String
        let url: URL
    }

    private struct IndexedDBCandidate: Sendable {
        let label: String
        let url: URL
    }

    private static func chromeLocalStorageCandidates(browserDetection: BrowserDetection) -> [LocalStorageCandidate] {
        let browsers: [Browser] = [
            .chrome,
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
            .chatgptAtlas,
            .chromium,
            .helium,
        ]

        // Filter to browsers with profile data to avoid unnecessary filesystem access
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
            return LocalStorageCandidate(label: label, kind: .chromeLevelDB(levelDBURL))
        }
    }

    private static func chromeSessionStorageCandidates(browserDetection: BrowserDetection)
    -> [SessionStorageCandidate] {
        let browsers: [Browser] = [
            .chrome,
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
            .chatgptAtlas,
            .chromium,
            .helium,
        ]

        // Filter to browsers with profile data to avoid unnecessary filesystem access
        let installedBrowsers = browsers.browsersWithProfileData(using: browserDetection)

        let roots = ChromiumProfileLocator
            .roots(for: installedBrowsers, homeDirectories: BrowserCookieClient.defaultHomeDirectories())
            .map { (url: $0.url, labelPrefix: $0.labelPrefix) }

        var candidates: [SessionStorageCandidate] = []
        for root in roots {
            candidates.append(contentsOf: self.chromeProfileSessionStorageDirs(
                root: root.url,
                labelPrefix: root.labelPrefix))
        }
        return candidates
    }

    private static func chromeProfileSessionStorageDirs(root: URL, labelPrefix: String) -> [SessionStorageCandidate] {
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
            let sessionURL = dir.appendingPathComponent("Session Storage")
            guard FileManager.default.fileExists(atPath: sessionURL.path) else { return nil }
            let label = "\(labelPrefix) \(dir.lastPathComponent) (Session Storage)"
            return SessionStorageCandidate(label: label, url: sessionURL)
        }
    }

    private static func chromeIndexedDBCandidates(browserDetection: BrowserDetection) -> [IndexedDBCandidate] {
        let browsers: [Browser] = [
            .chrome,
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
            .chatgptAtlas,
            .chromium,
            .helium,
        ]

        // Filter to browsers with profile data to avoid unnecessary filesystem access
        let installedBrowsers = browsers.browsersWithProfileData(using: browserDetection)

        let roots = ChromiumProfileLocator
            .roots(for: installedBrowsers, homeDirectories: BrowserCookieClient.defaultHomeDirectories())
            .map { (url: $0.url, labelPrefix: $0.labelPrefix) }

        var candidates: [IndexedDBCandidate] = []
        for root in roots {
            candidates.append(contentsOf: self.chromeProfileIndexedDBDirs(
                root: root.url,
                labelPrefix: root.labelPrefix))
        }
        return candidates
    }

    private static func chromeProfileIndexedDBDirs(root: URL, labelPrefix: String) -> [IndexedDBCandidate] {
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

        let targetPrefixes = [
            "https_platform.minimax.io_",
            "https_www.minimax.io_",
            "https_minimax.io_",
            "https_platform.minimaxi.com_",
            "https_minimaxi.com_",
            "https_www.minimaxi.com_",
        ]

        var candidates: [IndexedDBCandidate] = []
        for dir in profileDirs {
            let indexedDBRoot = dir.appendingPathComponent("IndexedDB")
            guard let dbEntries = try? FileManager.default.contentsOfDirectory(
                at: indexedDBRoot,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles])
            else { continue }
            for entry in dbEntries {
                guard let isDir = (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory), isDir else {
                    continue
                }
                let name = entry.lastPathComponent
                guard targetPrefixes.contains(where: { name.hasPrefix($0) }),
                      name.hasSuffix(".indexeddb.leveldb")
                else { continue }
                let label = "\(labelPrefix) \(dir.lastPathComponent) (IndexedDB)"
                candidates.append(IndexedDBCandidate(label: label, url: entry))
            }
        }
        return candidates
    }

    // MARK: - Token extraction

    private struct LocalStorageSnapshot: Sendable {
        let tokens: [String]
        let groupID: String?
    }

    private static func readLocalStorage(
        from levelDBURL: URL,
        logger: ((String) -> Void)? = nil) -> LocalStorageSnapshot
    {
        let origins = [
            "https://platform.minimax.io",
            "https://www.minimax.io",
            "https://minimax.io",
            "https://platform.minimaxi.com",
            "https://www.minimaxi.com",
            "https://minimaxi.com",
        ]
        var entries: [SweetCookieKit.ChromiumLocalStorageEntry] = []
        for origin in origins {
            entries.append(contentsOf: SweetCookieKit.ChromiumLocalStorageReader.readEntries(
                for: origin,
                in: levelDBURL,
                logger: logger))
        }

        var tokens: [String] = []
        var seen = Set<String>()
        var groupID: String?
        var hasMinimaxSignal = !entries.isEmpty

        for entry in entries {
            let extracted = self.extractAccessTokens(from: entry.value)
            for token in extracted where !seen.contains(token) {
                seen.insert(token)
                tokens.append(token)
            }
            if groupID == nil, let match = self.extractGroupID(from: entry.value) {
                groupID = match
            }
        }

        if tokens.isEmpty {
            let textEntries = SweetCookieKit.ChromiumLocalStorageReader.readTextEntries(
                in: levelDBURL,
                logger: logger)
            let candidateEntries = textEntries.filter { entry in
                let key = entry.key.lowercased()
                let value = entry.value.lowercased()
                return key.contains("minimax.io") || value.contains("minimax.io") ||
                    key.contains("minimaxi.com") || value.contains("minimaxi.com")
            }
            if !candidateEntries.isEmpty {
                logger?("[minimax-storage] Local storage text entries: \(candidateEntries.count)")
                hasMinimaxSignal = true
            }
            for entry in candidateEntries {
                let extracted = self.extractAccessTokens(from: entry.value)
                for token in extracted where !seen.contains(token) {
                    if token.contains("."), !self.isMiniMaxJWT(token) {
                        continue
                    }
                    seen.insert(token)
                    tokens.append(token)
                }
                if groupID == nil, let match = self.extractGroupID(from: entry.value) {
                    groupID = match
                }
            }
        }

        if tokens.isEmpty, hasMinimaxSignal {
            let rawCandidates = SweetCookieKit.ChromiumLocalStorageReader.readTokenCandidates(
                in: levelDBURL,
                minimumLength: 60,
                logger: logger)
            if !rawCandidates.isEmpty {
                logger?("[minimax-storage] Local storage raw token candidates: \(rawCandidates.count)")
            }
            for candidate in rawCandidates
                where self.looksLikeToken(candidate) && self.isMiniMaxJWT(candidate) && !seen.contains(candidate)
            {
                seen.insert(candidate)
                tokens.append(candidate)
                if groupID == nil {
                    groupID = self.groupID(fromJWT: candidate)
                }
            }
        }

        if tokens.isEmpty, !entries.isEmpty {
            let sample = entries.prefix(6).map { "\($0.key) (\($0.value.count) chars)" }
            logger?("[minimax-storage] Local storage key sample: \(sample.joined(separator: ", "))")
            for entry in entries
                where entry.key == "user_detail" || entry.key == "persist:root" || entry.key == "access_token"
            {
                let preview = entry.value.prefix(200)
                if entry.key == "access_token" {
                    logger?("[minimax-storage] \(entry.key) preview: \(preview) (raw \(entry.rawValueLength) bytes)")
                } else {
                    logger?("[minimax-storage] \(entry.key) preview: \(preview)")
                }
                if entry.key == "persist:root" {
                    self.logPersistRootKeys(entry.value, logger: logger)
                }
            }
        }

        return LocalStorageSnapshot(tokens: tokens, groupID: groupID)
    }

    private static func readSessionStorageTokens(
        from levelDBURL: URL,
        logger: ((String) -> Void)? = nil) -> [String]
    {
        let entries = SweetCookieKit.ChromiumLocalStorageReader.readTextEntries(
            in: levelDBURL,
            logger: logger)
        guard !entries.isEmpty else { return [] }

        let origins = [
            "https://platform.minimax.io",
            "https://www.minimax.io",
            "https://minimax.io",
            "https://platform.minimaxi.com",
            "https://www.minimaxi.com",
            "https://minimaxi.com",
        ]
        let mapIDs = self.sessionStorageMapIDs(in: entries, origins: origins, logger: logger)
        if mapIDs.isEmpty {
            logger?("[minimax-storage] No MiniMax session storage namespaces found")
            return []
        }

        let mapEntries = entries.filter { entry in
            guard let mapID = self.sessionStorageMapID(fromKey: entry.key) else { return false }
            return mapIDs.contains(mapID)
        }
        if mapEntries.isEmpty {
            logger?("[minimax-storage] No MiniMax session storage map entries found")
            return []
        }

        let tokenKeySample = mapEntries
            .filter { entry in
                entry.key.localizedCaseInsensitiveContains("token") ||
                    entry.key.localizedCaseInsensitiveContains("auth")
            }
            .prefix(8)
            .map(\.key)
        if !tokenKeySample.isEmpty {
            logger?("[minimax-storage] MiniMax session storage token keys: \(tokenKeySample.joined(separator: ", "))")
        }

        var tokens: [String] = []
        var seen = Set<String>()
        for entry in mapEntries {
            let extracted = self.extractAccessTokens(from: entry.value)
            for token in extracted where !seen.contains(token) {
                seen.insert(token)
                tokens.append(token)
            }
        }

        if tokens.isEmpty {
            let sample = mapEntries.prefix(8).map { entry in
                "\(entry.key) (\(entry.value.count) chars)"
            }
            logger?("[minimax-storage] MiniMax session storage sample: \(sample.joined(separator: ", "))")
        }

        return tokens
    }

    private static func readIndexedDBTokens(
        from levelDBURL: URL,
        logger: ((String) -> Void)? = nil) -> [String]
    {
        let entries = SweetCookieKit.ChromiumLocalStorageReader.readTextEntries(
            in: levelDBURL,
            logger: logger)
        var tokens: [String] = []
        var seen = Set<String>()
        if !entries.isEmpty {
            for entry in entries {
                let extracted = self.extractAccessTokens(from: entry.value)
                for token in extracted where !seen.contains(token) {
                    seen.insert(token)
                    tokens.append(token)
                }
            }
        }

        if tokens.isEmpty {
            let rawCandidates = SweetCookieKit.ChromiumLocalStorageReader.readTokenCandidates(
                in: levelDBURL,
                minimumLength: 60,
                logger: logger)
            if !rawCandidates.isEmpty {
                logger?("[minimax-storage] IndexedDB raw token candidates: \(rawCandidates.count)")
            }
            for candidate in rawCandidates where self.looksLikeToken(candidate) && !seen.contains(candidate) {
                seen.insert(candidate)
                tokens.append(candidate)
            }
        }

        if tokens.isEmpty {
            let sample = entries.prefix(8).map { entry in
                "\(entry.key) (\(entry.value.count) chars)"
            }
            if !sample.isEmpty {
                logger?("[minimax-storage] IndexedDB sample: \(sample.joined(separator: ", "))")
            }
        }
        return tokens
    }

    private static func sessionStorageMapIDs(
        in entries: [SweetCookieKit.ChromiumLevelDBTextEntry],
        origins: [String],
        logger: ((String) -> Void)? = nil) -> Set<Int>
    {
        var mapIDs = Set<Int>()
        for entry in entries where entry.key.hasPrefix("namespace-") {
            for origin in origins where entry.key.localizedCaseInsensitiveContains(origin) {
                if let mapID = self.sessionStorageMapID(fromValue: entry.value) {
                    mapIDs.insert(mapID)
                }
            }
        }
        if !mapIDs.isEmpty {
            let values = mapIDs.map(String.init).sorted().joined(separator: ", ")
            logger?("[minimax-storage] Session storage map ids for MiniMax: \(values)")
        }
        return mapIDs
    }

    private static func sessionStorageMapID(fromValue value: String) -> Int? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return Int(trimmed)
    }

    private static func sessionStorageMapID(fromKey key: String) -> Int? {
        guard key.hasPrefix("map-") else { return nil }
        let parts = key.split(separator: "-", maxSplits: 2)
        guard parts.count >= 2 else { return nil }
        return Int(parts[1])
    }

    private static func extractAccessTokens(from value: String) -> [String] {
        var tokens = Set<String>()

        let patterns = [
            #"access_token[^A-Za-z0-9._\-+=/]+([A-Za-z0-9._\-+=/]{20,})"#,
            #"accessToken[^A-Za-z0-9._\-+=/]+([A-Za-z0-9._\-+=/]{20,})"#,
            #"id_token[^A-Za-z0-9._\-+=/]+([A-Za-z0-9._\-+=/]{20,})"#,
            #"idToken[^A-Za-z0-9._\-+=/]+([A-Za-z0-9._\-+=/]{20,})"#,
        ]

        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { continue }
            let range = NSRange(value.startIndex..<value.endIndex, in: value)
            let matches = regex.matches(in: value, options: [], range: range)
            for match in matches {
                guard match.numberOfRanges > 1,
                      let tokenRange = Range(match.range(at: 1), in: value)
                else { continue }
                tokens.insert(String(value[tokenRange]))
            }
        }

        if let jsonTokens = self.extractTokensFromJSON(value) {
            tokens.formUnion(jsonTokens)
        }

        if let jwtMatches = self.matchJWTs(in: value) {
            tokens.formUnion(jwtMatches)
        }

        let preferred = tokens.filter { $0.count >= 60 }
        return preferred.isEmpty ? Array(tokens) : Array(preferred)
    }

    private static func extractTokensFromJSON(_ value: String) -> [String]? {
        guard let data = value.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data, options: [])
        else { return nil }
        return self.collectTokens(from: json)
    }

    private static func collectTokens(from value: Any) -> [String] {
        var tokens: [String] = []
        switch value {
        case let dict as [String: Any]:
            for (key, child) in dict {
                if self.tokenKeys.contains(key), let string = child as? String, self.looksLikeToken(string) {
                    tokens.append(string)
                } else {
                    tokens.append(contentsOf: self.collectTokens(from: child))
                }
            }
        case let array as [Any]:
            for child in array {
                tokens.append(contentsOf: self.collectTokens(from: child))
            }
        case let string as String:
            if self.looksLikeToken(string) {
                tokens.append(string)
            } else if let nested = self.extractTokensFromJSON(string) {
                tokens.append(contentsOf: nested)
            }
        default:
            break
        }
        return tokens
    }

    private static let tokenKeys: Set<String> = [
        "access_token",
        "accessToken",
        "id_token",
        "idToken",
        "token",
        "authToken",
        "authorization",
        "bearer",
    ]

    private static func looksLikeToken(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.contains("."), trimmed.split(separator: ".").count >= 3 {
            return trimmed.count >= 60
        }
        return trimmed.count >= 60 && trimmed.range(of: #"^[A-Za-z0-9._\-+=/]+$"#, options: .regularExpression) != nil
    }

    private static func logPersistRootKeys(_ value: String, logger: ((String) -> Void)?) {
        guard let data = value.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data, options: []),
              let root = json as? [String: Any]
        else { return }

        let rootKeys = root.keys.sorted()
        if !rootKeys.isEmpty {
            let sample = rootKeys.prefix(10).joined(separator: ", ")
            logger?("[minimax-storage] persist:root keys: \(sample)")
        }

        if let authString = root["auth"] as? String,
           let authData = authString.data(using: .utf8),
           let authJSON = try? JSONSerialization.jsonObject(with: authData, options: []),
           let auth = authJSON as? [String: Any]
        {
            let authKeys = auth.keys.sorted()
            if !authKeys.isEmpty {
                let sample = authKeys.prefix(10).joined(separator: ", ")
                logger?("[minimax-storage] persist:root auth keys: \(sample)")
            }
        }
    }

    private static func matchJWTs(in value: String) -> [String]? {
        let pattern = #"[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return nil }
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        let matches = regex.matches(in: value, options: [], range: range)
        guard !matches.isEmpty else { return nil }
        return matches.compactMap { match in
            guard let tokenRange = Range(match.range(at: 0), in: value) else { return nil }
            return String(value[tokenRange])
        }
    }

    private static func isMiniMaxJWT(_ token: String) -> Bool {
        guard let claims = self.decodeJWTClaims(token) else { return false }
        if let iss = claims["iss"] as? String, iss.localizedCaseInsensitiveContains("minimax") {
            return true
        }
        let signalKeys = [
            "GroupID",
            "GroupName",
            "UserName",
            "SubjectID",
            "Mail",
            "TokenType",
        ]
        if signalKeys.contains(where: { claims[$0] != nil }) {
            return true
        }
        return false
    }

    private static func extractGroupID(from value: String) -> String? {
        if let data = value.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data, options: []),
           let match = self.extractGroupID(from: json)
        {
            return match
        }

        let markers = [
            "groups\":[",
            "groupId\":\"",
            "group_id\":\"",
        ]
        for marker in markers {
            guard let range = value.range(of: marker) else { continue }
            let tail = value[range.upperBound...].prefix(200)
            if let match = self.longestDigitSequence(in: String(tail)) {
                return match
            }
        }
        return nil
    }

    private static func extractGroupID(from value: Any) -> String? {
        switch value {
        case let dict as [String: Any]:
            for (key, child) in dict {
                if key.lowercased().contains("group"),
                   let match = self.stringID(from: child)
                {
                    return match
                }
                if let nested = self.extractGroupID(from: child) {
                    return nested
                }
            }
        case let array as [Any]:
            for child in array {
                if let match = self.extractGroupID(from: child) {
                    return match
                }
            }
        default:
            break
        }
        return nil
    }

    private static func groupID(fromJWT token: String) -> String? {
        guard token.contains(".") else { return nil }
        guard let claims = self.decodeJWTClaims(token) else { return nil }

        let directKeys = [
            "group_id",
            "groupId",
            "groupID",
            "gid",
            "tenant_id",
            "tenantId",
            "org_id",
            "orgId",
        ]
        for key in directKeys {
            if let match = self.stringID(from: claims[key]) {
                return match
            }
        }

        for (key, value) in claims where key.lowercased().contains("group") {
            if let match = self.stringID(from: value) {
                return match
            }
        }

        return nil
    }

    private static func decodeJWTClaims(_ token: String) -> [String: Any]? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        let payload = String(parts[1])
        guard let data = self.base64URLDecode(payload) else { return nil }
        guard let object = try? JSONSerialization.jsonObject(with: data, options: []),
              let dict = object as? [String: Any]
        else { return nil }
        return dict
    }

    private static func base64URLDecode(_ value: String) -> Data? {
        var base64 = value.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let padding = (4 - base64.count % 4) % 4
        if padding > 0 {
            base64.append(String(repeating: "=", count: padding))
        }
        return Data(base64Encoded: base64)
    }

    private static func stringID(from value: Any?) -> String? {
        switch value {
        case let number as Int:
            return String(number)
        case let number as Int64:
            return String(number)
        case let number as NSNumber:
            return String(number.intValue)
        case let text as String:
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if let match = self.longestDigitSequence(in: trimmed) {
                return match
            }
            return trimmed.isEmpty ? nil : trimmed
        default:
            return nil
        }
    }

    private static func longestDigitSequence(in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: #"[0-9]{4,}"#, options: []) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        let matches = regex.matches(in: text, options: [], range: range)
        let candidates = matches.compactMap { match -> String? in
            guard let tokenRange = Range(match.range(at: 0), in: text) else { return nil }
            return String(text[tokenRange])
        }
        return candidates.max(by: { $0.count < $1.count })
    }
}
#endif
