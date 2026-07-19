import Foundation

public enum GroqConsoleSession {
    /// Long-lived (~30 day) opaque session cookie. Exchanged for a fresh JWT.
    public static let sessionCookieName = "stytch_session"
    /// Short-lived session JWT cookie. Used directly if a refresh isn't possible.
    public static let jwtCookieName = "stytch_session_jwt"
    /// Environment override (a session JWT), primarily for CLI/testing.
    public static let sessionEnvironmentKey = "GROQ_SESSION_JWT"
    /// Environment override (an opaque session token) for CLI/testing the refresh path.
    public static let sessionTokenEnvironmentKey = "GROQ_SESSION_TOKEN"

    public struct SessionInfo: Sendable {
        /// Long-lived opaque token; when present, exchanged for a fresh JWT.
        public let sessionToken: String?
        /// Short-lived JWT read straight from the browser (fallback / override).
        public let directJWT: String?
        public let sourceLabel: String

        public init(sessionToken: String?, directJWT: String?, sourceLabel: String) {
            self.sessionToken = sessionToken
            self.directJWT = directJWT
            self.sourceLabel = sourceLabel
        }
    }

    /// Resolves a usable session JWT for `SessionInfo`: refreshes the opaque
    /// token when available (robust for background polling), else falls back to
    /// the short-lived JWT cookie.
    static func resolveJWT(
        for session: SessionInfo,
        environment: [String: String],
        transport: any ProviderHTTPTransport) async throws -> String
    {
        if let token = session.sessionToken?.trimmingCharacters(in: .whitespacesAndNewlines),
           !token.isEmpty
        {
            do {
                return try await GroqConsoleStytch.refreshSessionJWT(
                    sessionToken: token,
                    environment: environment,
                    transport: transport)
            } catch {
                // Fall through to a direct JWT if the refresh failed but we have one.
                if let jwt = session.directJWT?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !jwt.isEmpty
                {
                    return jwt
                }
                throw error
            }
        }
        if let jwt = session.directJWT?.trimmingCharacters(in: .whitespacesAndNewlines), !jwt.isEmpty {
            return jwt
        }
        throw GroqConsoleError.missingSession
    }

    static func environmentSession(_ environment: [String: String]) -> SessionInfo? {
        let jwt = environment[self.sessionEnvironmentKey]?.trimmingCharacters(in: .whitespacesAndNewlines)
        let token = environment[self.sessionTokenEnvironmentKey]?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let token, !token.isEmpty {
            return SessionInfo(sessionToken: token, directJWT: jwt?.nonEmpty, sourceLabel: "env")
        }
        if let jwt, !jwt.isEmpty {
            return SessionInfo(sessionToken: nil, directJWT: jwt, sourceLabel: "env")
        }
        return nil
    }

    /// Pulls the session JWT out of a raw `Cookie:` header string (manual entry).
    public static func session(fromCookieHeader header: String?) -> SessionInfo? {
        guard let normalized = CookieHeaderNormalizer.normalize(header) else { return nil }
        var token: String?
        var jwt: String?
        for pair in CookieHeaderNormalizer.pairs(from: normalized) {
            let name = pair.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let value = pair.value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { continue }
            if name == self.sessionCookieName { token = value }
            if name == self.jwtCookieName { jwt = value }
        }
        guard token != nil || jwt != nil else { return nil }
        return SessionInfo(sessionToken: token, directJWT: jwt, sourceLabel: "manual")
    }
}

extension String {
    fileprivate var nonEmpty: String? {
        self.isEmpty ? nil : self
    }
}

#if os(macOS)
import SweetCookieKit

extension GroqConsoleSession {
    private static let log = CodexBarLog.logger(LogCategories.providers)
    private static let cookieClient = BrowserCookieClient()
    private static let cookieDomains = ["groq.com", "console.groq.com"]
    private static let cookieImportOrder: BrowserCookieImportOrder =
        ProviderDefaults.metadata[.groq]?.browserCookieOrder ?? Browser.defaultImportOrder

    /// Resolves candidate sessions from (1) the environment override, then
    /// (2) browser cookie stores in the configured import order.
    public static func resolveSessions(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        browserDetection: BrowserDetection = BrowserDetection(),
        logger: ((String) -> Void)? = nil) -> [SessionInfo]
    {
        if let override = self.environmentSession(environment) {
            return [override]
        }
        return self.importSessions(browserDetection: browserDetection, logger: logger)
    }

    public static func hasSession(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        browserDetection: BrowserDetection = BrowserDetection(),
        logger: ((String) -> Void)? = nil) -> Bool
    {
        !self.resolveSessions(
            environment: environment,
            browserDetection: browserDetection,
            logger: logger).isEmpty
    }

    static func importSessions(
        browserDetection: BrowserDetection,
        logger: ((String) -> Void)?) -> [SessionInfo]
    {
        var sessions: [SessionInfo] = []
        let candidates = self.cookieImportOrder.cookieImportCandidates(using: browserDetection)
        for browserSource in candidates {
            do {
                let query = BrowserCookieQuery(domains: self.cookieDomains)
                let sources = try self.cookieClient.codexBarRecords(
                    matching: query,
                    in: browserSource,
                    logger: { self.emit($0, logger: logger) })
                sessions.append(contentsOf: self.sessionInfos(from: sources, origin: query.origin))
            } catch {
                BrowserCookieAccessGate.recordIfNeeded(error)
                self.emit(
                    "\(browserSource.displayName) cookie import failed: \(error.localizedDescription)",
                    logger: logger)
            }
        }
        return sessions
    }

    static func sessionInfos(
        from sources: [BrowserCookieStoreRecords],
        origin: BrowserCookieOriginStrategy) -> [SessionInfo]
    {
        let grouped = Dictionary(grouping: sources, by: { $0.store.profile.id })
        let sortedGroups = grouped.values.sorted { lhs, rhs in
            self.mergedLabel(for: lhs) < self.mergedLabel(for: rhs)
        }

        var sessions: [SessionInfo] = []
        for group in sortedGroups where !group.isEmpty {
            let label = self.mergedLabel(for: group)
            let merged = self.mergeRecords(group)
            let cookies = BrowserCookieClient.makeHTTPCookies(merged, origin: origin)
            let token = cookies.first { $0.name == self.sessionCookieName }?.value.nonEmpty
            let jwt = cookies.first { $0.name == self.jwtCookieName }?.value.nonEmpty
            guard token != nil || jwt != nil else { continue }
            sessions.append(SessionInfo(sessionToken: token, directJWT: jwt, sourceLabel: label))
        }
        return sessions
    }

    private static func emit(_ message: String, logger: ((String) -> Void)?) {
        logger?("[groq-cookie] \(message)")
        self.log.debug("\(message)")
    }

    private static func mergedLabel(for sources: [BrowserCookieStoreRecords]) -> String {
        guard let base = sources.map(\.label).min() else { return "Unknown" }
        if base.hasSuffix(" (Network)") {
            return String(base.dropLast(" (Network)".count))
        }
        return base
    }

    private static func mergeRecords(_ sources: [BrowserCookieStoreRecords]) -> [BrowserCookieRecord] {
        let sortedSources = sources.sorted { lhs, rhs in
            self.storePriority(lhs.store.kind) < self.storePriority(rhs.store.kind)
        }
        var mergedByKey: [String: BrowserCookieRecord] = [:]
        for source in sortedSources {
            for record in source.records {
                let key = "\(record.name)|\(record.domain)|\(record.path)"
                if let existing = mergedByKey[key] {
                    if self.shouldReplace(existing: existing, candidate: record) {
                        mergedByKey[key] = record
                    }
                } else {
                    mergedByKey[key] = record
                }
            }
        }
        return Array(mergedByKey.values)
    }

    private static func storePriority(_ kind: BrowserCookieStoreKind) -> Int {
        switch kind {
        case .network: 0
        case .primary: 1
        case .safari: 2
        }
    }

    private static func shouldReplace(existing: BrowserCookieRecord, candidate: BrowserCookieRecord) -> Bool {
        switch (existing.expires, candidate.expires) {
        case let (lhs?, rhs?): rhs > lhs
        case (nil, .some): true
        case (.some, nil): false
        case (nil, nil): false
        }
    }
}
#else
extension GroqConsoleSession {
    public static func resolveSessions(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        browserDetection _: BrowserDetection = BrowserDetection(),
        logger _: ((String) -> Void)? = nil) -> [SessionInfo]
    {
        guard let override = self.environmentSession(environment) else { return [] }
        return [override]
    }

    public static func hasSession(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        browserDetection _: BrowserDetection = BrowserDetection(),
        logger _: ((String) -> Void)? = nil) -> Bool
    {
        self.environmentSession(environment) != nil
    }
}
#endif
