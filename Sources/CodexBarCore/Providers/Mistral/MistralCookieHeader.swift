import Foundation

public struct MistralCookieOverride: Sendable, Equatable {
    public let cookieHeader: String
    public let csrfToken: String?
    public let sessionCookieName: String

    public init(cookieHeader: String, csrfToken: String?, sessionCookieName: String) {
        self.cookieHeader = cookieHeader
        self.csrfToken = csrfToken
        self.sessionCookieName = sessionCookieName
    }
}

public enum MistralCookieHeader {
    public static func resolveCookieOverride(context: ProviderFetchContext) -> MistralCookieOverride? {
        if let settings = context.settings?.mistral,
           settings.cookieSource == .manual,
           let manual = settings.manualCookieHeader,
           !manual.isEmpty
        {
            return self.override(from: manual, explicitCSRFToken: MistralSettingsReader.csrfToken(environment: context.env))
        }

        if let envCookie = MistralSettingsReader.cookieHeader(environment: context.env) {
            return self.override(from: envCookie, explicitCSRFToken: MistralSettingsReader.csrfToken(environment: context.env))
        }

        return nil
    }

    public static func override(from raw: String?, explicitCSRFToken: String? = nil) -> MistralCookieOverride? {
        guard let normalized = CookieHeaderNormalizer.normalize(raw) else { return nil }
        return self.override(fromNormalizedHeader: normalized, explicitCSRFToken: explicitCSRFToken)
    }

    public static func sessionCookie(from cookies: [HTTPCookie]) -> MistralCookieOverride? {
        let header = cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
        return self.override(fromNormalizedHeader: header)
    }

    public static func override(
        fromNormalizedHeader normalizedHeader: String,
        explicitCSRFToken: String? = nil) -> MistralCookieOverride?
    {
        let pairs = CookieHeaderNormalizer.pairs(from: normalizedHeader)
        guard let sessionPair = pairs.first(where: { self.isSessionCookieName($0.name) }) else {
            return nil
        }

        let csrfToken = explicitCSRFToken
            ?? pairs.first(where: { $0.name.caseInsensitiveCompare("csrftoken") == .orderedSame })?.value
        return MistralCookieOverride(
            cookieHeader: normalizedHeader,
            csrfToken: csrfToken,
            sessionCookieName: sessionPair.name)
    }

    public static func isSessionCookieName(_ name: String) -> Bool {
        name.hasPrefix("ory_session_")
    }
}
