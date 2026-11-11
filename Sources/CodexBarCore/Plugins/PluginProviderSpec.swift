import Foundation

/// Swift registration data for bundled plugins. Fetching and parsing stay in the plugin.
public struct PluginProviderSpec: Sendable {
    public struct SecureField: Sendable {
        public let id: String
        public let title: String
        public let subtitle: String
        public var placeholder: String? = "Paste API key…"
        public var action: (id: String, title: String, url: String)?
    }

    public struct TextField: Sendable {
        public let id: String
        public let title: String
        public let subtitle: String
        public let placeholder: String?
    }

    public struct WorkspaceField: Sendable {
        public let environmentKey: String
        public let field: TextField
        public var resolvesProjectID = false
    }

    public let id: UsageProvider
    public let displayName: String
    public var shortDisplayName: String?
    public let sessionLabel: String
    public let weeklyLabel: String
    public var opusLabel: String?
    public var creditsHint = ""
    public var sharePlanLabels: [String: String] = [:]
    public var toggleTitle: String?
    public var debugLogUnavailableMessage: String?
    public var debugPane = ProviderDebugPaneCapabilities()
    public var balanceOnly = false
    public var usesDetailBackedWindow = false
    public let dashboardURL: String?
    public var subscriptionDashboardURL: String?
    public var statusPageURL: String?
    public var statusLinkURL: String?
    public let color: ProviderColor
    public let confetti: [UInt32]
    public var widgetColor: ProviderColor?
    public var progressColorStyle: ProviderBranding.ProgressColorStyle = .brand
    public let noDataMessage: String
    public var supportsTokenCost = false
    /// Lines under the spend history. Without any, the card falls back to the local-log estimate note, which is
    /// wrong for providers whose history comes from a vendor API.
    public var tokenCostHintLines: [ProviderTokenCostHint] = []
    public var settingsSection: ProviderSettingsSectionRegistration?
    public var pluginResultPolicy = ProviderPluginResultPolicy()
    public var history: ProviderHistoryCapability = .optIn
    public var burnDownWidgetSelectable = true
    public var environmentKey: String = ""
    public var environmentAliases: [String] = []
    public var apiKeyDebugLabel: String?
    public var missingCredentialMessage: ProviderCredentialAdapter.MissingCredentialMessage?
    public var additionalProjections: [ProviderCredentialEnvironmentProjection] = []
    public var tokenAccountSupport: TokenAccountSupport?
    public var configValidator: ProviderCredentialAdapter.ConfigValidator = { _ in [] }
    public var config = ProviderConfigCapabilities()
    public var menuBarMetrics: ProviderMenuBarMetricCapabilities?
    public var presentation = ProviderUsagePresentation()
    public var aliases: [String] = []
    public var setup: ProviderSetup = .unknown
    public var timeout = ProviderPluginRuntime.defaultTimeout
    public var scriptSettings: @Sendable (ProviderFetchContext) -> [String: String] = { _ in [:] }
    public var validateContext: ScriptFetchStrategy.ContextValidator = { _ in }
    public var webSource: WebSource?
    public var apiKeyField: SecureField?
    public var workspaceField: WorkspaceField?
    public var endpoint: Endpoint?
    public var toggles: [Toggle] = []
    public var requiresAPIKeyForFetch = true
    public var showsAPIDetail = false
    public enum Availability: Sendable {
        case always
        case environmentKey
        case configuredKey
        case configuredKeyOrAccount
    }

    public var availability: Availability = .always
    public var observesTokenAccounts = false

    public func apiKey(environment: [String: String]) -> String? {
        SettingsValue.first(in: environment, keys: [self.environmentKey] + self.environmentAliases)
    }

    public func makeDescriptor(
        credentials: ProviderCredentialAdapter? = nil,
        fetchPlan: ProviderFetchPlan? = nil) -> ProviderDescriptor
    {
        let metadata = ProviderMetadata(
            id: self.id,
            displayName: self.displayName,
            shortDisplayName: self.shortDisplayName,
            sessionLabel: self.sessionLabel,
            weeklyLabel: self.weeklyLabel,
            opusLabel: self.opusLabel,
            supportsOpus: self.opusLabel != nil,
            supportsCredits: false,
            creditsHint: self.creditsHint,
            toggleTitle: self.toggleTitle ?? "Show \(self.displayName) usage",
            cliName: self.id.rawValue,
            defaultEnabled: false,
            widgetSelectable: false,
            burnDownWidgetSelectable: self.burnDownWidgetSelectable,
            sharePlanLabels: self.sharePlanLabels,
            debugLogUnavailableMessage: self.debugLogUnavailableMessage,
            debugPane: self.debugPane,
            balanceOnly: self.balanceOnly,
            usesDetailBackedWindow: self.usesDetailBackedWindow,
            browserCookieOrder: (self.settingsSection ?? self.webSource?.settingsSection)?.selectedProfileCookieOrder
                ?? self.webSource?.browserCookieOrder,
            dashboardURL: self.dashboardURL,
            subscriptionDashboardURL: self.subscriptionDashboardURL,
            statusPageURL: self.statusPageURL,
            statusLinkURL: self.statusLinkURL)
        let fetchPlan: ProviderFetchPlan = fetchPlan ?? {
            // Strategies own their runtimes; retain the finite API timeout variants across refreshes.
            let timeouts = self.webSource == nil ? Set([self.timeout] + self.toggles.compactMap(\.enabledTimeout)) : []
            let strategies = Dictionary(uniqueKeysWithValues: timeouts.map { ($0, self.makeStrategy(timeout: $0)) })
            return ProviderFetchPlan(
                sourceModes: self.webSource?.sourceModes ?? [.auto, .api],
                pipeline: ProviderFetchPipeline(resolveStrategies: { context in
                    if let web = self.webSource { return [self.webStrategy(web, context: context)] }
                    let timeout = self.fetchTimeout(environment: context.env)
                    return [strategies[timeout] ?? self.makeStrategy(timeout: timeout)]
                }))
        }()
        let cli = ProviderCLIConfig(
            name: self.id.rawValue,
            aliases: self.aliases,
            versionDetector: nil,
            browserSupportExemption: { source, environment, settings in
                self.webSource?.browserSupportExemption?(source, environment, settings) ?? false
            })
        return ProviderDescriptor(
            id: self.id,
            menuBarMetrics: self.menuBarMetrics,
            settingsSection: self.settingsSection ?? self.webSource?.settingsSection,
            credentials: credentials ?? self.makeCredentials(),
            pluginResultPolicy: self.pluginResultPolicy,
            config: ProviderConfigCapabilities(
                workspaceIDValidationOrder: self.config.workspaceIDValidationOrder,
                supportsEnterpriseHost: self.endpoint != nil || self.config.supportsEnterpriseHost),
            metadata: metadata,
            branding: ProviderBranding(
                iconStyle: .init(provider: self.id),
                iconResourceName: "ProviderIcon-\(self.id.rawValue)",
                color: self.color,
                confettiPalette: self.confetti.map { ProviderColor(hex: $0) },
                widgetColor: self.widgetColor,
                progressColorStyle: self.progressColorStyle),
            tokenCost: ProviderTokenCostConfig(
                supportsTokenCost: self.supportsTokenCost,
                noDataMessage: { self.noDataMessage },
                menuHintLines: self.tokenCostHintLines),
            history: self.history,
            presentation: self.presentation,
            fetchPlan: fetchPlan,
            cli: cli,
            setup: self.setup)
    }

    func scriptValues(_ context: ProviderFetchContext) -> ScriptFetchStrategy.Values? {
        let key = self.apiKey(environment: context.env)
        guard !self.requiresAPIKeyForFetch || key != nil,
              self.endpoint?.isAvailable(environment: context.env) ?? true else { return nil }
        var settings = self.scriptSettings(context)
        if let endpoint = self.endpoint {
            settings[endpoint.environmentKey] = endpoint.url(environment: context.env)?.absoluteString ?? ""
        }
        for toggle in self.toggles {
            settings[toggle.environmentKey] = context.env[toggle.environmentKey] ?? "false"
        }
        if let field = self.workspaceField,
           let value = SettingsValue.cleaned(context.env[field.environmentKey])
        {
            settings[field.environmentKey] = value
        }
        return .init(settings: settings, secrets: key.map { [self.environmentKey: $0] } ?? [:])
    }

    func makeStrategy(
        transport: any ProviderHTTPTransport = ProviderHTTPClient.shared,
        timeout: TimeInterval? = nil) -> ScriptFetchStrategy
    {
        ScriptFetchStrategy(
            id: "\(self.id.rawValue).js",
            provider: self.id,
            bundledPlugin: self.id.rawValue,
            secretKey: self.requiresAPIKeyForFetch ? self.environmentKey : nil,
            sourceLabel: "api",
            transport: transport,
            timeout: timeout ?? self.timeout,
            validateContext: self.validateContext,
            resolveValues: self.scriptValues,
            isEnabled: { _ in true })
    }
}
