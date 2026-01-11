import Foundation
import SweetCookieKit

#if os(macOS)

extension ClaudeWebAPIFetcher {
    // MARK: - Session Key Extraction

    struct CookieStoreCandidate: Hashable, Sendable {
        let engine: ClaudeBrowserEngine
        let browserID: String
        let browserName: String
        let bundleIDs: [String]
        let profileName: String?
        let kind: BrowserCookieStoreKind
        let url: URL
        let label: String
    }

    static func _cookieStoreCandidatesForTesting(
        catalog: ClaudeBrowserCatalog,
        homeDirectories: [URL],
        logger: ((String) -> Void)? = nil) -> [CookieStoreCandidate]
    {
        let reporter = CookieExtractionReporter(logger: logger)
        return Self.cookieStoreCandidates(
            from: catalog,
            reporter: reporter,
            browserDetection: nil,
            homeDirectories: homeDirectories,
            filterInstalled: false)
    }

    static func extractSessionKeyInfo(
        browserDetection: BrowserDetection,
        logger: ((String) -> Void)? = nil) throws -> SessionKeyInfo
    {
        _ = browserDetection
        let reporter = CookieExtractionReporter(logger: logger)
        let query = BrowserCookieQuery(domains: ["claude.ai"])

        reporter.info("Starting cookie scan")
        let catalog = Self.loadBrowserCatalog(reporter: reporter)
        let candidates = Self.cookieStoreCandidates(
            from: catalog,
            reporter: reporter,
            browserDetection: browserDetection)
        reporter.info("Cookie store candidates: \(candidates.count)")

        for candidate in candidates {
            if let sessionInfo = Self.sessionKeyInfo(from: candidate, query: query, reporter: reporter) {
                return sessionInfo
            }
        }

        throw FetchError.noSessionKeyFound(report: reporter.report)
    }

    private static func loadBrowserCatalog(reporter: CookieExtractionReporter) -> ClaudeBrowserCatalog {
        do {
            let catalog = try ClaudeBrowserCatalog.loadFromBundle()
            let count = catalog.chromium.count + catalog.firefox.count + catalog.webkit.count + catalog.safari.count
            reporter.info("Loaded browser catalog (\(count) entries)")
            return catalog
        } catch {
            reporter.error(
                "Browser catalog load failed: \(error.localizedDescription)",
                category: .catalogLoadFailed)
            return .empty
        }
    }

    private static func cookieStoreCandidates(
        from catalog: ClaudeBrowserCatalog,
        reporter: CookieExtractionReporter,
        browserDetection: BrowserDetection?,
        fileManager: FileManager = .default,
        homeDirectories: [URL]? = nil,
        filterInstalled: Bool = true) -> [CookieStoreCandidate]
    {
        let homes = homeDirectories ?? Self.resolveHomeDirectories()
        var candidates: [CookieStoreCandidate] = []
        candidates.reserveCapacity(64)

        var seenPaths = Set<String>()
        let allowedIDs = browserDetection?.allowedBrowserIDsSnapshot()

        for engine in ClaudeBrowserCatalog.orderedEngines {
            let allEntries = catalog.entries(for: engine)
            let installedEntries = filterInstalled
                ? ClaudeBrowserDetector.installedEntries(from: catalog, for: engine)
                : allEntries
            let entries = allowedIDs.map { allowed in
                installedEntries.filter { allowed.contains($0.id) }
            } ?? installedEntries

            if filterInstalled {
                let skipped = allEntries.count - entries.count
                if skipped > 0 {
                    reporter.info("\(engine.rawValue): \(entries.count) installed, \(skipped) not found")
                }
            }

            for entry in entries {
                guard !entry.profileRootRelative.isEmpty else {
                    reporter.warning(
                        "No profile roots configured.",
                        browser: entry.displayName,
                        category: .profileRootEmpty)
                    continue
                }

                guard !entry.cookiePathPatterns.isEmpty else {
                    reporter.warning(
                        "No cookie path patterns configured.",
                        browser: entry.displayName,
                        category: .noCookieFiles)
                    continue
                }

                for home in homes {
                    for root in entry.profileRootRelative {
                        let rootURL = Self.resolveRootURL(root, home: home)
                        var isDir: ObjCBool = false
                        guard fileManager.fileExists(atPath: rootURL.path, isDirectory: &isDir), isDir.boolValue else {
                            reporter.info(
                                "Profile root missing: \(rootURL.path)",
                                browser: entry.displayName,
                                category: .profileRootMissing)
                            continue
                        }

                        reporter.info(
                            "Profile root found: \(rootURL.path)",
                            browser: entry.displayName)
                        let paths = Self.resolveCookiePaths(
                            root: rootURL,
                            patterns: entry.cookiePathPatterns,
                            fileManager: fileManager,
                            reporter: reporter,
                            browser: entry.displayName)

                        if paths.isEmpty {
                            reporter.warning(
                                "No cookie files found under \(rootURL.path).",
                                browser: entry.displayName,
                                category: .noCookieFiles)
                            continue
                        }

                        for path in paths {
                            let canonical = path.path
                            guard seenPaths.insert(canonical).inserted else {
                                reporter.info(
                                    "Duplicate cookie store path skipped: \(canonical)",
                                    browser: entry.displayName,
                                    category: .duplicateStore)
                                continue
                            }

                            let kind = Self.cookieStoreKind(for: path, engine: engine)
                            let profileName = Self.profileName(for: path, engine: engine)
                            let label = Self.cookieStoreLabel(
                                browserName: entry.displayName,
                                profileName: profileName,
                                kind: kind)

                            candidates.append(CookieStoreCandidate(
                                engine: engine,
                                browserID: entry.id,
                                browserName: entry.displayName,
                                bundleIDs: entry.bundleIDs,
                                profileName: profileName,
                                kind: kind,
                                url: path,
                                label: label))
                        }
                    }
                }
            }
        }

        return candidates
    }

    private static func resolveHomeDirectories() -> [URL] {
        let homes = BrowserCookieClient.defaultHomeDirectories()
        var seen = Set<String>()
        return homes.filter { home in
            let path = home.path
            guard !seen.contains(path) else { return false }
            seen.insert(path)
            return true
        }
    }

    private static func resolveRootURL(_ root: String, home: URL) -> URL {
        if root.hasPrefix("/") {
            return URL(fileURLWithPath: root)
        }
        if root.hasPrefix("Library/") {
            return home.appendingPathComponent(root)
        }
        return home.appendingPathComponent("Library").appendingPathComponent(root)
    }

    private static func resolveCookiePaths(
        root: URL,
        patterns: [String],
        fileManager: FileManager,
        reporter: CookieExtractionReporter,
        browser: String) -> [URL]
    {
        var results: [URL] = []
        var seen = Set<String>()

        for pattern in patterns {
            let expanded = Self.expandPattern(
                root: root,
                pattern: pattern,
                fileManager: fileManager,
                reporter: reporter,
                browser: browser)
            for url in expanded {
                let path = url.path
                if seen.insert(path).inserted {
                    results.append(url)
                }
            }
        }

        return results
    }

    private static func expandPattern(
        root: URL,
        pattern: String,
        fileManager: FileManager,
        reporter: CookieExtractionReporter,
        browser: String) -> [URL]
    {
        let components = pattern.split(separator: "/").map(String.init)
        guard !components.isEmpty else { return [] }

        var paths: [URL] = [root]
        for (index, component) in components.enumerated() {
            let isLast = index == components.count - 1
            let hasWildcard = component.contains("*")
            var nextPaths: [URL] = []

            for current in paths {
                if hasWildcard {
                    guard let entries = Self.directoryEntries(
                        at: current,
                        fileManager: fileManager,
                        reporter: reporter,
                        browser: browser)
                    else {
                        continue
                    }

                    for entry in entries {
                        let name = entry.lastPathComponent
                        guard Self.matchesWildcard(name, pattern: component) else { continue }
                        if !isLast {
                            var isDir: ObjCBool = false
                            guard fileManager.fileExists(atPath: entry.path, isDirectory: &isDir),
                                  isDir.boolValue
                            else {
                                continue
                            }
                        }
                        nextPaths.append(entry)
                    }
                } else {
                    nextPaths.append(current.appendingPathComponent(component))
                }
            }

            paths = nextPaths
            if paths.isEmpty { return [] }
        }

        return paths.filter { fileManager.fileExists(atPath: $0.path) }
    }

    private static func directoryEntries(
        at url: URL,
        fileManager: FileManager,
        reporter: CookieExtractionReporter,
        browser: String) -> [URL]?
    {
        do {
            return try fileManager.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles])
        } catch {
            reporter.warning(
                "Failed to list directory \(url.path): \(error.localizedDescription)",
                browser: browser,
                category: .directoryReadFailed)
            return nil
        }
    }

    private static func matchesWildcard(_ name: String, pattern: String) -> Bool {
        guard pattern.contains("*") else { return name == pattern }
        if pattern == "*" { return true }

        let parts = pattern.split(separator: "*", omittingEmptySubsequences: false).map(String.init)
        var index = name.startIndex

        for (offset, part) in parts.enumerated() where !part.isEmpty {
            if offset == 0 {
                guard name.hasPrefix(part) else { return false }
                index = name.index(name.startIndex, offsetBy: part.count)
                continue
            }
            if offset == parts.count - 1 {
                guard name[index...].hasSuffix(part) else { return false }
            } else {
                guard let range = name[index...].range(of: part) else { return false }
                index = range.upperBound
            }
        }

        return true
    }

    private static func cookieStoreKind(for url: URL, engine: ClaudeBrowserEngine) -> BrowserCookieStoreKind {
        switch engine {
        case .chromium:
            let path = url.path
            if path.contains("/Network/Cookies") || path.hasSuffix("/Network/Cookies") {
                return .network
            }
            return .primary
        case .firefox, .webkit, .safari:
            return .primary
        }
    }

    private static func profileName(for url: URL, engine: ClaudeBrowserEngine) -> String? {
        switch engine {
        case .chromium:
            if url.lastPathComponent == "Cookies" {
                let parent = url.deletingLastPathComponent()
                if parent.lastPathComponent == "Network" {
                    return parent.deletingLastPathComponent().lastPathComponent
                }
                return parent.lastPathComponent
            }
            return url.deletingLastPathComponent().lastPathComponent
        case .firefox:
            return url.deletingLastPathComponent().lastPathComponent
        case .webkit, .safari:
            return nil
        }
    }

    private static func cookieStoreLabel(
        browserName: String,
        profileName: String?,
        kind: BrowserCookieStoreKind) -> String
    {
        var label = browserName
        if let profileName, !profileName.isEmpty {
            label += " \(profileName)"
        }
        if kind == .network {
            label += " (Network)"
        }
        return label
    }

    private static func sessionKeyInfo(
        from candidate: CookieStoreCandidate,
        query: BrowserCookieQuery,
        reporter: CookieExtractionReporter) -> SessionKeyInfo?
    {
        reporter.info(
            "Trying cookies from \(candidate.url.path)",
            browser: candidate.browserName)

        switch candidate.engine {
        case .chromium, .firefox:
            let profileName = candidate.profileName ?? "Default"
            let profile = BrowserProfile(id: "\(candidate.browserID).\(profileName)", name: profileName)
            let browser: Browser = candidate.engine == .firefox ? .firefox : .chromium
            let store = BrowserCookieStore(
                browser: browser,
                profile: profile,
                kind: candidate.kind,
                label: candidate.label,
                databaseURL: candidate.url)
            do {
                let records = try Self.cookieClient.records(
                    matching: query,
                    in: store,
                    logger: reporter.makeClientLogger(browser: candidate.browserName))
                let pairs = records.map { (name: $0.name, value: $0.value) }
                if let sessionKey = findSessionKey(in: pairs) {
                    reporter.info(
                        "Found sessionKey in \(candidate.label)",
                        browser: candidate.browserName)
                    return SessionKeyInfo(
                        key: sessionKey,
                        sourceLabel: candidate.label,
                        cookieCount: records.count)
                }
                if candidate.engine == .chromium,
                   let fallback = try? ChromiumCookieFallbackReader.loadSessionKey(
                       databaseURL: candidate.url,
                       browserName: candidate.browserName,
                       bundleIDs: candidate.bundleIDs,
                       domains: query.domains,
                       logger: reporter.makeClientLogger(browser: candidate.browserName))
                {
                    reporter.info(
                        "Found sessionKey in \(candidate.label) via fallback",
                        browser: candidate.browserName)
                    return SessionKeyInfo(
                        key: fallback.key,
                        sourceLabel: candidate.label,
                        cookieCount: fallback.cookieCount)
                }
                reporter.info(
                    "Session key not found in \(candidate.label) (\(records.count) cookies)",
                    browser: candidate.browserName)
            } catch {
                reporter.warning(
                    "Cookie read failed: \(error.localizedDescription)",
                    browser: candidate.browserName,
                    category: .cookieReadFailed)
                if candidate.engine == .chromium,
                   let fallback = try? ChromiumCookieFallbackReader.loadSessionKey(
                       databaseURL: candidate.url,
                       browserName: candidate.browserName,
                       bundleIDs: candidate.bundleIDs,
                       domains: query.domains,
                       logger: reporter.makeClientLogger(browser: candidate.browserName))
                {
                    reporter.info(
                        "Found sessionKey in \(candidate.label) via fallback",
                        browser: candidate.browserName)
                    return SessionKeyInfo(
                        key: fallback.key,
                        sourceLabel: candidate.label,
                        cookieCount: fallback.cookieCount)
                }
            }
        case .webkit, .safari:
            do {
                let records = try BinaryCookiesReader.loadCookies(
                    from: candidate.url,
                    matching: query,
                    logger: reporter.makeClientLogger(browser: candidate.browserName))
                let pairs = records.map { (name: $0.name, value: $0.value) }
                if let sessionKey = findSessionKey(in: pairs) {
                    reporter.info(
                        "Found sessionKey in \(candidate.label)",
                        browser: candidate.browserName)
                    return SessionKeyInfo(
                        key: sessionKey,
                        sourceLabel: candidate.label,
                        cookieCount: records.count)
                }
                reporter.info(
                    "Session key not found in \(candidate.label) (\(records.count) cookies)",
                    browser: candidate.browserName)
            } catch let error as BinaryCookiesReader.ReadError {
                switch error {
                case .fileNotFound:
                    reporter.warning(
                        "Cookie file missing: \(candidate.url.path)",
                        browser: candidate.browserName,
                        category: .noCookieFiles)
                case let .fileNotReadable(path):
                    reporter.warning(
                        "Cookie file not readable: \(path)",
                        browser: candidate.browserName,
                        category: .cookieFileUnreadable)
                case .invalidFile:
                    reporter.error(
                        "Cookie file invalid: \(candidate.url.path)",
                        browser: candidate.browserName,
                        category: .cookieParseFailed)
                }
            } catch {
                reporter.error(
                    "Cookie parse failed: \(error.localizedDescription)",
                    browser: candidate.browserName,
                    category: .cookieParseFailed)
            }
        }

        return nil
    }

    static func findSessionKey(in cookies: [(name: String, value: String)]) -> String? {
        for cookie in cookies where cookie.name == "sessionKey" {
            let value = cookie.value.trimmingCharacters(in: .whitespacesAndNewlines)
            if value.hasPrefix("sk-ant-") {
                return value
            }
        }
        return nil
    }
}

#endif
