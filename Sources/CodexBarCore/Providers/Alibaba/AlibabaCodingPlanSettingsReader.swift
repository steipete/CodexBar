import Foundation

public struct AlibabaCodingPlanSettingsReader: Sendable {
    private static let endpointValidator = ProviderEndpointOverrideValidator(
        allowedHosts: [
            "modelstudio.console.alibabacloud.com",
            "bailian-singapore-cs.alibabacloud.com",
            "bailian.console.aliyun.com",
            "bailian-cs.console.aliyun.com",
            "bailian-beijing-cs.aliyuncs.com",
        ])

    public static let apiTokenKey = "ALIBABA_CODING_PLAN_API_KEY"
    public static let qwenAPITokenKey = "ALIBABA_QWEN_API_KEY"
    public static let dashScopeAPITokenKey = "DASHSCOPE_API_KEY"
    public static let apiTokenEnvironmentKeys = [
        Self.apiTokenKey,
        Self.qwenAPITokenKey,
        Self.dashScopeAPITokenKey,
    ]
    public static let cookieHeaderKey = "ALIBABA_CODING_PLAN_COOKIE"
    public static let hostKey = "ALIBABA_CODING_PLAN_HOST"
    public static let quotaURLKey = "ALIBABA_CODING_PLAN_QUOTA_URL"
    public static let requireProviderEndpointOverridesKey = "ALIBABA_CODING_PLAN_REQUIRE_PROVIDER_ENDPOINT_OVERRIDES"
    private static let endpointOverrideKeys = [
        Self.hostKey,
        Self.quotaURLKey,
    ]

    public static func apiToken(
        environment: [String: String] = ProcessInfo.processInfo.environment) -> String?
    {
        for key in self.apiTokenEnvironmentKeys {
            if let token = self.cleaned(environment[key]) { return token }
        }
        return nil
    }

    public static func hostOverride(
        environment: [String: String] = ProcessInfo.processInfo.environment) -> String?
    {
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

    public static func cookieHeader(
        environment: [String: String] = ProcessInfo.processInfo.environment) -> String?
    {
        self.cleaned(environment[self.cookieHeaderKey])
    }

    public static func quotaURL(
        environment: [String: String] = ProcessInfo.processInfo.environment) -> URL?
    {
        self.endpointValidator.validatedURL(
            self.cleaned(environment[self.quotaURLKey]),
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

public enum AlibabaCodingPlanSettingsError: LocalizedError, Sendable {
    case missingToken
    case missingCookie(details: String? = nil)
    case invalidCookie

    public var errorDescription: String? {
        switch self {
        case .missingToken:
            return "Alibaba Coding Plan API key not found. " +
                "Set apiKey in ~/.codexbar/config.json, ALIBABA_CODING_PLAN_API_KEY, " +
                "ALIBABA_QWEN_API_KEY, or DASHSCOPE_API_KEY."
        case let .missingCookie(details):
            let base = "No Alibaba Coding Plan session cookies found in browsers. " +
                "If you use Safari, enable Full Disk Access for CodexBar/Terminal or paste a manual Cookie header."
            guard let details, !details.isEmpty else { return base }
            return "\(base) \(details)"
        case .invalidCookie:
            return "Alibaba Coding Plan cookie header is invalid."
        }
    }
}
