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
    private static let workspaceIDProviders: [UsageProvider] = [
        .azureopenai,
        .openai,
        .opencode,
        .opencodego,
        .deepgram,
    ]

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

        self.validateSecretKey(entry, issues: &issues)

        self.validateRegion(entry, issues: &issues)

        if let workspaceID = entry.workspaceID,
           !workspaceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           !self.providerSupportsWorkspaceID(provider)
        {
            issues.append(CodexBarConfigIssue(
                severity: .warning,
                provider: provider,
                field: "workspaceID",
                code: "workspace_unused",
                message: "workspaceID is set but only \(self.workspaceIDProviderList) support workspaceID."))
        }

        if let enterpriseHost = entry.enterpriseHost,
           !enterpriseHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           !self.providerSupportsEnterpriseHost(provider)
        {
            issues.append(CodexBarConfigIssue(
                severity: .warning,
                provider: provider,
                field: "enterpriseHost",
                code: "enterprise_host_unused",
                message: "enterpriseHost is set but only azureopenai, copilot, and llmproxy support enterpriseHost."))
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

    private static func validateSecretKey(_ entry: ProviderConfig, issues: inout [CodexBarConfigIssue]) {
        guard let secretKey = entry.secretKey,
              !secretKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              entry.id != .bedrock
        else {
            return
        }

        issues.append(CodexBarConfigIssue(
            severity: .warning,
            provider: entry.id,
            field: "secretKey",
            code: "secret_key_unused",
            message: "secretKey is set but only bedrock uses secretKey."))
    }

    private static func providerSupportsWorkspaceID(_ provider: UsageProvider) -> Bool {
        self.workspaceIDProviders.contains(provider)
    }

    private static var workspaceIDProviderList: String {
        self.formattedProviderList(self.workspaceIDProviders)
    }

    private static func formattedProviderList(_ providers: [UsageProvider]) -> String {
        let names = providers.map(\.rawValue)
        guard let last = names.last else { return "" }
        guard names.count > 1 else { return last }
        return "\(names.dropLast().joined(separator: ", ")), and \(last)"
    }

    private static func providerSupportsEnterpriseHost(_ provider: UsageProvider) -> Bool {
        switch provider {
        case .azureopenai, .copilot, .llmproxy:
            true
        default:
            false
        }
    }

    private static func validateRegion(_ entry: ProviderConfig, issues: inout [CodexBarConfigIssue]) {
        let provider = entry.id
        guard let region = entry.region?.trimmingCharacters(in: .whitespacesAndNewlines),
              !region.isEmpty
        else {
            return
        }

        switch provider {
        case .minimax:
            self.validateKnownRegion(
                region,
                provider: provider,
                isValid: MiniMaxAPIRegion(rawValue: region) != nil,
                displayName: "MiniMax",
                issues: &issues)
        case .zai:
            self.validateKnownRegion(
                region,
                provider: provider,
                isValid: ZaiAPIRegion(rawValue: region) != nil,
                displayName: "z.ai",
                issues: &issues)
        case .alibaba:
            self.validateKnownRegion(
                region,
                provider: provider,
                isValid: AlibabaCodingPlanAPIRegion(rawValue: region) != nil,
                displayName: "Alibaba Coding Plan",
                issues: &issues)
        case .moonshot:
            self.validateKnownRegion(
                region,
                provider: provider,
                isValid: MoonshotRegion(rawValue: region) != nil,
                displayName: "Moonshot",
                issues: &issues)
        case .bedrock:
            break
        default:
            issues.append(CodexBarConfigIssue(
                severity: .warning,
                provider: provider,
                field: "region",
                code: "region_unused",
                message: "region is set but \(provider.rawValue) does not use regions."))
        }
    }

    private static func validateKnownRegion(
        _ region: String,
        provider: UsageProvider,
        isValid: Bool,
        displayName: String,
        issues: inout [CodexBarConfigIssue])
    {
        guard !isValid else { return }
        issues.append(CodexBarConfigIssue(
            severity: .error,
            provider: provider,
            field: "region",
            code: "invalid_region",
            message: "Region \(region) is not a valid \(displayName) region."))
    }
}
