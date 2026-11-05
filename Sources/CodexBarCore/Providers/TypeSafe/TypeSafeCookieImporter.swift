import Foundation

#if os(macOS)
import SweetCookieKit

enum TypeSafeCookieImporter {
    static func recordsForDestination(_ records: [BrowserCookieRecord]) -> [BrowserCookieRecord] {
        let destinationPath = "/api/billing/overview"
        return records.enumerated().filter { _, record in
            let path = record.path
            guard destinationPath == path ||
                (destinationPath.hasPrefix(path) && (path.hasSuffix("/") ||
                        destinationPath.dropFirst(path.count).first == "/"))
            else { return false }
            let domain = record.domain.lowercased()
            switch record.scope {
            case .hostOnly:
                return domain == "console.typesafe.ai"
            case .domain:
                let normalized = domain.hasPrefix(".") ? String(domain.dropFirst()) : domain
                return normalized == "console.typesafe.ai" || normalized == "typesafe.ai"
            }
        }.sorted {
            let leftLength = $0.element.path.count
            let rightLength = $1.element.path.count
            return leftLength == rightLength ? $0.offset < $1.offset : leftLength > rightLength
        }.map(\.element)
    }

    static func cookieHeader(from records: [BrowserCookieRecord]) -> String {
        self.recordsForDestination(records).map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
    }

    static func cookieQuery(referenceDate: Date = Date()) -> BrowserCookieQuery {
        BrowserCookieQuery(
            domains: ["console.typesafe.ai", "typesafe.ai"],
            domainMatch: .exact,
            includeExpired: false,
            referenceDate: referenceDate)
    }

    private static let cookieClient = BrowserCookieClient()

    static func resolvedImportOrder(_ preferredBrowsers: [Browser]?) -> [Browser] {
        if let preferredBrowsers, !preferredBrowsers.isEmpty { return preferredBrowsers }
        return BrowserCookieImportSupport.importOrder(for: .typesafe)
    }

    static func sessionCandidates(
        browserDetection: BrowserDetection,
        preferredBrowsers: [Browser]? = nil,
        logger: ((String) -> Void)? = nil) throws -> AnySequence<TypeSafeResolvedSession>
    {
        try BrowserCookieImportSupport.collectSessions(
            from: self.resolvedImportOrder(preferredBrowsers).lazyCookieImportCandidates(using: browserDetection),
            missingError: TypeSafeCredentialError.missingCookie,
            logger: { logger?($0) },
            load: { browser in
                try self.cookieClient.codexBarRecords(
                    matching: self.cookieQuery(),
                    in: browser,
                    logger: logger).compactMap { source in
                    let header = self.cookieHeader(from: source.records)
                    guard !header.isEmpty else { return nil }
                    return TypeSafeResolvedSession(cookieHeader: header, sourceLabel: source.label)
                }
            })
    }
}
#endif
