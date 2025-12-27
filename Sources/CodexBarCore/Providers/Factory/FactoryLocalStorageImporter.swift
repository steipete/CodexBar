import Foundation

#if os(macOS)
enum FactoryLocalStorageImporter {
    struct TokenInfo: Sendable {
        let refreshToken: String
        let accessToken: String?
        let sourceLabel: String
    }

    static func importWorkOSTokens(logger: ((String) -> Void)? = nil) -> [TokenInfo] {
        let log: (String) -> Void = { msg in logger?("[factory-storage] \(msg)") }
        var tokens: [TokenInfo] = []

        for candidate in self.chromeLocalStorageCandidates() {
            guard let token = self.readWorkOSToken(from: candidate.levelDBURL) else { continue }
            log("Found WorkOS refresh token in \(candidate.label)")
            tokens.append(TokenInfo(
                refreshToken: token.refreshToken,
                accessToken: token.accessToken,
                sourceLabel: candidate.label))
        }

        if tokens.isEmpty {
            log("No WorkOS refresh token found in Chrome local storage")
        }

        return tokens
    }

    // MARK: - Chrome local storage discovery

    private struct LocalStorageCandidate: Sendable {
        let label: String
        let levelDBURL: URL
    }

    private static func chromeLocalStorageCandidates() -> [LocalStorageCandidate] {
        let roots: [(url: URL, labelPrefix: String)] = self.candidateHomes().flatMap { home in
            let appSupport = home
                .appendingPathComponent("Library")
                .appendingPathComponent("Application Support")
            return [
                (appSupport.appendingPathComponent("Google").appendingPathComponent("Chrome"), "Chrome"),
                (appSupport.appendingPathComponent("Google").appendingPathComponent("Chrome Beta"), "Chrome Beta"),
                (appSupport.appendingPathComponent("Google").appendingPathComponent("Chrome Canary"), "Chrome Canary"),
                (appSupport.appendingPathComponent("Arc").appendingPathComponent("User Data"), "Arc"),
                (appSupport.appendingPathComponent("Arc Beta").appendingPathComponent("User Data"), "Arc Beta"),
                (appSupport.appendingPathComponent("Arc Canary").appendingPathComponent("User Data"), "Arc Canary"),
                (
                    appSupport
                        .appendingPathComponent("com.openai.atlas")
                        .appendingPathComponent("browser-data")
                        .appendingPathComponent("host"),
                    "ChatGPT Atlas"),
                (appSupport.appendingPathComponent("Chromium"), "Chromium"),
            ]
        }

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
            return LocalStorageCandidate(label: label, levelDBURL: levelDBURL)
        }
    }

    private static func candidateHomes() -> [URL] {
        var homes: [URL] = []
        homes.append(FileManager.default.homeDirectoryForCurrentUser)
        if let userHome = NSHomeDirectoryForUser(NSUserName()) {
            homes.append(URL(fileURLWithPath: userHome))
        }
        if let envHome = ProcessInfo.processInfo.environment["HOME"], !envHome.isEmpty {
            homes.append(URL(fileURLWithPath: envHome))
        }
        var seen = Set<String>()
        return homes.filter { home in
            let path = home.path
            guard !seen.contains(path) else { return false }
            seen.insert(path)
            return true
        }
    }

    // MARK: - Token extraction

    private struct WorkOSTokenMatch: Sendable {
        let refreshToken: String
        let accessToken: String?
    }

    private static func readWorkOSToken(from levelDBURL: URL) -> WorkOSTokenMatch? {
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
            if let match = self.extractWorkOSToken(from: data) {
                return match
            }
        }
        return nil
    }

    private static func extractWorkOSToken(from data: Data) -> WorkOSTokenMatch? {
        guard let contents = String(data: data, encoding: .utf8) ??
            String(data: data, encoding: .isoLatin1)
        else { return nil }
        guard contents.contains("workos:refresh-token") else { return nil }

        let refreshToken = self.matchToken(
            in: contents,
            pattern: "workos:refresh-token[^A-Za-z0-9_-]*([A-Za-z0-9_-]{20,})")
        guard let refreshToken else { return nil }

        let accessToken = self.matchToken(
            in: contents,
            pattern: "workos:access-token[^A-Za-z0-9_-]*([A-Za-z0-9_-]{20,})")

        return WorkOSTokenMatch(refreshToken: refreshToken, accessToken: accessToken)
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
