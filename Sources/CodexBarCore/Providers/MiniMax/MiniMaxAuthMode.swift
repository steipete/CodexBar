import Foundation

public enum MiniMaxAuthMode: Sendable {
    case apiToken
    case cookie
    case none

    public static func resolve(apiToken: String?, cookieHeader: String?) -> MiniMaxAuthMode {
        let cleanedToken = self.cleaned(apiToken)
        let cleanedCookie = self.cleaned(cookieHeader)
        if cleanedToken != nil {
            return .apiToken
        }
        if cleanedCookie != nil {
            return .cookie
        }
        return .none
    }

    public var usesAPIToken: Bool {
        self == .apiToken
    }

    public var usesCookie: Bool {
        self == .cookie
    }

    public var allowsCookies: Bool {
        self != .apiToken
    }

    private static func cleaned(_ raw: String?) -> String? {
        guard let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty
        else {
            return nil
        }
        return value
    }
}
