import Foundation
#if os(macOS)
import SweetCookieKit
#endif

#if os(macOS)
enum WindsurfFirebaseTokenImporter {
    struct TokenInfo {
        let refreshToken: String
        let accessToken: String?
        let sourceLabel: String
    }

    static func importFirebaseTokens(
        browserDetection: BrowserDetection,
        logger: ((String) -> Void)? = nil) -> [TokenInfo]
    {
        let log: (String) -> Void = { msg in logger?("[windsurf-firebase] \(msg)") }
        var tokens: [TokenInfo] = []

        let candidates = self.chromeIndexedDBCandidates(browserDetection: browserDetection)
        if !candidates.isEmpty {
            log("IndexedDB candidates: \(candidates.count)")
        }

        for candidate in candidates {
            let extracted = self.readFirebaseTokens(from: candidate.url, logger: log)
            for token in extracted {
                log("Found Firebase refresh token in \(candidate.label)")
                tokens.append(TokenInfo(
                    refreshToken: token.refreshToken,
                    accessToken: token.accessToken,
                    sourceLabel: candidate.label))
            }
        }

        if tokens.isEmpty {
            log("No Firebase refresh token found in browser IndexedDB")
        }

        return tokens
    }

    // MARK: - IndexedDB discovery (follows MiniMax chromeProfileIndexedDBDirs pattern)

    private struct IndexedDBCandidate {
        let label: String
        let url: URL
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
            .dia,
            .chatgptAtlas,
            .chromium,
            .helium,
        ]

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

    private static let indexedDBPrefix = "https_windsurf.com_"

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
                guard name.hasPrefix(self.indexedDBPrefix),
                      name.hasSuffix(".indexeddb.leveldb")
                else { continue }
                let label = "\(labelPrefix) \(dir.lastPathComponent)"
                candidates.append(IndexedDBCandidate(label: label, url: entry))
            }
        }
        return candidates
    }

    // MARK: - Token extraction (follows Factory readWorkOSToken pattern)

    private static func readFirebaseTokens(
        from levelDBURL: URL,
        logger: ((String) -> Void)? = nil) -> [TokenInfo]
    {
        // Try structured reading first via SweetCookieKit
        let textEntries = SweetCookieKit.ChromiumLocalStorageReader.readTextEntries(
            in: levelDBURL,
            logger: logger)
        var tokens: [TokenInfo] = []
        var seenRefresh = Set<String>()

        for entry in textEntries {
            if let token = self.extractFirebaseTokens(from: entry.value), !seenRefresh.contains(token.refreshToken) {
                seenRefresh.insert(token.refreshToken)
                tokens.append(token)
            }
        }

        if tokens.isEmpty {
            let rawCandidates = SweetCookieKit.ChromiumLocalStorageReader.readTokenCandidates(
                in: levelDBURL,
                minimumLength: 40,
                logger: logger)
            for candidate in rawCandidates {
                if let token = self.extractFirebaseTokens(from: candidate),
                   !seenRefresh.contains(token.refreshToken)
                {
                    seenRefresh.insert(token.refreshToken)
                    tokens.append(token)
                }
            }
        }

        // Fallback: scan raw .ldb/.log files (Factory readWorkOSToken pattern)
        if tokens.isEmpty {
            if let token = self.scanLevelDBFiles(at: levelDBURL) {
                tokens.append(token)
            }
        }

        return tokens
    }

    private static func scanLevelDBFiles(at levelDBURL: URL) -> TokenInfo? {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: levelDBURL,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles])
        else { return nil }

        let files = entries.filter { url in
            let ext = url.pathExtension.lowercased()
            return ext == "ldb" || ext == "log"
        }
        .sorted { lhs, rhs in
            let left = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
            let right = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
            return (left ?? .distantPast) > (right ?? .distantPast)
        }

        for file in files {
            guard let data = try? Data(contentsOf: file, options: [.mappedIfSafe]) else { continue }
            guard let contents = String(data: data, encoding: .utf8) ??
                String(data: data, encoding: .isoLatin1)
            else { continue }
            if let token = self.extractFirebaseTokens(from: contents) {
                return token
            }
        }
        return nil
    }

    private static func extractFirebaseTokens(from value: String) -> TokenInfo? {
        // Firebase refresh tokens start with AMf-vB (Google Identity Toolkit)
        let refreshToken = self.matchToken(
            in: value,
            pattern: #"refreshToken.{1,20}(AMf-vB[A-Za-z0-9_-]{20,})"#)
            ?? self.matchToken(
                in: value,
                pattern: #"refresh_token.{1,20}(AMf-vB[A-Za-z0-9_-]{20,})"#)
            ?? self.matchToken(
                in: value,
                pattern: #"(AMf-vB[A-Za-z0-9_-]{40,})"#)

        guard let refreshToken else { return nil }

        // Firebase access tokens are JWTs (eyJ...)
        let accessToken = self.matchToken(
            in: value,
            pattern: #"accessToken.{1,20}(eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+)"#)
            ?? self.matchToken(
                in: value,
                pattern: #"access_token.{1,20}(eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+)"#)

        return TokenInfo(refreshToken: refreshToken, accessToken: accessToken, sourceLabel: "browser")
    }

    private static func matchToken(in contents: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return nil }
        let range = NSRange(contents.startIndex..<contents.endIndex, in: contents)
        guard let match = regex.matches(in: contents, options: [], range: range).last else { return nil }
        guard match.numberOfRanges > 1,
              let tokenRange = Range(match.range(at: 1), in: contents)
        else { return nil }
        return String(contents[tokenRange])
    }
}
#endif
