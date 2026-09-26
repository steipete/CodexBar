import Foundation

public struct MiniMaxCookieOverride: Sendable {
    public let cookieHeader: String
    public let authorizationToken: String?
    public let groupID: String?

    public init(cookieHeader: String, authorizationToken: String?, groupID: String?) {
        self.cookieHeader = cookieHeader
        self.authorizationToken = authorizationToken
        self.groupID = groupID
    }
}

public enum MiniMaxCookieHeader {
    private static let headerPatterns: [String] = [
        #"(?i)-H\s*'Cookie:\s*([^']+)'"#,
        #"(?i)-H\s*\"Cookie:\s*([^\"]+)\""#,
        #"(?i)\bcookie:\s*'([^']+)'"#,
        #"(?i)\bcookie:\s*\"([^\"]+)\""#,
        #"(?i)\bcookie:\s*([^\r\n]+)"#,
        #"(?i)(?:--cookie|-b)\s*'([^']+)'"#,
        #"(?i)(?:--cookie|-b)\s*\"([^\"]+)\""#,
        #"(?i)(?:--cookie|-b)\s*([^\s]+)"#,
    ]
    private static let authorizationPattern = #"(?i)\bauthorization:\s*bearer\s+([A-Za-z0-9._\-+=/]+)"#
    private static let groupIDPatterns = [
        #"(?i)\bx-group-id:\s*([0-9]{4,})"#,
        #"(?i)\bminimax_group_id_v2=([0-9]{4,})"#,
        #"(?i)\bgroup[_]?id=([0-9]{4,})"#,
    ]

    public static func override(from raw: String?) -> MiniMaxCookieOverride? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty
        else {
            return nil
        }
        guard let cookie = self.normalized(from: raw) else { return nil }
        let authorizationToken = CookieHeaderNormalizer.extractHeader(from: raw, patterns: [self.authorizationPattern])
        let groupID = CookieHeaderNormalizer.extractHeader(from: raw, patterns: self.groupIDPatterns)
        return MiniMaxCookieOverride(
            cookieHeader: cookie,
            authorizationToken: authorizationToken,
            groupID: groupID)
    }

    public static func normalized(from raw: String?) -> String? {
        CookieHeaderNormalizer.normalize(raw, headerPatterns: self.headerPatterns)
    }
}
