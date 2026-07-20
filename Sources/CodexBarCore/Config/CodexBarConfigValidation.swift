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
    private static let enterpriseHostProviders: [UsageProvider] = [
        .azureopenai,
        .clawrouter,
        .copilot,
        .kimi,
        .litellm,
        .llmproxy,
        .sub2api,
        .wayfinder,
    ]

    private static let workspaceIDProviders: [UsageProvider] = [
        .azureopenai,
        .openai,
        .opencode,
        .opencodego,
        .devin,
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
        self.validateHooks(config.hooks, issues: &issues)

        return issues
    }

    private static func validateHooks(_ hooks: HooksConfig?, issues: inout [CodexBarConfigIssue]) {
        guard let hooks else { return }
        var seenIDs: Set<String> = []

        if hooks.events.count > HooksConfig.maximumRuleCount {
            issues.append(self.hookIssue(
                field: "hooks.events",
                code: "too_many_hook_rules",
                message: "Hooks support at most \(HooksConfig.maximumRuleCount) rules."))
        }

        for (index, rule) in hooks.events.enumerated() {
            let field = "hooks.events[\(index)]"
            if !seenIDs.insert(rule.id).inserted {
                issues.append(self.hookIssue(
                    field: field,
                    code: "duplicate_hook_id",
                    message: "Hook rule IDs must be unique."))
            }
            if !rule.hasValidExecutablePath {
                issues.append(self.hookIssue(
                    field: "\(field).executable",
                    code: "invalid_hook_executable",
                    message: "Hook executables must use a non-empty absolute path."))
            }
            if !rule.hasKnownProvider {
                issues.append(self.hookIssue(
                    field: "\(field).provider",
                    code: "invalid_hook_provider",
                    message: "Hook provider '\(rule.provider ?? "")' is not recognized."))
            }
            if !rule.hasValidThreshold {
                issues.append(self.hookIssue(
                    field: "\(field).threshold",
                    code: "invalid_hook_threshold",
                    message: "Hook thresholds must be greater than 0 and at most 1."))
            }
            if !rule.hasValidTimeout {
                issues.append(self.hookIssue(
                    field: "\(field).timeoutSeconds",
                    code: "invalid_hook_timeout",
                    message: "Hook timeouts must be between 0.1 and 300 seconds."))
            }
            if !rule.hasValidCommandShape {
                issues.append(self.hookIssue(
                    field: field,
                    code: "invalid_hook_command_size",
                    message: "Hook IDs, arguments, or aggregate command size exceed supported limits."))
            }
        }
    }

    private static func hookIssue(field: String, code: String, message: String) -> CodexBarConfigIssue {
        CodexBarConfigIssue(
            severity: .error,
            provider: nil,
            field: field,
            code: code,
            message: message)
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
           self.providerRequiresAPIKey(provider),
           !self.hasConfiguredAPICredential(entry)
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

        self.validateSub2APIBaseURL(entry, issues: &issues)

        self.validateRegion(entry, issues: &issues)

        self.validateZaiTeamContext(entry, issues: &issues)

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
                message: "enterpriseHost is set but only \(self.enterpriseHostProviderList) support enterpriseHost."))
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
              entry.id != .bedrock,
              entry.id != .doubao
        else {
            return
        }

        issues.append(CodexBarConfigIssue(
            severity: .warning,
            provider: entry.id,
            field: "secretKey",
            code: "secret_key_unused",
            message: "secretKey is set but only bedrock and doubao use secretKey."))
    }

    private static func validateSub2APIBaseURL(_ entry: ProviderConfig, issues: inout [CodexBarConfigIssue]) {
        guard entry.id == .sub2api,
              let raw = entry.enterpriseHost?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty,
              Sub2APISettingsReader.baseURL(environment: [Sub2APISettingsReader.baseURLEnvironmentKey: raw]) == nil
        else {
            return
        }

        issues.append(CodexBarConfigIssue(
            severity: .error,
            provider: .sub2api,
            field: "enterpriseHost",
            code: "invalid_enterprise_host",
            message: Sub2APISettingsError.invalidBaseURL.errorDescription ?? "Invalid sub2api base URL."))
    }

    private static func validateZaiTeamContext(_ entry: ProviderConfig, issues: inout [CodexBarConfigIssue]) {
        guard entry.id == .zai else { return }

        guard let tokenAccounts = entry.tokenAccounts else { return }
        for account in tokenAccounts.accounts
            where account.sanitizedUsageScope?.lowercased() == ZaiUsageScope.team.rawValue
        {
            if account.sanitizedOrganizationID == nil || account.sanitizedWorkspaceID == nil {
                issues.append(self.zaiMissingTeamContextIssue(field: "tokenAccounts"))
                return
            }
        }
    }

    private static func zaiMissingTeamContextIssue(field: String) -> CodexBarConfigIssue {
        CodexBarConfigIssue(
            severity: .warning,
            provider: .zai,
            field: field,
            code: "zai_team_context_missing",
            message: "z.ai Team mode requires both organizationID and workspaceID.")
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
        self.enterpriseHostProviders.contains(provider)
    }

    private static func providerRequiresAPIKey(_ provider: UsageProvider) -> Bool {
        provider != .wayfinder
    }

    private static func hasConfiguredAPICredential(_ entry: ProviderConfig) -> Bool {
        if let apiKey = entry.apiKey?.trimmingCharacters(in: .whitespacesAndNewlines), !apiKey.isEmpty {
            return true
        }
        return entry.tokenAccounts?.accounts.contains(where: { account in
            let token = account.token.trimmingCharacters(in: .whitespacesAndNewlines)
            return !token.isEmpty &&
                TokenAccountSupportCatalog.envOverride(for: entry.id, token: token)?.isEmpty == false
        }) == true
    }

    private static var enterpriseHostProviderList: String {
        self.formattedProviderList(self.enterpriseHostProviders)
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
        case .alibabatokenplan:
            self.validateKnownRegion(
                region,
                provider: provider,
                isValid: AlibabaTokenPlanAPIRegion(rawValue: region) != nil,
                displayName: "Alibaba Token Plan",
                issues: &issues)
        case .moonshot:
            self.validateKnownRegion(
                region,
                provider: provider,
                isValid: MoonshotRegion(rawValue: region) != nil,
                displayName: "Moonshot",
                issues: &issues)
        case .bedrock, .doubao:
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
