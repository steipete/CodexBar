import Foundation

public struct MiniMaxSettingsReader: Sendable {
    private static let endpointValidator = ProviderEndpointOverrideValidator(
        allowedDomainSuffixes: ["minimax.io", "minimaxi.com"])

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
            self.cleaned(environment[self.hostKey]),
            policy: self.endpointOverrideHostPolicy(environment: environment))
    }

    public static func rejectedEndpointOverrideKey(
        environment: [String: String] = ProcessInfo.processInfo.environment) -> String?
    {
        let policy = self.endpointOverrideHostPolicy(environment: environment)
        return self.endpointOverrideKeys.first { key in
            guard let value = self.cleaned(environment[key]) else { return false }
            if key == Self.hostKey {
                return self.endpointValidator.validatedHost(value, policy: policy) == nil
            }
            return self.endpointValidator.validatedURL(value, policy: policy) == nil
        }
    }

    public static func codingPlanURL(
        environment: [String: String] = ProcessInfo.processInfo.environment) -> URL?
    {
        self.endpointValidator.validatedURL(
            self.cleaned(environment[self.codingPlanURLKey]),
            policy: self.endpointOverrideHostPolicy(environment: environment))
    }

    public static func remainsURL(
        environment: [String: String] = ProcessInfo.processInfo.environment) -> URL?
    {
        self.endpointValidator.validatedURL(
            self.cleaned(environment[self.remainsURLKey]),
            policy: self.endpointOverrideHostPolicy(environment: environment))
    }

    public static func billingHistoryURL(
        environment: [String: String] = ProcessInfo.processInfo.environment) -> URL?
    {
        self.endpointValidator.validatedURL(
            self.cleaned(environment[self.billingHistoryURLKey]),
            policy: self.endpointOverrideHostPolicy(environment: environment))
    }

    static func endpointOverrideHostPolicy(environment: [String: String]) -> ProviderEndpointOverrideValidator
    .HostPolicy {
        guard let value = self.cleaned(environment[self.requireProviderEndpointOverridesKey])?.lowercased(),
              ["1", "true", "yes", "on"].contains(value)
        else { return .allowAnyHTTPSHost }
        return .providerOwnedOnly
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
