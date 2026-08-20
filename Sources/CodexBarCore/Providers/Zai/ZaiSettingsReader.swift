import Foundation

public struct ZaiSettingsReader: Sendable {
    private static let log = CodexBarLog.logger(LogCategories.provider(.zai, scope: "settings"))

    public static let apiTokenKey = "Z_AI_API_KEY"
    public static let bigModelAPITokenKeys = [
        "BIGMODEL_API_KEY",
        "ZHIPU_API_KEY",
        "ZHIPUAI_API_KEY",
        "GLM_API_KEY",
    ]
    public static let bigModelAPIKeyRelativePaths = [
        ".coding-relay/glm-api-key",
        ".config/bigmodel/api_key",
        ".config/zhipu/api_key",
    ]
    public static let apiHostKey = "Z_AI_API_HOST"
    public static let quotaURLKey = "Z_AI_QUOTA_URL"
    public static let balanceURLKey = "Z_AI_BALANCE_URL"
    public static let bigModelOrganizationKey = "Z_AI_BIGMODEL_ORGANIZATION"
    public static let bigModelProjectKey = "Z_AI_BIGMODEL_PROJECT"

    public static func apiToken(
        environment: [String: String] = ProcessInfo.processInfo.environment) -> String?
    {
        self.apiToken(for: self.inferredRegion(environment: environment), environment: environment)
    }

    public static func apiToken(
        for region: ZaiAPIRegion,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> String?
    {
        if let token = self.cleaned(environment[self.apiTokenKey]) {
            return token
        }
        guard region == .bigmodelCN else { return nil }
        for key in self.bigModelAPITokenKeys {
            if let token = self.cleaned(environment[key]) {
                return token
            }
        }
        for relativePath in self.bigModelAPIKeyRelativePaths {
            let url = homeDirectory.appendingPathComponent(relativePath, isDirectory: false)
            guard FileManager.default.isReadableFile(atPath: url.path),
                  let raw = try? String(contentsOf: url, encoding: .utf8),
                  let token = self.cleaned(raw.split(whereSeparator: \.isNewline).first.map(String.init))
            else { continue }
            return token
        }
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

    public static func balanceURL(
        environment: [String: String] = ProcessInfo.processInfo.environment) -> URL?
    {
        guard let raw = self.cleaned(environment[balanceURLKey]) else { return nil }
        return ProviderEndpointOverrideValidator.normalizedHTTPSURL(from: raw)
    }

    public static func validateEndpointOverrides(
        environment: [String: String] = ProcessInfo.processInfo.environment) throws
    {
        try self.validateQuotaEndpointOverride(environment: environment)
        try self.validateAPIHostEndpointOverride(environment: environment)
        if let raw = self.cleaned(environment[balanceURLKey]),
           self.balanceURL(environment: environment) == nil
        {
            throw ZaiSettingsError.invalidEndpointOverride(self.balanceURLKey)
        }
    }

    public static func validateEndpointOverrides(
        region: ZaiAPIRegion,
        environment: [String: String] = ProcessInfo.processInfo.environment) throws
    {
        try self.validateQuotaEndpointOverride(region: region, environment: environment)
        try self.validateAPIHostEndpointOverride(region: region, environment: environment)
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

    public static func validateQuotaEndpointOverride(
        region: ZaiAPIRegion,
        environment: [String: String] = ProcessInfo.processInfo.environment) throws
    {
        try self.validateQuotaEndpointOverride(environment: environment)
        if let url = self.quotaURL(environment: environment) {
            try self.validateKnownHost(url, region: region, key: self.quotaURLKey)
            return
        }
        if let raw = self.apiHost(environment: environment),
           let url = ProviderEndpointOverrideValidator.normalizedHTTPSURL(from: raw)
        {
            try self.validateKnownHost(url, region: region, key: self.apiHostKey)
        }
    }

    public static func validateAPIHostEndpointOverride(
        environment: [String: String] = ProcessInfo.processInfo.environment) throws
    {
        guard let raw = self.cleaned(environment[self.apiHostKey]) else { return }
        guard ProviderEndpointOverrideValidator.normalizedHTTPSURL(from: raw) != nil else {
            throw ZaiSettingsError.invalidEndpointOverride(self.apiHostKey)
        }
    }

    public static func validateAPIHostEndpointOverride(
        region: ZaiAPIRegion,
        environment: [String: String] = ProcessInfo.processInfo.environment) throws
    {
        try self.validateAPIHostEndpointOverride(environment: environment)
        guard let raw = self.apiHost(environment: environment),
              let url = ProviderEndpointOverrideValidator.normalizedHTTPSURL(from: raw)
        else { return }
        try self.validateKnownHost(url, region: region, key: self.apiHostKey)
    }

    private static func inferredRegion(environment: [String: String]) -> ZaiAPIRegion {
        let host = self.quotaURL(environment: environment)?.host?.lowercased()
            ?? self.apiHost(environment: environment)
            .flatMap { ProviderEndpointOverrideValidator.normalizedHTTPSURL(from: $0)?.host?.lowercased() }
        return host == ZaiAPIRegion.bigmodelCN.quotaLimitURL.host?.lowercased() ? .bigmodelCN : .global
    }

    private static func validateKnownHost(_ url: URL, region: ZaiAPIRegion, key: String) throws {
        let host = url.host?.lowercased()
        let globalHost = ZaiAPIRegion.global.quotaLimitURL.host?.lowercased()
        let chinaHost = ZaiAPIRegion.bigmodelCN.quotaLimitURL.host?.lowercased()
        guard host == globalHost || host == chinaHost else { return }
        guard host == region.quotaLimitURL.host?.lowercased() else {
            throw ZaiSettingsError.endpointRegionMismatch(key, region)
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
    case endpointRegionMismatch(String, ZaiAPIRegion)

    public var errorDescription: String? {
        switch self {
        case .missingToken:
            "z.ai API token not found. Set apiKey in ~/.codexbar/config.json or Z_AI_API_KEY."
        case let .invalidEndpointOverride(key):
            "z.ai endpoint override \(key) must use HTTPS or a bare host."
        case let .endpointRegionMismatch(key, region):
            "z.ai endpoint override \(key) does not match the selected \(region.displayName) region."
        }
    }
}
