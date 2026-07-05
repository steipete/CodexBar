import Foundation
#if os(macOS)
import SweetCookieKit
#endif

#if os(macOS)
enum DeepSeekLocalStorageImporter {
    struct AuthorizationInfo {
        let authorizationHeader: String
        let sourceLabel: String
    }

    private static let storageOrigins = [
        "https://platform.deepseek.com",
        "https://chat.deepseek.com",
    ]

    private static let storageTokenKeys = [
        "auth_token",
        "access_token",
        "accessToken",
        "token",
        "userToken",
        "platform_token",
    ]

    struct LocalStorageCandidate {
        let label: String
        let url: URL
    }

    nonisolated(unsafe) static var importAuthorizationHeadersOverrideForTesting:
        ((BrowserDetection, ((String) -> Void)?) -> [AuthorizationInfo])?

    static func importAuthorizationHeaders(
        browserDetection: BrowserDetection,
        logger: ((String) -> Void)? = nil) -> [AuthorizationInfo]
    {
        if let override = self.importAuthorizationHeadersOverrideForTesting {
            return override(browserDetection, logger)
        }

        let log: (String) -> Void = { msg in logger?("[deepseek-storage] \(msg)") }
        let candidates = self.chromeLocalStorageCandidates(browserDetection: browserDetection)
        if candidates.isEmpty {
            log("No Chrome local storage candidates")
            return []
        }
        log("Chrome local storage candidates: \(candidates.count)")

        var results: [AuthorizationInfo] = []
        for candidate in candidates {
            guard let authorizationHeader = self.readAuthorizationHeader(from: candidate.url, logger: log),
                  self.looksLikeDeepSeekAuthorizationHeader(authorizationHeader)
            else {
                continue
            }
            log("Found DeepSeek bearer token in \(candidate.label)")
            results.append(AuthorizationInfo(
                authorizationHeader: authorizationHeader,
                sourceLabel: candidate.label))
        }
        if results.isEmpty {
            log("No DeepSeek bearer token found in browser local storage")
        }
        return results
    }

    static func authorizationHeader(from storage: [String: String]) -> String? {
        for key in self.storageTokenKeys {
            guard let value = storage[key] else { continue }
            if let bearer = self.bearer(from: value), self.looksLikeDeepSeekAuthorizationHeader(bearer) {
                return bearer
            }
        }

        for (key, value) in storage where key.lowercased().contains("token") {
            guard let bearer = self.bearer(from: value),
                  self.looksLikeDeepSeekAuthorizationHeader(bearer) else { continue }
            return bearer
        }

        return nil
    }

    static func bearer(from raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.lowercased().hasPrefix("bearer ") {
            return trimmed
        }
        if self.looksLikeJWT(trimmed) {
            return "Bearer \(trimmed)"
        }
        if let json = self.jsonObject(from: trimmed) {
            if let value = json["value"] as? String, let bearer = self.bearer(from: value) {
                return bearer
            }
            for key in ["token", "access_token", "accessToken", "auth_token"] {
                if let value = json[key] as? String, let bearer = self.bearer(from: value) {
                    return bearer
                }
            }
        }
        if self.looksLikeDeepSeekPlatformToken(trimmed) {
            return "Bearer \(trimmed)"
        }
        return nil
    }

    static func looksLikeJWT(_ raw: String) -> Bool {
        let parts = raw.split(separator: ".")
        return parts.count == 3 && raw.hasPrefix("eyJ") && raw.count > 40
    }

    static func looksLikeDeepSeekPlatformToken(_ raw: String) -> Bool {
        let token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard token.count >= 40, !token.hasPrefix("eyJ") else { return false }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "+/=_-"))
        return token.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    static func looksLikeDeepSeekAuthorizationHeader(_ authorizationHeader: String) -> Bool {
        let token = authorizationHeader
            .replacingOccurrences(of: "Bearer ", with: "", options: [.caseInsensitive])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if self.looksLikeJWT(token) {
            return self.looksLikeDeepSeekJWT(authorizationHeader)
        }
        return self.looksLikeDeepSeekPlatformToken(token)
    }

    static func looksLikeDeepSeekJWT(_ authorizationHeader: String) -> Bool {
        let token = authorizationHeader
            .replacingOccurrences(of: "Bearer ", with: "", options: [.caseInsensitive])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard self.looksLikeJWT(token), let payload = self.jwtPayload(from: token) else { return false }

        if payload["firebase"] != nil { return false }
        if let aud = payload["aud"] as? String, aud == "writefull" { return false }
        if let type = payload["type"] as? String, type == "websocket" { return false }
        if let iss = payload["iss"] as? String,
           iss.contains("google") || iss.contains("firebase") || iss.contains("jetbrains")
        {
            return false
        }
        if let exp = payload["exp"] as? TimeInterval {
            guard exp > Date().timeIntervalSince1970 else { return false }
        } else if let exp = payload["exp"] as? Int {
            guard TimeInterval(exp) > Date().timeIntervalSince1970 else { return false }
        } else if let exp = payload["exp"] as? NSNumber {
            guard exp.doubleValue > Date().timeIntervalSince1970 else { return false }
        } else {
            return false
        }

        if let iss = payload["iss"] as? String {
            let lower = iss.lowercased()
            if lower.contains("openai") || lower.contains("google") || lower.contains("firebase")
                || lower.contains("jetbrains") || lower.contains("auth0")
            {
                return false
            }
        }

        return self.looksLikeDeepSeekIdentity(payload)
    }

    private static func looksLikeDeepSeekIdentity(_ payload: [String: Any]) -> Bool {
        if payload["openid"] != nil { return false }
        if payload["auth_provider"] != nil { return false }
        if payload["role"] != nil, payload["email"] == nil { return false }
        if let email = payload["email"] as? String, email.contains("@") {
            return true
        }
        if let sub = payload["sub"] as? String, !sub.isEmpty, sub.allSatisfy(\.isNumber) {
            return true
        }
        return false
    }

    static func sanitized(_ session: DeepSeekPlatformSession) -> DeepSeekPlatformSession {
        guard let authorizationHeader = session.authorizationHeader,
              !authorizationHeader.isEmpty
        else {
            return session
        }
        guard self.looksLikeDeepSeekAuthorizationHeader(authorizationHeader) else {
            return DeepSeekPlatformSession(
                cookieHeader: session.cookieHeader,
                authorizationHeader: nil)
        }
        return session
    }

    private static func chromeLocalStorageCandidates(browserDetection: BrowserDetection) -> [LocalStorageCandidate] {
        let order = ProviderDefaults.metadata[.deepseek]?.browserCookieOrder ?? Browser.defaultImportOrder
        let installedBrowsers = order.browsersWithProfileData(using: browserDetection)
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
            let label = dir.lastPathComponent == "Default"
                ? labelPrefix
                : "\(labelPrefix) (\(dir.lastPathComponent))"
            return LocalStorageCandidate(label: label, url: levelDBURL)
        }
    }

    private static func readAuthorizationHeader(
        from levelDBURL: URL,
        logger: @escaping (String) -> Void) -> String?
    {
        var storage: [String: String] = [:]
        for origin in self.storageOrigins {
            let entries = SweetCookieKit.ChromiumLocalStorageReader.readEntries(
                for: origin,
                in: levelDBURL,
                logger: logger)
            for entry in entries {
                storage[entry.key] = self.decodedStorageValue(entry.value)
            }
        }

        let textEntries = SweetCookieKit.ChromiumLocalStorageReader.readTextEntries(
            in: levelDBURL,
            logger: logger)
        for entry in textEntries where storage[entry.key] == nil {
            if entry.key.lowercased().contains("token") || entry.key == "auth_token" || entry.key == "userToken" {
                storage[entry.key] = self.decodedStorageValue(entry.value)
            }
        }

        if let bearer = self.authorizationHeader(from: storage) {
            return bearer
        }

        if !storage.isEmpty {
            let sample = storage.keys.sorted().prefix(8).joined(separator: ", ")
            logger("Local storage key sample: \(sample)")
        }
        return nil
    }

    private static func decodedStorageValue(_ raw: String) -> String {
        if raw.hasPrefix("\""), raw.hasSuffix("\""), raw.count >= 2 {
            return String(raw.dropFirst().dropLast())
        }
        return raw
    }

    private static func jsonObject(from raw: String) -> [String: Any]? {
        guard let data = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }
        return object
    }

    private static func jwtPayload(from token: String) -> [String: Any]? {
        let parts = token.split(separator: ".")
        guard parts.count == 3 else { return nil }
        var payload = String(parts[1])
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: payload.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }
        return object
    }

    private static func jwtExpiration(from authorizationHeader: String) -> TimeInterval? {
        let token = authorizationHeader
            .replacingOccurrences(of: "Bearer ", with: "", options: [.caseInsensitive])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let payload = self.jwtPayload(from: token) else { return nil }
        if let exp = payload["exp"] as? TimeInterval { return exp }
        if let exp = payload["exp"] as? Int { return TimeInterval(exp) }
        if let exp = payload["exp"] as? NSNumber { return exp.doubleValue }
        return nil
    }
}
#endif
