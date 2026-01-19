import Foundation

public enum CodexBarConfigIssueSeverity: String, Codable, Sendable {
    case warning
    case error
}

public struct CodexBarConfigIssue: Codable, Sendable, Equatable {
    public let severity: CodexBarConfigIssueSeverity
    public let provider: UsageProvider?
    public let field: String?
    public let code: String
    public let message: String

    public init(
        severity: CodexBarConfigIssueSeverity,
        provider: UsageProvider?,
        field: String?,
        code: String,
        message: String)
    {
        self.severity = severity
        self.provider = provider
        self.field = field
        self.code = code
        self.message = message
    }
}

public enum CodexBarConfigValidator {
    public static func validate(_ config: CodexBarConfig) -> [CodexBarConfigIssue] {
        var issues: [CodexBarConfigIssue] = []

        if config.version != CodexBarConfig.currentVersion {
            issues.append(CodexBarConfigIssue(
                severity: .error,
                provider: nil,
                field: "version",
                code: "version_mismatch",
                message: "Unsupported config version \(config.version)."))
        }

        for entry in config.providers {
            self.validateProvider(entry, issues: &issues)
        }

        return issues
    }

    private static func validateProvider(_ entry: ProviderConfig, issues: inout [CodexBarConfigIssue]) {
        let provider = entry.id
        let descriptor = ProviderDescriptorRegistry.descriptor(for: provider)
        let supportedSources = descriptor.fetchPlan.sourceModes
        let supportsWeb = supportedSources.contains(.auto) || supportedSources.contains(.web)
        let supportsAPI = supportedSources.contains(.api)

        if let source = entry.source, !supportedSources.contains(source) {
            issues.append(CodexBarConfigIssue(
                severity: .error,
                provider: provider,
                field: "source",
                code: "unsupported_source",
                message: "Source \(source.rawValue) is not supported for \(provider.rawValue)."))
        }

        if let apiKey = entry.apiKey, !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !supportsAPI {
            issues.append(CodexBarConfigIssue(
                severity: .warning,
                provider: provider,
                field: "apiKey",
                code: "api_key_unused",
                message: "apiKey is set but \(provider.rawValue) does not support api source."))
        }

        if let source = entry.source, source == .api, !supportsAPI {
            issues.append(CodexBarConfigIssue(
                severity: .error,
                provider: provider,
                field: "source",
                code: "api_source_unsupported",
                message: "Source api is not supported for \(provider.rawValue)."))
        }

        if let source = entry.source, source == .api,
           entry.apiKey?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true
        {
            issues.append(CodexBarConfigIssue(
                severity: .warning,
                provider: provider,
                field: "apiKey",
                code: "api_key_missing",
                message: "Source api is selected but apiKey is missing for \(provider.rawValue)."))
        }

        if entry.cookieSource != nil, !supportsWeb {
            issues.append(CodexBarConfigIssue(
                severity: .warning,
                provider: provider,
                field: "cookieSource",
                code: "cookie_source_unused",
                message: "cookieSource is set but \(provider.rawValue) does not use web cookies."))
        }

        if let cookieHeader = entry.cookieHeader,
           !cookieHeader.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           !supportsWeb
        {
            issues.append(CodexBarConfigIssue(
                severity: .warning,
                provider: provider,
                field: "cookieHeader",
                code: "cookie_header_unused",
                message: "cookieHeader is set but \(provider.rawValue) does not use web cookies."))
        }

        if let cookieSource = entry.cookieSource,
           cookieSource == .manual,
           entry.cookieHeader?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true
        {
            issues.append(CodexBarConfigIssue(
                severity: .warning,
                provider: provider,
                field: "cookieHeader",
                code: "cookie_header_missing",
                message: "cookieSource manual is set but cookieHeader is missing for \(provider.rawValue)."))
        }

        if let region = entry.region, !region.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            switch provider {
            case .minimax:
                if MiniMaxAPIRegion(rawValue: region) == nil {
                    issues.append(CodexBarConfigIssue(
                        severity: .error,
                        provider: provider,
                        field: "region",
                        code: "invalid_region",
                        message: "Region \(region) is not a valid MiniMax region."))
                }
            case .zai:
                if ZaiAPIRegion(rawValue: region) == nil {
                    issues.append(CodexBarConfigIssue(
                        severity: .error,
                        provider: provider,
                        field: "region",
                        code: "invalid_region",
                        message: "Region \(region) is not a valid z.ai region."))
                }
            default:
                issues.append(CodexBarConfigIssue(
                    severity: .warning,
                    provider: provider,
                    field: "region",
                    code: "region_unused",
                    message: "region is set but \(provider.rawValue) does not use regions."))
            }
        }

        if let workspaceID = entry.workspaceID,
           !workspaceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           provider != .opencode
        {
            issues.append(CodexBarConfigIssue(
                severity: .warning,
                provider: provider,
                field: "workspaceID",
                code: "workspace_unused",
                message: "workspaceID is set but only opencode supports workspaceID."))
        }

        if let tokenAccounts = entry.tokenAccounts, !tokenAccounts.accounts.isEmpty,
           TokenAccountSupportCatalog.support(for: provider) == nil
        {
            issues.append(CodexBarConfigIssue(
                severity: .warning,
                provider: provider,
                field: "tokenAccounts",
                code: "token_accounts_unused",
                message: "tokenAccounts are set but \(provider.rawValue) does not support token accounts."))
        }
    }
}
