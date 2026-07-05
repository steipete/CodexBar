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
        DeepSeekSessionAuthorization.authorizationHeader(from: storage)
    }

    static func bearer(from raw: String) -> String? {
        DeepSeekSessionAuthorization.bearer(from: raw)
    }

    static func looksLikeJWT(_ raw: String) -> Bool {
        DeepSeekSessionAuthorization.looksLikeJWT(raw)
    }

    static func looksLikeDeepSeekPlatformToken(_ raw: String) -> Bool {
        DeepSeekSessionAuthorization.looksLikeDeepSeekPlatformToken(raw)
    }

    static func looksLikeDeepSeekAuthorizationHeader(_ authorizationHeader: String) -> Bool {
        DeepSeekSessionAuthorization.looksLikeDeepSeekAuthorizationHeader(authorizationHeader)
    }

    static func looksLikeDeepSeekJWT(_ authorizationHeader: String) -> Bool {
        DeepSeekSessionAuthorization.looksLikeDeepSeekJWT(authorizationHeader)
    }

    static func sanitized(_ session: DeepSeekPlatformSession) -> DeepSeekPlatformSession {
        DeepSeekSessionAuthorization.sanitized(session)
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
}
#endif
