#if os(macOS)
import Foundation
import SweetCookieKit
import WebKit

@MainActor
public struct OpenAIDashboardBrowserCookieImporter {
    public struct FoundAccount: Sendable, Hashable {
        public let sourceLabel: String
        public let email: String

        public init(sourceLabel: String, email: String) {
            self.sourceLabel = sourceLabel
            self.email = email
        }
    }

    public enum ImportError: LocalizedError {
        case noCookiesFound
        case browserAccessDenied(details: String)
        case dashboardStillRequiresLogin
        case noMatchingAccount(found: [FoundAccount])
        case manualCookieHeaderInvalid

        public var errorDescription: String? {
            switch self {
            case .noCookiesFound:
                return "No browser cookies found."
            case let .browserAccessDenied(details):
                return "Browser cookie access denied. \(details)"
            case .dashboardStillRequiresLogin:
                return "Browser cookies imported, but dashboard still requires login."
            case let .noMatchingAccount(found):
                if found.isEmpty { return "No matching OpenAI web session found in browsers." }
                let display = found
                    .sorted { lhs, rhs in
                        if lhs.sourceLabel == rhs.sourceLabel { return lhs.email < rhs.email }
                        return lhs.sourceLabel < rhs.sourceLabel
                    }
                    .map { "\($0.sourceLabel)=\($0.email)" }
                    .joined(separator: ", ")
                return "OpenAI web session does not match Codex account. Found: \(display)."
            case .manualCookieHeaderInvalid:
                return "Manual cookie header is missing a valid OpenAI session cookie."
            }
        }
    }

    public struct ImportResult: Sendable {
        public let sourceLabel: String
        public let cookieCount: Int
        public let signedInEmail: String?
        public let matchesCodexEmail: Bool

        public init(
            sourceLabel: String,
            cookieCount: Int,
            signedInEmail: String?,
            matchesCodexEmail: Bool)
        {
            self.sourceLabel = sourceLabel
            self.cookieCount = cookieCount
            self.signedInEmail = signedInEmail
            self.matchesCodexEmail = matchesCodexEmail
        }
    }

    public init(browserDetection: BrowserDetection) {
        self.browserDetection = browserDetection
    }

    private let browserDetection: BrowserDetection

    private struct ImportDiagnostics {
        var mismatches: [FoundAccount] = []
        var foundAnyCookies: Bool = false
        var foundUnknownEmail: Bool = false
        var accessDeniedHints: [String] = []
    }

    private static let cookieDomains = ["chatgpt.com", "openai.com"]
    private static let cookieClient = BrowserCookieClient()
    private static let cookieImportOrder: BrowserCookieImportOrder =
        ProviderDefaults.metadata[.codex]?.browserCookieOrder ?? Browser.defaultImportOrder

    private enum CandidateEvaluation {
        case match(candidate: Candidate, signedInEmail: String)
        case mismatch(candidate: Candidate, signedInEmail: String)
        case loggedIn(candidate: Candidate, signedInEmail: String)
        case unknown(candidate: Candidate)
        case loginRequired(candidate: Candidate)
    }

    public func importBestCookies(
        intoAccountEmail targetEmail: String?,
        allowAnyAccount: Bool = false,
        logger: ((String) -> Void)? = nil) async throws -> ImportResult
    {
        let log: (String) -> Void = { message in
            logger?("[web] \(message)")
        }

        let targetEmail = targetEmail?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedTarget = targetEmail?.isEmpty == false ? targetEmail : nil

        if let normalizedTarget {
            log("Codex email: \(normalizedTarget)")
        } else {
            guard allowAnyAccount else {
                throw ImportError.noCookiesFound
            }
            log("Codex email unknown; importing any signed-in session.")
        }

        var diagnostics = ImportDiagnostics()

        // Filter to cookie-eligible browsers to avoid unnecessary keychain prompts
        let installedBrowsers = Self.cookieImportOrder.cookieImportCandidates(using: self.browserDetection)
        for browserSource in installedBrowsers {
            if let match = await self.trySource(
                browserSource,
                targetEmail: normalizedTarget,
                allowAnyAccount: allowAnyAccount,
                log: log,
                diagnostics: &diagnostics)
            {
                return match
            }
        }

        if !diagnostics.mismatches.isEmpty {
            let found = Array(Set(diagnostics.mismatches)).sorted { lhs, rhs in
                if lhs.sourceLabel == rhs.sourceLabel { return lhs.email < rhs.email }
                return lhs.sourceLabel < rhs.sourceLabel
            }
            let emails = Array(Set(found.map(\.email))).sorted()
            log("No matching browser session found. Candidates signed in as: \(emails.joined(separator: ", "))")
            throw ImportError.noMatchingAccount(found: found)
        }

        if diagnostics.foundUnknownEmail || diagnostics.foundAnyCookies {
            log("No matching browser session found (email unknown).")
            throw ImportError.noMatchingAccount(found: [])
        }

        if !diagnostics.accessDeniedHints.isEmpty {
            let details = diagnostics.accessDeniedHints.joined(separator: " ")
            log("Cookie access denied: \(details)")
            throw ImportError.browserAccessDenied(details: details)
        }

        throw ImportError.noCookiesFound
    }

    public func importManualCookies(
        cookieHeader: String,
        intoAccountEmail targetEmail: String?,
        allowAnyAccount: Bool = false,
        logger: ((String) -> Void)? = nil) async throws -> ImportResult
    {
        let log: (String) -> Void = { message in
            logger?("[web] \(message)")
        }
        let normalizedTarget = targetEmail?.trimmingCharacters(in: .whitespacesAndNewlines)
        let allowAnyAccount = allowAnyAccount || normalizedTarget == nil || normalizedTarget?.isEmpty == true

        guard let normalized = CookieHeaderNormalizer.normalize(cookieHeader) else {
            throw ImportError.manualCookieHeaderInvalid
        }
        let pairs = CookieHeaderNormalizer.pairs(from: normalized)
        guard !pairs.isEmpty else { throw ImportError.manualCookieHeaderInvalid }
        let cookies = self.cookies(from: pairs)
        guard !cookies.isEmpty else { throw ImportError.manualCookieHeaderInvalid }

        let candidate = Candidate(label: "Manual", cookies: cookies)
        switch await self.evaluateCandidate(
            candidate,
            targetEmail: normalizedTarget,
            allowAnyAccount: allowAnyAccount,
            log: log)
        {
        case let .match(_, signedInEmail):
            return try await self.persist(candidate: candidate, targetEmail: signedInEmail, logger: log)
        case let .loggedIn(_, signedInEmail):
            return try await self.persist(candidate: candidate, targetEmail: signedInEmail, logger: log)
        case let .mismatch(_, signedInEmail):
            throw ImportError.noMatchingAccount(found: [FoundAccount(sourceLabel: "Manual", email: signedInEmail)])
        case .unknown:
            if allowAnyAccount {
                return try await self.persistToDefaultStore(candidate: candidate, logger: log)
            }
            throw ImportError.noMatchingAccount(found: [])
        case .loginRequired:
            throw ImportError.manualCookieHeaderInvalid
        }
    }

    private func trySafari(
        targetEmail: String?,
        allowAnyAccount: Bool,
        log: @escaping (String) -> Void,
        diagnostics: inout ImportDiagnostics) async -> ImportResult?
    {
        // Safari first: avoids touching Keychain ("Chrome Safe Storage") when Safari already matches.
        do {
            let query = BrowserCookieQuery(domains: Self.cookieDomains)
            let sources = try Self.cookieClient.records(
                matching: query,
                in: .safari,
                logger: log)
            guard !sources.isEmpty else {
                log("Safari contained 0 matching records.")
                return nil
            }
            for source in sources {
                let cookies = BrowserCookieClient.makeHTTPCookies(source.records, origin: query.origin)
                guard !cookies.isEmpty else {
                    log("\(source.label) produced 0 HTTPCookies.")
                    continue
                }

                diagnostics.foundAnyCookies = true
                log("Loaded \(cookies.count) cookies from \(source.label) (\(self.cookieSummary(cookies)))")
                let candidate = Candidate(label: source.label, cookies: cookies)
                if let match = await self.applyCandidate(
                    candidate,
                    targetEmail: targetEmail,
                    allowAnyAccount: allowAnyAccount,
                    log: log,
                    diagnostics: &diagnostics)
                {
                    return match
                }
            }
            return nil
        } catch let error as BrowserCookieError {
            if let hint = error.accessDeniedHint {
                diagnostics.accessDeniedHints.append(hint)
            }
            log("Safari cookie load failed: \(error.localizedDescription)")
            return nil
        } catch {
            log("Safari cookie load failed: \(error.localizedDescription)")
            return nil
        }
    }

    private func tryChrome(
        targetEmail: String?,
        allowAnyAccount: Bool,
        log: @escaping (String) -> Void,
        diagnostics: inout ImportDiagnostics) async -> ImportResult?
    {
        // Chrome fallback: may trigger Keychain prompt. Only do this if Safari didn't match.
        do {
            let query = BrowserCookieQuery(domains: Self.cookieDomains)
            let chromeSources = try Self.cookieClient.records(
                matching: query,
                in: .chrome)
            for source in chromeSources {
                let cookies = BrowserCookieClient.makeHTTPCookies(source.records, origin: query.origin)
                if cookies.isEmpty {
                    log("\(source.label) produced 0 HTTPCookies.")
                    continue
                }
                diagnostics.foundAnyCookies = true
                log("Loaded \(cookies.count) cookies from \(source.label) (\(self.cookieSummary(cookies)))")
                let candidate = Candidate(label: source.label, cookies: cookies)
                if let match = await self.applyCandidate(
                    candidate,
                    targetEmail: targetEmail,
                    allowAnyAccount: allowAnyAccount,
                    log: log,
                    diagnostics: &diagnostics)
                {
                    return match
                }
            }
            return nil
        } catch let error as BrowserCookieError {
            if let hint = error.accessDeniedHint {
                diagnostics.accessDeniedHints.append(hint)
            }
            log("Chrome cookie load failed: \(error.localizedDescription)")
            return nil
        } catch {
            log("Chrome cookie load failed: \(error.localizedDescription)")
            return nil
        }
    }

    private func tryFirefox(
        targetEmail: String?,
        allowAnyAccount: Bool,
        log: @escaping (String) -> Void,
        diagnostics: inout ImportDiagnostics) async -> ImportResult?
    {
        // Firefox fallback: no Keychain, but still only after Safari/Chrome.
        do {
            let query = BrowserCookieQuery(domains: Self.cookieDomains)
            let firefoxSources = try Self.cookieClient.records(
                matching: query,
                in: .firefox)
            for source in firefoxSources {
                let cookies = BrowserCookieClient.makeHTTPCookies(source.records, origin: query.origin)
                if cookies.isEmpty {
                    log("\(source.label) produced 0 HTTPCookies.")
                    continue
                }
                diagnostics.foundAnyCookies = true
                log("Loaded \(cookies.count) cookies from \(source.label) (\(self.cookieSummary(cookies)))")
                let candidate = Candidate(label: source.label, cookies: cookies)
                if let match = await self.applyCandidate(
                    candidate,
                    targetEmail: targetEmail,
                    allowAnyAccount: allowAnyAccount,
                    log: log,
                    diagnostics: &diagnostics)
                {
                    return match
                }
            }
            return nil
        } catch let error as BrowserCookieError {
            if let hint = error.accessDeniedHint {
                diagnostics.accessDeniedHints.append(hint)
            }
            log("Firefox cookie load failed: \(error.localizedDescription)")
            return nil
        } catch {
            log("Firefox cookie load failed: \(error.localizedDescription)")
            return nil
        }
    }

    private func trySource(
        _ source: Browser,
        targetEmail: String?,
        allowAnyAccount: Bool,
        log: @escaping (String) -> Void,
        diagnostics: inout ImportDiagnostics) async -> ImportResult?
    {
        switch source {
        case .safari:
            await self.trySafari(
                targetEmail: targetEmail,
                allowAnyAccount: allowAnyAccount,
                log: log,
                diagnostics: &diagnostics)
        case .chrome:
            await self.tryChrome(
                targetEmail: targetEmail,
                allowAnyAccount: allowAnyAccount,
                log: log,
                diagnostics: &diagnostics)
        case .firefox:
            await self.tryFirefox(
                targetEmail: targetEmail,
                allowAnyAccount: allowAnyAccount,
                log: log,
                diagnostics: &diagnostics)
        default:
            nil
        }
    }

    private func applyCandidate(
        _ candidate: Candidate,
        targetEmail: String?,
        allowAnyAccount: Bool,
        log: @escaping (String) -> Void,
        diagnostics: inout ImportDiagnostics) async -> ImportResult?
    {
        switch await self.evaluateCandidate(
            candidate,
            targetEmail: targetEmail,
            allowAnyAccount: allowAnyAccount,
            log: log)
        {
        case let .match(candidate, signedInEmail):
            log("Selected \(candidate.label) (matches Codex: \(signedInEmail))")
            guard let targetEmail else { return nil }
            return try? await self.persist(candidate: candidate, targetEmail: targetEmail, logger: log)
        case let .mismatch(candidate, signedInEmail):
            await self.handleMismatch(
                candidate: candidate,
                signedInEmail: signedInEmail,
                log: log,
                diagnostics: &diagnostics)
            return nil
        case let .loggedIn(candidate, signedInEmail):
            log("Selected \(candidate.label) (signed in: \(signedInEmail))")
            return try? await self.persist(candidate: candidate, targetEmail: signedInEmail, logger: log)
        case .unknown:
            if allowAnyAccount {
                log("Selected \(candidate.label) (signed in: unknown)")
                return try? await self.persistToDefaultStore(candidate: candidate, logger: log)
            }
            diagnostics.foundUnknownEmail = true
            return nil
        case .loginRequired:
            return nil
        }
    }

    private func evaluateCandidate(
        _ candidate: Candidate,
        targetEmail: String?,
        allowAnyAccount: Bool,
        log: @escaping (String) -> Void) async -> CandidateEvaluation
    {
        log("Trying candidate \(candidate.label) (\(candidate.cookies.count) cookies)")

        let apiEmail = await self.fetchSignedInEmailFromAPI(cookies: candidate.cookies, logger: log)
        if let apiEmail {
            log("Candidate \(candidate.label) API email: \(apiEmail)")
        }

        // Prefer the API email when available (fast; avoids WebKit hydration/timeout risks).
        if let apiEmail, !apiEmail.isEmpty {
            if let targetEmail {
                if apiEmail.lowercased() == targetEmail.lowercased() {
                    return .match(candidate: candidate, signedInEmail: apiEmail)
                }
                return .mismatch(candidate: candidate, signedInEmail: apiEmail)
            }
            if allowAnyAccount { return .loggedIn(candidate: candidate, signedInEmail: apiEmail) }
        }

        if !self.hasSessionCookies(candidate.cookies) {
            log("Candidate \(candidate.label) missing session cookies; skipping")
            return .loginRequired(candidate: candidate)
        }

        let scratch = WKWebsiteDataStore.nonPersistent()
        await self.setCookies(candidate.cookies, into: scratch)

        do {
            let probe = try await OpenAIDashboardFetcher().probeUsagePage(
                websiteDataStore: scratch,
                logger: log,
                timeout: 25)
            let signedInEmail = probe.signedInEmail?.trimmingCharacters(in: .whitespacesAndNewlines)
            log("Candidate \(candidate.label) DOM email: \(signedInEmail ?? "unknown")")

            let resolvedEmail = signedInEmail?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let resolvedEmail, !resolvedEmail.isEmpty {
                if let targetEmail {
                    if resolvedEmail.lowercased() == targetEmail.lowercased() {
                        return .match(candidate: candidate, signedInEmail: resolvedEmail)
                    }
                    return .mismatch(candidate: candidate, signedInEmail: resolvedEmail)
                }
                if allowAnyAccount { return .loggedIn(candidate: candidate, signedInEmail: resolvedEmail) }
            }

            return .unknown(candidate: candidate)
        } catch OpenAIDashboardFetcher.FetchError.loginRequired {
            log("Candidate \(candidate.label) requires login.")
            return .loginRequired(candidate: candidate)
        } catch {
            log("Candidate \(candidate.label) probe error: \(error.localizedDescription)")
            return .unknown(candidate: candidate)
        }
    }

    private func hasSessionCookies(_ cookies: [HTTPCookie]) -> Bool {
        for cookie in cookies {
            let name = cookie.name.lowercased()
            if name.contains("session-token") || name.contains("authjs") || name.contains("next-auth") {
                return true
            }
            if name == "_account" { return true }
        }
        return false
    }

    private func handleMismatch(
        candidate: Candidate,
        signedInEmail: String,
        log: @escaping (String) -> Void,
        diagnostics: inout ImportDiagnostics) async
    {
        log("Candidate \(candidate.label) mismatch (\(signedInEmail)); continuing browser search")
        diagnostics.mismatches.append(FoundAccount(sourceLabel: candidate.label, email: signedInEmail))
        // Mismatch still means we found a valid signed-in session. Persist it keyed by its email so if
        // the user switches Codex accounts later, we can reuse this session immediately without another
        // Keychain prompt.
        await self.persistCookies(candidate: candidate, accountEmail: signedInEmail, logger: log)
    }

    private func fetchSignedInEmailFromAPI(
        cookies: [HTTPCookie],
        logger: (String) -> Void) async -> String?
    {
        let chatgptCookies = cookies.filter { $0.domain.lowercased().contains("chatgpt.com") }
        guard !chatgptCookies.isEmpty else { return nil }

        let cookieHeader = chatgptCookies
            .map { "\($0.name)=\($0.value)" }
            .joined(separator: "; ")

        let endpoints = [
            "https://chatgpt.com/backend-api/me",
            "https://chatgpt.com/api/auth/session",
        ]

        for urlString in endpoints {
            guard let url = URL(string: urlString) else { continue }
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.timeoutInterval = 10
            request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
            request.setValue("application/json", forHTTPHeaderField: "Accept")

            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? -1
                logger("API \(url.host ?? "chatgpt.com") \(url.path) status=\(status)")
                guard status >= 200, status < 300 else { continue }
                if let email = Self.findFirstEmail(inJSONData: data) {
                    return email.trimmingCharacters(in: .whitespacesAndNewlines)
                }
            } catch {
                logger("API request failed: \(error.localizedDescription)")
            }
        }

        return nil
    }

    private static func findFirstEmail(inJSONData data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data, options: []) else { return nil }
        var queue: [Any] = [json]
        var seen = 0
        while !queue.isEmpty, seen < 2000 {
            let cur = queue.removeFirst()
            seen += 1
            if let str = cur as? String, str.contains("@") {
                return str
            }
            if let dict = cur as? [String: Any] {
                for (k, v) in dict {
                    if k.lowercased() == "email", let s = v as? String, s.contains("@") { return s }
                    queue.append(v)
                }
            } else if let arr = cur as? [Any] {
                queue.append(contentsOf: arr)
            }
        }
        return nil
    }

    private func persist(
        candidate: Candidate,
        targetEmail: String,
        logger: @escaping (String) -> Void) async throws -> ImportResult
    {
        let persistent = OpenAIDashboardWebsiteDataStore.store(forAccountEmail: targetEmail)
        await self.clearChatGPTCookies(in: persistent)
        await self.setCookies(candidate.cookies, into: persistent)

        // Validate against the persistent store (login + email sync).
        do {
            let probe = try await OpenAIDashboardFetcher().probeUsagePage(
                websiteDataStore: persistent,
                logger: logger,
                timeout: 20)
            let signed = probe.signedInEmail?.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
            let matches = signed?.lowercased() == targetEmail.lowercased()
            logger("Persistent session signed in as: \(signed ?? "unknown")")
            if signed != nil, matches == false {
                let found = signed?.isEmpty == false
                    ? [FoundAccount(sourceLabel: candidate.label, email: signed!)]
                    : []
                throw ImportError.noMatchingAccount(found: found)
            }
            return ImportResult(
                sourceLabel: candidate.label,
                cookieCount: candidate.cookies.count,
                signedInEmail: signed,
                matchesCodexEmail: matches)
        } catch OpenAIDashboardFetcher.FetchError.loginRequired {
            logger("Selected \(candidate.label) but dashboard still requires login.")
            throw ImportError.dashboardStillRequiresLogin
        }
    }

    private func persistToDefaultStore(
        candidate: Candidate,
        logger: @escaping (String) -> Void) async throws -> ImportResult
    {
        let persistent = OpenAIDashboardWebsiteDataStore.store(forAccountEmail: nil)
        await self.clearChatGPTCookies(in: persistent)
        await self.setCookies(candidate.cookies, into: persistent)

        do {
            let probe = try await OpenAIDashboardFetcher().probeUsagePage(
                websiteDataStore: persistent,
                logger: logger,
                timeout: 20)
            let signed = probe.signedInEmail?.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
            logger("Persistent session signed in as: \(signed ?? "unknown")")
            return ImportResult(
                sourceLabel: candidate.label,
                cookieCount: candidate.cookies.count,
                signedInEmail: signed,
                matchesCodexEmail: false)
        } catch OpenAIDashboardFetcher.FetchError.loginRequired {
            logger("Selected \(candidate.label) but dashboard still requires login.")
            throw ImportError.dashboardStillRequiresLogin
        }
    }

    // MARK: - Candidates

    private func cookies(from pairs: [(name: String, value: String)]) -> [HTTPCookie] {
        var cookies: [HTTPCookie] = []
        for domain in Self.cookieDomains {
            for pair in pairs {
                let props: [HTTPCookiePropertyKey: Any] = [
                    .name: pair.name,
                    .value: pair.value,
                    .domain: domain,
                    .path: "/",
                    .secure: true,
                ]
                if let cookie = HTTPCookie(properties: props) {
                    cookies.append(cookie)
                }
            }
        }
        return cookies
    }

    private struct Candidate: Sendable {
        let label: String
        let cookies: [HTTPCookie]
    }

    // MARK: - WebKit cookie store

    private func persistCookies(candidate: Candidate, accountEmail: String, logger: (String) -> Void) async {
        let store = OpenAIDashboardWebsiteDataStore.store(forAccountEmail: accountEmail)
        await self.clearChatGPTCookies(in: store)
        await self.setCookies(candidate.cookies, into: store)
        logger("Persisted cookies for \(accountEmail) (source=\(candidate.label))")
    }

    private func clearChatGPTCookies(in store: WKWebsiteDataStore) async {
        await withCheckedContinuation { cont in
            store.fetchDataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes()) { records in
                let filtered = records.filter { record in
                    let name = record.displayName.lowercased()
                    return name.contains("chatgpt.com") || name.contains("openai.com")
                }
                store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), for: filtered) {
                    cont.resume()
                }
            }
        }
    }

    private func setCookies(_ cookies: [HTTPCookie], into store: WKWebsiteDataStore) async {
        for cookie in cookies {
            await withCheckedContinuation { cont in
                store.httpCookieStore.setCookie(cookie) { cont.resume() }
            }
        }
    }

    private func cookieSummary(_ cookies: [HTTPCookie]) -> String {
        let nameCounts = Dictionary(grouping: cookies, by: \.name).mapValues { $0.count }
        let important = [
            "__Secure-next-auth.session-token",
            "__Secure-next-auth.session-token.0",
            "__Secure-next-auth.session-token.1",
            "_account",
            "oai-did",
            "cf_clearance",
        ]
        let parts: [String] = important.compactMap { name -> String? in
            guard let c = nameCounts[name], c > 0 else { return nil }
            return "\(name)=\(c)"
        }
        if parts.isEmpty { return "no key cookies detected" }
        return parts.joined(separator: ", ")
    }
}
#else
import Foundation

@MainActor
public struct OpenAIDashboardBrowserCookieImporter {
    public struct FoundAccount: Sendable, Hashable {
        public let sourceLabel: String
        public let email: String

        public init(sourceLabel: String, email: String) {
            self.sourceLabel = sourceLabel
            self.email = email
        }
    }

    public enum ImportError: LocalizedError {
        case noCookiesFound
        case browserAccessDenied(details: String)
        case dashboardStillRequiresLogin
        case noMatchingAccount(found: [FoundAccount])
        case manualCookieHeaderInvalid

        public var errorDescription: String? {
            switch self {
            case .noCookiesFound:
                return "No browser cookies found."
            case let .browserAccessDenied(details):
                return "Browser cookie access denied. \(details)"
            case .dashboardStillRequiresLogin:
                return "Browser cookies imported, but dashboard still requires login."
            case let .noMatchingAccount(found):
                if found.isEmpty { return "No matching OpenAI web session found in browsers." }
                let display = found
                    .sorted { lhs, rhs in
                        if lhs.sourceLabel == rhs.sourceLabel { return lhs.email < rhs.email }
                        return lhs.sourceLabel < rhs.sourceLabel
                    }
                    .map { "\($0.sourceLabel)=\($0.email)" }
                    .joined(separator: ", ")
                return "OpenAI web session does not match Codex account. Found: \(display)."
            case .manualCookieHeaderInvalid:
                return "Manual cookie header is missing a valid OpenAI session cookie."
            }
        }
    }

    public struct ImportResult: Sendable {
        public let sourceLabel: String
        public let cookieCount: Int
        public let signedInEmail: String?
        public let matchesCodexEmail: Bool

        public init(sourceLabel: String, cookieCount: Int, signedInEmail: String?, matchesCodexEmail: Bool) {
            self.sourceLabel = sourceLabel
            self.cookieCount = cookieCount
            self.signedInEmail = signedInEmail
            self.matchesCodexEmail = matchesCodexEmail
        }
    }

    public init() {}

    public func importBestCookies(
        intoAccountEmail _: String?,
        allowAnyAccount _: Bool = false,
        logger _: ((String) -> Void)? = nil) async throws -> ImportResult
    {
        throw ImportError.browserAccessDenied(details: "OpenAI web cookie import is only supported on macOS.")
    }

    public func importManualCookies(
        cookieHeader _: String,
        intoAccountEmail _: String?,
        allowAnyAccount _: Bool = false,
        logger _: ((String) -> Void)? = nil) async throws -> ImportResult
    {
        throw ImportError.browserAccessDenied(details: "OpenAI web cookie import is only supported on macOS.")
    }
}
#endif
