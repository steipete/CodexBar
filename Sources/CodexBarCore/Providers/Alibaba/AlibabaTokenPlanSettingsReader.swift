import Foundation

public struct AlibabaTokenPlanSettingsReader: Sendable {
    public static let cookieHeaderKey = "ALIBABA_TOKEN_PLAN_COOKIE"
    public static let hostKey = "ALIBABA_TOKEN_PLAN_HOST"
    public static let quotaURLKey = "ALIBABA_TOKEN_PLAN_QUOTA_URL"

    private static let endpointValidator = ProviderEndpointOverrideValidator(
        allowedHosts: [
            "modelstudio.console.alibabacloud.com",
            "bailian.console.aliyun.com",
        ])

    public static func cookieHeader(
        environment: [String: String] = ProcessInfo.processInfo.environment) -> String?
    {
        self.cleaned(environment[self.cookieHeaderKey])
    }

    public static func hostOverride(
        environment: [String: String] = ProcessInfo.processInfo.environment) -> String?
    {
        self.endpointValidator.validatedHost(
            self.cleaned(environment[self.hostKey]),
            policy: .allowAnyHTTPSHost)
    }

    public static func quotaURL(
        environment: [String: String] = ProcessInfo.processInfo.environment) -> URL?
    {
        self.endpointValidator.validatedURL(
            self.cleaned(environment[self.quotaURLKey]),
            policy: .allowAnyHTTPSHost)
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

public enum AlibabaTokenPlanSettingsError: LocalizedError, Sendable {
    case missingCookie(details: String? = nil)
    case invalidCookie

    public var errorDescription: String? {
        switch self {
        case let .missingCookie(details):
            let base = "No Alibaba Token Plan session cookies found in browsers. " +
                "Sign in to Model Studio/Bailian in Chrome, " +
                "allow CodexBar to access Chrome Safe Storage in Keychain Access, " +
                "or paste a manual Cookie header."
            guard let details, !details.isEmpty else { return base }
            return "\(base) \(details)"
        case .invalidCookie:
            return "Alibaba Token Plan cookie header is invalid."
        }
    }
}
