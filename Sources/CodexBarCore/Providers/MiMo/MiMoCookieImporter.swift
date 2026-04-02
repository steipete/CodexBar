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
        let requestURL = URL(string: "https://platform.xiaomimimo.com/api/v1/balance")!
        var byName: [String: HTTPCookie] = [:]
        for cookie in cookies {
            guard self.knownCookieNames.contains(cookie.name) else { continue }
            guard !cookie.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            if let expiry = cookie.expiresDate, expiry < Date() { continue }
            guard Self.matchesRequestURL(cookie: cookie, url: requestURL) else { continue }

            if let existing = byName[cookie.name] {
                if Self.cookieSortKey(for: cookie) >= Self.cookieSortKey(for: existing) {
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

    private static func matchesRequestURL(cookie: HTTPCookie, url: URL) -> Bool {
        guard let host = url.host else { return false }
        let normalizedDomain = cookie.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard !normalizedDomain.isEmpty else { return false }
        guard host == normalizedDomain || host.hasSuffix(".\(normalizedDomain)") else { return false }

        let cookiePath = cookie.path.isEmpty ? "/" : cookie.path
        let requestPath = url.path.isEmpty ? "/" : url.path
        if requestPath == cookiePath {
            return true
        }
        guard requestPath.hasPrefix(cookiePath) else { return false }
        guard cookiePath != "/" else { return true }
        if cookiePath.hasSuffix("/") {
            return true
        }
        guard
            let boundaryIndex = requestPath.index(
                cookiePath.startIndex,
                offsetBy: cookiePath.count,
                limitedBy: requestPath.endIndex),
            boundaryIndex < requestPath.endIndex
        else {
            return true
        }
        return requestPath[boundaryIndex] == "/"
    }

    private static func cookieSortKey(for cookie: HTTPCookie) -> (Int, Int, Date) {
        let pathLength = cookie.path.count
        let normalizedDomain = cookie.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        let domainLength = normalizedDomain.count
        let expiry = cookie.expiresDate ?? .distantPast
        return (pathLength, domainLength, expiry)
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
                sessions.append(contentsOf: self.sessionInfos(from: sources, origin: query.origin))
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

    static func sessionInfos(
        from sources: [BrowserCookieStoreRecords],
        origin: BrowserCookieOriginStrategy = .domainBased) -> [SessionInfo]
    {
        let grouped = Dictionary(grouping: sources, by: { $0.store.profile.id })
        let sortedGroups = grouped.values.sorted { lhs, rhs in
            self.mergedLabel(for: lhs) < self.mergedLabel(for: rhs)
        }

        var sessions: [SessionInfo] = []
        for group in sortedGroups where !group.isEmpty {
            let label = self.mergedLabel(for: group)
            let mergedRecords = self.mergeRecords(group)
            guard !mergedRecords.isEmpty else { continue }
            let cookies = BrowserCookieClient.makeHTTPCookies(mergedRecords, origin: origin)
            guard let cookieHeader = MiMoCookieHeader.header(from: cookies) else {
                continue
            }
            sessions.append(SessionInfo(cookieHeader: cookieHeader, sourceLabel: label))
        }
        return sessions
    }

    private static func mergedLabel(for sources: [BrowserCookieStoreRecords]) -> String {
        guard let base = sources.map(\.label).min() else {
            return "Unknown"
        }
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
                let key = self.recordKey(record)
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

    private static func recordKey(_ record: BrowserCookieRecord) -> String {
        "\(record.name)|\(record.domain)|\(record.path)"
    }

    private static func shouldReplace(existing: BrowserCookieRecord, candidate: BrowserCookieRecord) -> Bool {
        switch (existing.expires, candidate.expires) {
        case let (lhs?, rhs?):
            rhs > lhs
        case (nil, .some):
            true
        case (.some, nil):
            false
        case (nil, nil):
            false
        }
    }
}
#endif
