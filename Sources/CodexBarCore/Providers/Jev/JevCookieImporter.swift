import Foundation

#if os(macOS)
import SweetCookieKit

public enum JevCookieImporter {
    private static let cookieClient = BrowserCookieClient()
    private static let domains = ["console.typesafe.ai", "typesafe.ai"]
    private static let importOrder = ProviderDefaults.metadata[.jev]?.browserCookieOrder
        ?? Browser.defaultImportOrder

    public struct SessionInfo: Sendable {
        public let cookieHeader: String
        public let sourceLabel: String
    }

    public static func importSessions(
        browserDetection: BrowserDetection = BrowserDetection()) throws -> [SessionInfo]
    {
        var sessions: [SessionInfo] = []
        for browser in self.importOrder.cookieImportCandidates(using: browserDetection) {
            let query = BrowserCookieQuery(domains: self.domains)
            let records = try? self.cookieClient.codexBarRecords(matching: query, in: browser)
            for profile in BrowserCookieProfiles.merge(records ?? []) where !profile.records.isEmpty {
                let cookies = BrowserCookieClient.makeHTTPCookies(profile.records, origin: query.origin)
                let header = cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
                if !header.isEmpty {
                    sessions.append(SessionInfo(cookieHeader: header, sourceLabel: profile.label))
                }
            }
        }
        return sessions
    }
}
#endif
