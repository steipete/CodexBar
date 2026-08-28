import Foundation

public struct ProviderCredentialEnvironmentProjection: Sendable {
    public enum Precedence: Sendable {
        case config
        case environment
    }

    public let key: String
    public let precedence: Precedence
    private let value: @Sendable (ProviderConfig) -> String?
    private let environmentHasValue: @Sendable ([String: String]) -> Bool

    public init(
        key: String,
        precedence: Precedence = .config,
        value: @escaping @Sendable (ProviderConfig) -> String?,
        environmentHasValue: @escaping @Sendable ([String: String]) -> Bool = { _ in false })
    {
        self.key = key
        self.precedence = precedence
        self.value = value
        self.environmentHasValue = environmentHasValue
    }

    func apply(config: ProviderConfig, base: [String: String], environment: inout [String: String]) {
        guard let value = self.value(config) else { return }
        if self.precedence == .environment, self.environmentHasValue(base) {
            return
        }
        environment[self.key] = value
    }
}

public enum ProviderCredentialResolutionKind: Sendable {
    case primary
    case secondary
    case projectID
}

public struct ProviderCredentialSettingsContext: Sendable {
    public let config: ProviderConfig?
    public let account: ProviderTokenAccount?

    public init(config: ProviderConfig?, account: ProviderTokenAccount?) {
        self.config = config
        self.account = account
    }

    public func cookieSettings(
        for provider: UsageProvider,
        configuredHeader: String? = nil) -> CookieProviderSettings
    {
        let configuredSource: ProviderCookieSource = if let override = self.config?.cookieSource {
            override
        } else if provider == .stepfun, self.config?.sanitizedRegion != nil {
            .manual
        } else if self.config?.sanitizedCookieHeader != nil {
            .manual
        } else {
            .auto
        }
        return ProviderCookieSettingsResolver.resolve(
            provider: provider,
            configuredSource: configuredSource,
            configuredHeader: configuredHeader ?? self.config?.sanitizedCookieHeader,
            selectedAccount: self.account)
    }
}

public struct ProviderCredentialAdapter: Sendable {
    public typealias EnvironmentOverride = @Sendable (
        _ base: [String: String],
        _ config: ProviderConfig?) -> [String: String]
    public typealias TokenResolver = @Sendable (
        _ kind: ProviderCredentialResolutionKind,
        _ environment: [String: String],
        _ authFileURL: URL?) -> ProviderTokenResolution?
    public typealias AuthDetector = @Sendable (
        _ environment: [String: String],
        _ settings: ProviderSettingsSnapshot?) -> [String]
    public typealias DiagnosticSummary = @Sendable (
        _ account: ProviderTokenAccount?,
        _ config: ProviderConfig?,
        _ environment: [String: String],
        _ settings: ProviderSettingsSnapshot?) -> ProviderDiagnosticAuthSummary
    public typealias ConfigValidator = @Sendable (_ config: ProviderConfig) -> [CodexBarConfigIssue]
    public typealias MissingCredentialMessage = @Sendable (_ environment: [String: String]) -> String?
    public typealias AccountEnvironmentOverride = @Sendable (
        _ environment: inout [String: String],
        _ account: ProviderTokenAccount) -> Void
    public typealias SelectedAccountSourceModeResolver = @Sendable (
        _ base: ProviderSourceMode,
        _ account: ProviderTokenAccount?,
        _ config: ProviderConfig?) -> ProviderSourceMode
    public typealias ManualTokenPersister = @Sendable (_ token: String) throws -> Void

    public let supportsAPIKeyOverride: Bool
    public let requiresAPIKeyForAPISource: Bool
    public let usesRegion: Bool
    public let usesSecretKey: Bool
    public let apiKeyDebugLabel: String?
    public let environmentProjections: [ProviderCredentialEnvironmentProjection]
    public let tokenAccountSupport: TokenAccountSupport?
    private let environmentOverride: EnvironmentOverride?
    private let tokenResolver: TokenResolver
    private let authDetector: AuthDetector
    private let diagnosticSummary: DiagnosticSummary?
    private let configValidator: ConfigValidator
    private let missingCredentialMessage: MissingCredentialMessage?
    private let accountEnvironmentOverride: AccountEnvironmentOverride
    private let selectedAccountSourceModeResolver: SelectedAccountSourceModeResolver
    private let manualTokenPersister: ManualTokenPersister?

    public init(
        supportsAPIKeyOverride: Bool = false,
        requiresAPIKeyForAPISource: Bool = true,
        usesRegion: Bool = false,
        usesSecretKey: Bool = false,
        apiKeyDebugLabel: String? = nil,
        environmentProjections: [ProviderCredentialEnvironmentProjection] = [],
        environmentOverride: EnvironmentOverride? = nil,
        tokenResolver: @escaping TokenResolver = { _, _, _ in nil },
        tokenAccountSupport: TokenAccountSupport? = nil,
        authDetector: @escaping AuthDetector = { _, _ in [] },
        diagnosticSummary: DiagnosticSummary? = nil,
        configValidator: @escaping ConfigValidator = { _ in [] },
        missingCredentialMessage: MissingCredentialMessage? = nil,
        accountEnvironmentOverride: @escaping AccountEnvironmentOverride = { _, _ in },
        selectedAccountSourceModeResolver: @escaping SelectedAccountSourceModeResolver = { base, _, _ in base },
        manualTokenPersister: ManualTokenPersister? = nil)
    {
        self.supportsAPIKeyOverride = supportsAPIKeyOverride
        self.requiresAPIKeyForAPISource = requiresAPIKeyForAPISource
        self.usesRegion = usesRegion
        self.usesSecretKey = usesSecretKey
        self.apiKeyDebugLabel = apiKeyDebugLabel
        self.environmentProjections = environmentProjections
        self.environmentOverride = environmentOverride
        self.tokenResolver = tokenResolver
        self.tokenAccountSupport = tokenAccountSupport
        self.authDetector = authDetector
        self.diagnosticSummary = diagnosticSummary
        self.configValidator = configValidator
        self.missingCredentialMessage = missingCredentialMessage
        self.accountEnvironmentOverride = accountEnvironmentOverride
        self.selectedAccountSourceModeResolver = selectedAccountSourceModeResolver
        self.manualTokenPersister = manualTokenPersister
    }

    public func applyConfig(base: [String: String], config: ProviderConfig?) -> [String: String] {
        if let environmentOverride {
            return environmentOverride(base, config)
        }
        guard let config else { return base }
        var environment = base
        for projection in self.environmentProjections {
            projection.apply(config: config, base: base, environment: &environment)
        }
        return environment
    }

    public func resolveToken(
        kind: ProviderCredentialResolutionKind = .primary,
        environment: [String: String],
        authFileURL: URL? = nil) -> ProviderTokenResolution?
    {
        self.tokenResolver(kind, environment, authFileURL)
    }

    public func diagnosticAuthSummary(
        account: ProviderTokenAccount?,
        config: ProviderConfig?,
        environment: [String: String],
        settings: ProviderSettingsSnapshot?) -> ProviderDiagnosticAuthSummary
    {
        if let diagnosticSummary {
            return diagnosticSummary(account, config, environment, settings)
        }
        var modes = account == nil ? [] : ["tokenAccount"]
        if config?.sanitizedAPIKey != nil || config?.sanitizedSecretKey != nil {
            modes.append("api")
        }
        for mode in self.authDetector(environment, settings) where !modes.contains(mode) {
            modes.append(mode)
        }
        if config?.sanitizedCookieHeader != nil, !modes.contains("web") {
            modes.append("web")
        }
        return ProviderDiagnosticAuthSummary(configured: !modes.isEmpty, modes: modes)
    }

    public func validateConfig(_ config: ProviderConfig) -> [CodexBarConfigIssue] {
        self.configValidator(config)
    }

    public func unavailableMessage(environment: [String: String]) -> String? {
        self.missingCredentialMessage?(environment)
    }

    public func applySelectedAccount(
        environment: inout [String: String],
        account: ProviderTokenAccount)
    {
        self.accountEnvironmentOverride(&environment, account)
    }

    public func selectedAccountSourceMode(
        base: ProviderSourceMode,
        account: ProviderTokenAccount?,
        config: ProviderConfig?) -> ProviderSourceMode
    {
        self.selectedAccountSourceModeResolver(base, account, config)
    }

    public func persistManualToken(_ token: String) throws {
        try self.manualTokenPersister?(token)
    }
}

extension ProviderCredentialEnvironmentProjection {
    public static func apiKey(
        _ key: String,
        precedence: Precedence = .config,
        environmentHasValue: @escaping @Sendable ([String: String]) -> Bool = { _ in false }) -> Self
    {
        Self(
            key: key,
            precedence: precedence,
            value: { $0.sanitizedAPIKey },
            environmentHasValue: environmentHasValue)
    }

    public static func secretKey(_ key: String) -> Self {
        Self(key: key, value: { $0.sanitizedSecretKey })
    }

    public static func cookieHeader(_ key: String, onlyWhenManual: Bool = false) -> Self {
        Self(key: key, value: { config in
            guard !onlyWhenManual || config.cookieSource == .manual else { return nil }
            return config.sanitizedCookieHeader
        })
    }

    public static func region(_ key: String) -> Self {
        Self(key: key, value: { $0.sanitizedRegion })
    }

    public static func workspaceID(_ key: String) -> Self {
        Self(key: key, value: { $0.sanitizedWorkspaceID })
    }

    public static func enterpriseHost(_ key: String) -> Self {
        Self(key: key, value: { $0.sanitizedEnterpriseHost })
    }
}

extension ProviderCredentialAdapter {
    public static func regionValidator(
        displayName: String,
        isValid: @escaping @Sendable (String) -> Bool) -> ConfigValidator
    {
        { config in
            guard let provider = config.id.firstPartyProvider,
                  let region = config.sanitizedRegion,
                  !isValid(region)
            else { return [] }
            return [CodexBarConfigIssue(
                severity: .error,
                provider: provider,
                field: "region",
                code: "invalid_region",
                message: "Region \(region) is not a valid \(displayName) region.")]
        }
    }

    public static func apiKey(
        environmentKey: String,
        apiKeyDebugLabel: String? = nil,
        additionalProjections: [ProviderCredentialEnvironmentProjection] = [],
        precedence: ProviderCredentialEnvironmentProjection.Precedence = .config,
        environmentHasValue: @escaping @Sendable ([String: String]) -> Bool = { _ in false },
        resolve: @escaping @Sendable ([String: String]) -> String?,
        tokenAccountSupport: TokenAccountSupport? = nil,
        usesRegion: Bool = false,
        configValidator: @escaping ConfigValidator = { _ in [] },
        missingCredentialMessage: MissingCredentialMessage? = nil,
        accountEnvironmentOverride: @escaping AccountEnvironmentOverride = { _, _ in }) -> Self
    {
        Self(
            supportsAPIKeyOverride: true,
            usesRegion: usesRegion,
            apiKeyDebugLabel: apiKeyDebugLabel,
            environmentProjections: [
                .apiKey(
                    environmentKey,
                    precedence: precedence,
                    environmentHasValue: environmentHasValue),
            ] + additionalProjections,
            tokenResolver: { kind, environment, _ in
                guard kind == .primary, let token = resolve(environment) else { return nil }
                return ProviderTokenResolution(token: token, source: .environment)
            },
            tokenAccountSupport: tokenAccountSupport,
            authDetector: { environment, _ in resolve(environment) == nil ? [] : ["api"] },
            configValidator: configValidator,
            missingCredentialMessage: missingCredentialMessage,
            accountEnvironmentOverride: accountEnvironmentOverride)
    }
}
