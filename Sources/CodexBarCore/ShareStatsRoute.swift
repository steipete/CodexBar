import Foundation

/// The only widget-to-app route for the aggregate Usage & Spend share preview.
/// It deliberately carries no provider, account, usage, spend, callback, or file data.
public enum ShareStatsRoute: Sendable, Equatable {
    case overview

    public static let overviewURL = URL(string: "codexbar://share-stats?version=1")!

    /// Validated component by component rather than by comparing the whole string. An exact
    /// string compare made every check below it unreachable, and it rejected the case variants
    /// the scheme is allowed to arrive in, despite the case-insensitive comparisons here.
    public static func parse(_ url: URL) -> Self? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.caseInsensitiveCompare("codexbar") == .orderedSame,
              components.host?.caseInsensitiveCompare("share-stats") == .orderedSame,
              components.port == nil,
              components.user == nil,
              components.password == nil,
              components.path.isEmpty,
              components.fragment == nil,
              // Raw, not queryItems: URLComponents percent-decodes, so "version=%31" would
              // otherwise read as "version=1" and slip through.
              components.percentEncodedQuery == "version=1"
        else { return nil }
        return .overview
    }
}
