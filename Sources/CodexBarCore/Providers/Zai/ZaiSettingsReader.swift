import Foundation

public struct ZaiSettingsReader: Sendable {
    private static let log = CodexBarLog.logger(LogCategories.zaiSettings)

    public static let apiTokenKey = "Z_AI_API_KEY"
    public static let apiHostKey = "Z_AI_API_HOST"
    public static let quotaURLKey = "Z_AI_QUOTA_URL"
    public static let bigModelOrganizationKey = "Z_AI_BIGMODEL_ORGANIZATION"
    public static let bigModelProjectKey = "Z_AI_BIGMODEL_PROJECT"

    public static func apiToken(
        environment: [String: String] = ProcessInfo.processInfo.environment) -> String?
    {
        if let token = self.cleaned(environment[apiTokenKey]) { return token }
        return nil
    }

    public static func apiHost(
        environment: [String: String] = ProcessInfo.processInfo.environment) -> String?
    {
        self.cleaned(environment[self.apiHostKey])
    }

    public static func quotaURL(
        environment: [String: String] = ProcessInfo.processInfo.environment) -> URL?
    {
        guard let raw = self.cleaned(environment[quotaURLKey]) else { return nil }
        return ProviderEndpointOverrideValidator.normalizedHTTPSURL(from: raw)
    }

    public static func validateEndpointOverrides(
        environment: [String: String] = ProcessInfo.processInfo.environment) throws
    {
        try self.validateQuotaEndpointOverride(environment: environment)
        try self.validateAPIHostEndpointOverride(environment: environment)
    }

    public static func validateQuotaEndpointOverride(
        environment: [String: String] = ProcessInfo.processInfo.environment) throws
    {
        if let raw = self.cleaned(environment[self.quotaURLKey]) {
            guard ProviderEndpointOverrideValidator.normalizedHTTPSURL(from: raw) != nil else {
                throw ZaiSettingsError.invalidEndpointOverride(self.quotaURLKey)
            }
            return
        }

        try self.validateAPIHostEndpointOverride(environment: environment)
    }

    public static func validateAPIHostEndpointOverride(
        environment: [String: String] = ProcessInfo.processInfo.environment) throws
    {
        guard let raw = self.cleaned(environment[self.apiHostKey]) else { return }
        guard ProviderEndpointOverrideValidator.normalizedHTTPSURL(from: raw) != nil else {
            throw ZaiSettingsError.invalidEndpointOverride(self.apiHostKey)
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
}

public enum ZaiSettingsError: LocalizedError, Sendable, Equatable {
    case missingToken
    case invalidEndpointOverride(String)

    public var errorDescription: String? {
        switch self {
        case .missingToken:
            "z.ai API token not found. Set apiKey in ~/.codexbar/config.json or Z_AI_API_KEY."
        case let .invalidEndpointOverride(key):
            "z.ai endpoint override \(key) must use HTTPS or a bare host."
        }
    }
}
