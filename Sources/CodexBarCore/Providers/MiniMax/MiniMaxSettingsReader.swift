import Foundation

public struct MiniMaxSettingsReader: Sendable {
    public static let cookieHeaderKeys = [
        "MINIMAX_COOKIE",
        "MINIMAX_COOKIE_HEADER",
    ]
    public static let hostKey = "MINIMAX_HOST"
    public static let codingPlanURLKey = "MINIMAX_CODING_PLAN_URL"
    public static let remainsURLKey = "MINIMAX_REMAINS_URL"
    public static let billingHistoryURLKey = "MINIMAX_BILLING_HISTORY_URL"

    public static func cookieHeader(
        environment: [String: String] = ProcessInfo.processInfo.environment) -> String?
    {
        for key in self.cookieHeaderKeys {
            guard let raw = environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !raw.isEmpty
            else {
                continue
            }
            if MiniMaxCookieHeader.normalized(from: raw) != nil {
                return raw
            }
        }
        return nil
    }

    public static func hostOverride(environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        guard let raw = self.cleaned(environment[self.hostKey]) else { return nil }
        return self.hasExplicitNonHTTPSURL(raw) ? nil : raw
    }

    public static func codingPlanURL(
        environment: [String: String] = ProcessInfo.processInfo.environment) -> URL?
    {
        self.url(from: environment[self.codingPlanURLKey])
    }

    public static func remainsURL(
        environment: [String: String] = ProcessInfo.processInfo.environment) -> URL?
    {
        self.url(from: environment[self.remainsURLKey])
    }

    public static func billingHistoryURL(
        environment: [String: String] = ProcessInfo.processInfo.environment) -> URL?
    {
        self.url(from: environment[self.billingHistoryURLKey])
    }

    public static func validateEndpointOverrides(
        environment: [String: String] = ProcessInfo.processInfo.environment) throws
    {
        let explicitURLKeys = [self.codingPlanURLKey, self.remainsURLKey, self.billingHistoryURLKey]
        for key in explicitURLKeys where self.hasExplicitNonHTTPSURL(environment[key]) {
            throw MiniMaxSettingsError.invalidEndpointOverride(key)
        }
        if self.hasExplicitNonHTTPSURL(environment[self.hostKey]) {
            throw MiniMaxSettingsError.invalidEndpointOverride(self.hostKey)
        }
    }

    static func cleaned(_ raw: String?) -> String? {
        guard var value = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }

        if (value.hasPrefix("\"") && value.hasSuffix("\"")) ||
            (value.hasPrefix("'") && value.hasSuffix("'"))
        {
            value = String(value.dropFirst().dropLast())
        }

        value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private static func url(from raw: String?) -> URL? {
        guard let cleaned = self.cleaned(raw) else { return nil }
        if self.hasExplicitURLScheme(cleaned) {
            guard let url = URL(string: cleaned), url.scheme?.lowercased() == "https" else { return nil }
            return url
        }
        return URL(string: "https://\(cleaned)")
    }

    private static func hasExplicitNonHTTPSURL(_ raw: String?) -> Bool {
        guard let cleaned = self.cleaned(raw), self.hasExplicitURLScheme(cleaned) else { return false }
        return URL(string: cleaned)?.scheme?.lowercased() != "https"
    }

    static func hasExplicitURLScheme(_ value: String) -> Bool {
        guard let colonIndex = value.firstIndex(of: ":") else { return false }
        let scheme = value[..<colonIndex]
        guard !scheme.isEmpty,
              scheme.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "+" || $0 == "-" || $0 == "." }),
              scheme.first?.isLetter == true
        else { return false }

        let remainder = value[value.index(after: colonIndex)...]
        if remainder.hasPrefix("//") { return true }

        let portCandidate = remainder.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
        return portCandidate.isEmpty || !portCandidate.allSatisfy(\.isNumber)
    }
}

public enum MiniMaxSettingsError: LocalizedError, Sendable, Equatable {
    case missingCookie
    case invalidEndpointOverride(String)

    public var errorDescription: String? {
        switch self {
        case .missingCookie:
            "MiniMax session not found. Sign in to platform.minimax.io or platform.minimaxi.com " +
                "in your browser and try again."
        case let .invalidEndpointOverride(key):
            "MiniMax endpoint override \(key) must use HTTPS or a bare host."
        }
    }
}
