import Foundation

enum MiMoCookieHeader {
    static let requiredCookieNames: Set<String> = [
        "api-platform_serviceToken",
        "userId",
    ]
    static let knownCookieNames: Set<String> = requiredCookieNames.union([
        "api-platform_ph",
        "api-platform_slh",
    ])

    static func normalizedHeader(from raw: String?) -> String? {
        guard let normalized = CookieHeaderNormalizer.normalize(raw) else { return nil }
        let pairs = CookieHeaderNormalizer.pairs(from: normalized)
        guard !pairs.isEmpty else { return nil }

        var byName: [String: String] = [:]
        for pair in pairs {
            let name = pair.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let value = pair.value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard self.knownCookieNames.contains(name), !value.isEmpty else { continue }
            byName[name] = value
        }

        guard self.requiredCookieNames.isSubset(of: Set(byName.keys)) else { return nil }
        return byName.keys.sorted().compactMap { name in
            guard let value = byName[name] else { return nil }
            return "\(name)=\(value)"
        }.joined(separator: "; ")
    }

    static func header(from cookies: [HTTPCookie]) -> String? {
        var byName: [String: HTTPCookie] = [:]

        for cookie in cookies {
            guard self.knownCookieNames.contains(cookie.name) else { continue }
            guard !cookie.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            if let expiry = cookie.expiresDate, expiry < Date() { continue }

            if let existing = byName[cookie.name] {
                let existingExpiry = existing.expiresDate ?? .distantPast
                let candidateExpiry = cookie.expiresDate ?? .distantPast
                if candidateExpiry >= existingExpiry {
                    byName[cookie.name] = cookie
                }
            } else {
                byName[cookie.name] = cookie
            }
        }

        guard self.requiredCookieNames.isSubset(of: Set(byName.keys)) else { return nil }
        return byName.keys.sorted().compactMap { name in
            guard let cookie = byName[name] else { return nil }
            return "\(cookie.name)=\(cookie.value)"
        }.joined(separator: "; ")
    }
}

#if os(macOS)
import SweetCookieKit

private let miMoCookieImportOrder: BrowserCookieImportOrder =
    ProviderDefaults.metadata[.mimo]?.browserCookieOrder ?? Browser.defaultImportOrder

public enum MiMoCookieImporter {
    private static let cookieClient = BrowserCookieClient()
    private static let cookieDomains = [
        "platform.xiaomimimo.com",
        "xiaomimimo.com",
    ]

    public struct SessionInfo: Sendable {
        public let cookieHeader: String
        public let sourceLabel: String

        public init(cookieHeader: String, sourceLabel: String) {
            self.cookieHeader = cookieHeader
            self.sourceLabel = sourceLabel
        }
    }

    nonisolated(unsafe) static var importSessionsOverrideForTesting:
        ((BrowserDetection, ((String) -> Void)?) throws -> [SessionInfo])?

    public static func importSessions(
        browserDetection: BrowserDetection,
        logger: ((String) -> Void)? = nil) throws -> [SessionInfo]
    {
        if let override = self.importSessionsOverrideForTesting {
            return try override(browserDetection, logger)
        }

        let log: (String) -> Void = { msg in logger?("[mimo-cookie] \(msg)") }
        var sessions: [SessionInfo] = []
        let installed = miMoCookieImportOrder.cookieImportCandidates(using: browserDetection)
        let labels = installed.map(\.displayName).joined(separator: ", ")
        log("Cookie import candidates: \(labels)")

        for browserSource in installed {
            do {
                let query = BrowserCookieQuery(domains: self.cookieDomains)
                let sources = try Self.cookieClient.records(
                    matching: query,
                    in: browserSource,
                    logger: log)

                for source in sources where !source.records.isEmpty {
                    let cookies = BrowserCookieClient.makeHTTPCookies(source.records, origin: query.origin)
                    guard let cookieHeader = MiMoCookieHeader.header(from: cookies) else {
                        continue
                    }
                    sessions.append(SessionInfo(cookieHeader: cookieHeader, sourceLabel: source.label))
                }
            } catch {
                BrowserCookieAccessGate.recordIfNeeded(error)
                log("\(browserSource.displayName) cookie import failed: \(error.localizedDescription)")
            }
        }

        return sessions
    }

    public static func hasSession(
        browserDetection: BrowserDetection,
        logger: ((String) -> Void)? = nil) -> Bool
    {
        (try? self.importSessions(browserDetection: browserDetection, logger: logger).isEmpty == false) ?? false
    }
}
#endif
