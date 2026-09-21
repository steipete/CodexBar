import Foundation

#if os(macOS)
import SweetCookieKit

enum TypeSafeCookieImporter {
    static func recordsForDestination(_ records: [BrowserCookieRecord]) -> [BrowserCookieRecord] {
        let destinationPath = "/settings/billing"
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
        guard let preferredBrowsers, !preferredBrowsers.isEmpty else { return [.chrome] }
        return preferredBrowsers
    }

    static func importSessions(
        browserDetection: BrowserDetection,
        preferredBrowsers: [Browser]? = nil,
        logger: ((String) -> Void)? = nil) throws -> [TypeSafeResolvedSession]
    {
        var sessions: [TypeSafeResolvedSession] = []
        for browser in self.resolvedImportOrder(preferredBrowsers).cookieImportCandidates(using: browserDetection) {
            do {
                let sources = try self.cookieClient.codexBarRecords(
                    matching: self.cookieQuery(),
                    in: browser,
                    logger: logger)
                for source in sources {
                    let header = self.cookieHeader(from: source.records)
                    guard !header.isEmpty else { continue }
                    sessions.append(TypeSafeResolvedSession(cookieHeader: header, sourceLabel: source.label))
                }
            } catch {
                BrowserCookieAccessGate.recordIfNeeded(error)
            }
        }
        guard !sessions.isEmpty else { throw TypeSafeCredentialError.missingCookie }
        return sessions
    }
}
#endif
