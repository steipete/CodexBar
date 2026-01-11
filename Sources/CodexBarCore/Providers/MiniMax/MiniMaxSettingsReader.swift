import Foundation

public struct MiniMaxSettingsReader: Sendable {
    public static let cookieHeaderKeys = [
        "MINIMAX_COOKIE",
        "MINIMAX_COOKIE_HEADER",
    ]
    public static let hostKey = "MINIMAX_HOST"
    public static let codingPlanURLKey = "MINIMAX_CODING_PLAN_URL"
    public static let remainsURLKey = "MINIMAX_REMAINS_URL"

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
        self.cleaned(environment[self.hostKey])
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

    static func cleaned(_ raw: String?) -> String? {
        guard var value = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }

        if (value.hasPrefix("\"") && value.hasSuffix("\"")) ||
            (value.hasPrefix("'") && value.hasSuffix("'"))
        {
            value.removeFirst()
            value.removeLast()
        }

        value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private static func url(from raw: String?) -> URL? {
        guard let cleaned = self.cleaned(raw) else { return nil }
        if let url = URL(string: cleaned), url.scheme != nil {
            return url
        }
        return URL(string: "https://\(cleaned)")
    }
}

public enum MiniMaxSettingsError: LocalizedError, Sendable {
    case missingCookie

    public var errorDescription: String? {
        switch self {
        case .missingCookie:
            "MiniMax session not found. Sign in to platform.minimax.io or platform.minimaxi.com in your browser and try again."
        }
    }
}
