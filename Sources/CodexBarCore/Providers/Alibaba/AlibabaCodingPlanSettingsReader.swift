import Foundation

public struct AlibabaCodingPlanSettingsReader: Sendable {
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
        guard let raw = self.cleaned(environment[self.hostKey]) else { return nil }
        return self.hasExplicitNonHTTPSURL(raw) ? nil : raw
    }

    public static func cookieHeader(
        environment: [String: String] = ProcessInfo.processInfo.environment) -> String?
    {
        self.cleaned(environment[self.cookieHeaderKey])
    }

    public static func quotaURL(
        environment: [String: String] = ProcessInfo.processInfo.environment) -> URL?
    {
        guard let raw = self.cleaned(environment[self.quotaURLKey]) else { return nil }
        if self.hasExplicitURLScheme(raw) {
            guard let url = URL(string: raw), url.scheme?.lowercased() == "https" else { return nil }
            return url
        }
        return URL(string: "https://\(raw)")
    }

    public static func validateEndpointOverrides(
        environment: [String: String] = ProcessInfo.processInfo.environment) throws
    {
        if self.hasExplicitNonHTTPSURL(environment[self.quotaURLKey]) {
            throw AlibabaCodingPlanSettingsError.invalidEndpointOverride(self.quotaURLKey)
        }
        if self.hasExplicitNonHTTPSURL(environment[self.hostKey]) {
            throw AlibabaCodingPlanSettingsError.invalidEndpointOverride(self.hostKey)
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

public enum AlibabaCodingPlanSettingsError: LocalizedError, Sendable, Equatable {
    case missingToken
    case missingCookie(details: String? = nil)
    case invalidCookie
    case invalidEndpointOverride(String)

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
        case let .invalidEndpointOverride(key):
            return "Alibaba Coding Plan endpoint override \(key) must use HTTPS or a bare host."
        }
    }
}
