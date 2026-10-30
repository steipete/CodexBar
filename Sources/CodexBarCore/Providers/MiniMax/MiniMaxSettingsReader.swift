import Foundation

public struct MiniMaxSettingsReader: Sendable {
    private static let endpointValidator = ProviderEndpointOverrideValidator(
        allowedDomainSuffixes: ["minimax.io", "minimaxi.com", "minimax.cn"])

    public static let cookieHeaderKeys = [
        "MINIMAX_COOKIE",
        "MINIMAX_COOKIE_HEADER",
    ]
    public static let hostKey = "MINIMAX_HOST"
    public static let codingPlanURLKey = "MINIMAX_CODING_PLAN_URL"
    public static let remainsURLKey = "MINIMAX_REMAINS_URL"
    public static let billingHistoryURLKey = "MINIMAX_BILLING_HISTORY_URL"
    public static let requireProviderEndpointOverridesKey = "MINIMAX_REQUIRE_PROVIDER_ENDPOINT_OVERRIDES"
    private static let endpointOverrideKeys = [
        Self.hostKey,
        Self.codingPlanURLKey,
        Self.remainsURLKey,
        Self.billingHistoryURLKey,
    ]

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
        self.endpointValidator.validatedHost(
            SettingsValue.cleaned(environment[self.hostKey]),
            policy: .init(requireProviderOwned: environment[self.requireProviderEndpointOverridesKey]))
    }

    public static func rejectedEndpointOverrideKey(
        environment: [String: String] = ProcessInfo.processInfo.environment) -> String?
    {
        self.endpointValidator.rejectedOverrideKey(
            environment: environment,
            keys: self.endpointOverrideKeys,
            hostKey: self.hostKey,
            policy: .init(requireProviderOwned: environment[self.requireProviderEndpointOverridesKey]))
    }

    public static func codingPlanURL(
        environment: [String: String] = ProcessInfo.processInfo.environment) -> URL?
    {
        self.endpointValidator.validatedURL(
            SettingsValue.cleaned(environment[self.codingPlanURLKey]),
            policy: .init(requireProviderOwned: environment[self.requireProviderEndpointOverridesKey]))
    }

    public static func remainsURL(
        environment: [String: String] = ProcessInfo.processInfo.environment) -> URL?
    {
        self.endpointValidator.validatedURL(
            SettingsValue.cleaned(environment[self.remainsURLKey]),
            policy: .init(requireProviderOwned: environment[self.requireProviderEndpointOverridesKey]))
    }

    public static func billingHistoryURL(
        environment: [String: String] = ProcessInfo.processInfo.environment) -> URL?
    {
        self.endpointValidator.validatedURL(
            SettingsValue.cleaned(environment[self.billingHistoryURLKey]),
            policy: .init(requireProviderOwned: environment[self.requireProviderEndpointOverridesKey]))
    }
}

public enum MiniMaxSettingsError: LocalizedError, Sendable {
    case missingCookie

    public var errorDescription: String? {
        switch self {
        case .missingCookie:
            "MiniMax session not found. Sign in to platform.minimax.io or platform.minimaxi.com " +
                "in your browser and try again."
        }
    }
}
