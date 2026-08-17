import Foundation
import SweetCookieKit

public enum XAIProviderDescriptor {
    public static let descriptor: ProviderDescriptor = Self.makeDescriptor()

    /// Chrome-only by default so enabling/refreshing xAI does not probe other browsers'
    /// Safe Storage. Same grok.com session as the Grok importer.
    private static var browserCookieOrder: BrowserCookieImportOrder? {
        #if os(macOS)
        [.chrome]
        #else
        return nil
        #endif
    }

    private static let credentials = ProviderCredentialAdapter(
        supportsAPIKeyOverride: true,
        environmentProjections: [
            .apiKey(XAISettingsReader.apiKeyEnvironmentKey),
            .workspaceID(XAISettingsReader.teamIDEnvironmentKey),
        ],
        tokenResolver: { kind, environment, _ in
            guard kind == .primary, let token = XAISettingsReader.apiKey(environment: environment)
            else {
                return nil
            }
            return ProviderTokenResolution(token: token, source: .environment)
        },
        tokenAccountSupport: TokenAccountSupport(
            title: "SuperGrok tokens",
            subtitle: "Store SuperGrok OAuth tokens or grok.com cookie headers.",
            placeholder: "Paste SuperGrok token or Cookie: …",
            injection: .cookieHeader,
            requiresManualCookieSource: false,
            cookieName: nil,
            environmentOverride: { token in
                switch XAICredentialRouting.resolve(
                    tokenAccountToken: token, manualCookieHeader: nil)
                {
                case let .oauth(accessToken):
                    [XAISettingsReader.oauthTokenEnvironmentKey: accessToken]
                case .managementAPI:
                    [XAISettingsReader.apiKeyEnvironmentKey: token]
                case .none, .webCookie:
                    nil
                }
            },
            environmentScrubber: { environment, _ in
                environment.removeValue(forKey: XAISettingsReader.oauthTokenEnvironmentKey)
            }),
        authDetector: { environment, settings in
            var modes: [String] = []
            if XAISettingsReader.apiKey(environment: environment) != nil {
                modes.append("api")
            }
            if XAISettingsReader.oauthAccessToken(environment: environment, settings: settings?.xai)
                != nil
            {
                modes.append("oauth")
            }
            return modes
        },
        selectedAccountSourceModeResolver: { base, account, _ in
            guard let account else { return base }
            return XAIProviderSettings.resolvedSource(
                pickerSource: base,
                routing: XAICredentialRouting.resolve(
                    tokenAccountToken: account.token,
                    manualCookieHeader: nil),
                hasAccount: true)
        })

    static func makeDescriptor() -> ProviderDescriptor {
        ProviderDescriptor(
            id: .xai,
            settingsSection: .init(
                XAIProviderSettingsKey.self,
                cookieSettings: { settings in
                    CookieProviderSettings(
                        cookieSource: settings.cookieSource,
                        manualCookieHeader: settings.manualCookieHeader)
                },
                credentialSettings: { context in
                    Self.credentialSettings(from: context)
                }),
            credentials: self.credentials,
            config: ProviderConfigCapabilities(workspaceIDValidationOrder: 6),
            metadata: ProviderMetadata(
                id: .xai,
                displayName: "xAI",
                sessionLabel: "Spend",
                weeklyLabel: "Spend",
                opusLabel: nil,
                supportsOpus: false,
                supportsCredits: false,
                creditsHint: "",
                toggleTitle: "Show xAI usage",
                cliName: "xai",
                defaultEnabled: false,
                widgetSelectable: false,
                debugLogUnavailableMessage: "xAI debug log not yet implemented",
                browserCookieOrder: self.browserCookieOrder,
                dashboardURL: "https://console.x.ai",
                subscriptionDashboardURL: XAIOAuthUsageMapper.superGrokUsageDashboardURL,
                statusPageURL: nil,
                statusLinkURL: "https://status.x.ai"),
            branding: ProviderBranding(
                iconStyle: .init(provider: .xai),
                iconResourceName: "ProviderIcon-xai",
                color: ProviderColor(red: 142 / 255, green: 142 / 255, blue: 147 / 255),
                confettiPalette: [
                    ProviderColor(hex: 0x1A1A1A),
                    ProviderColor(hex: 0x8E8E93),
                    ProviderColor(hex: 0xF5F5F7),
                ]),
            tokenCost: ProviderTokenCostConfig(
                supportsTokenCost: false,
                noDataMessage: {
                    "xAI spend history comes from the Management API billing endpoints."
                }),
            presentation: ProviderUsagePresentation(
                rateWindowLabeler: { metadata, snapshot, now in
                    ProviderRateWindowLabels(
                        primary: Self.primaryLabel(snapshot: snapshot, now: now)
                            ?? metadata.sessionLabel,
                        secondary: metadata.weeklyLabel,
                        tertiary: metadata.opusLabel ?? "Sonnet",
                        showsTertiary: metadata.supportsOpus)
                },
                identityPresenter: { provider, snapshot in
                    guard let plan = snapshot.loginMethod(for: provider), !plan.isEmpty else {
                        return ProviderIdentityPresentation(badge: nil, plan: nil)
                    }
                    let display = UsageFormatter.cleanPlanName(plan)
                    return ProviderIdentityPresentation(badge: display, plan: display)
                },
                costPresenter: { snapshot in
                    let showsFallback = snapshot.providerCost?.period != "Prepaid credits"
                    let style: ProviderCostMenuCardStyle =
                        showsFallback ? .generic : .prepaidCredits
                    return ProviderCostPresentation(
                        showsGenericFallback: showsFallback, menuCardStyle: style)
                },
                optionalDetails: ProviderOptionalDetailsPresentation(
                    costSummaryTitles: ["Billing summary"])),
            fetchPlan: ProviderFetchPlan(
                sourceModes: [.auto, .api, .oauth, .web],
                pipeline: ProviderFetchPipeline(resolveStrategies: self.resolveStrategies)),
            cli: ProviderCLIConfig(
                name: "xai",
                versionDetector: nil,
                browserSupportExemption: { sourceMode, _, settings in
                    sourceMode == .oauth || settings?.xai?.cookieSource == .manual
                }))
    }

    public static func primaryLabel(snapshot: UsageSnapshot, now: Date = .now) -> String? {
        guard XAIOAuthUsageMapper.isSuperGrokFamily(snapshot.loginMethod(for: .xai)) else {
            return nil
        }
        return GrokProviderDescriptor.displayLabel(window: snapshot.primary, now: now) ?? "Credits"
    }

    private static func credentialSettings(
        from context: ProviderCredentialSettingsContext) -> XAIProviderSettings
    {
        XAIProviderSettings.resolved(
            pickerSource: context.config?.source ?? .auto,
            tokenAccountToken: context.account?.token,
            configuredCookieSource: context.cookieSettings(for: .xai).cookieSource,
            configuredCookieHeader: context.account == nil
                ? context.config?.sanitizedCookieHeader : nil,
            allowGrokCLICredentials: XAISettingsReader.allowGrokCLICredentials(
                pluginSettings: context.config?.pluginSettings))
    }

    private static func resolveStrategies(context: ProviderFetchContext) async
        -> [any ProviderFetchStrategy]
    {
        let api = Self.managementAPIStrategy()
        let oauth = XAIOAuthFetchStrategy()
        let web = XAIWebFetchStrategy()
        switch context.sourceMode {
        case .auto:
            return [api, oauth, web] as [any ProviderFetchStrategy]
        case .api:
            return [api]
        case .oauth:
            return [oauth]
        case .web:
            return [oauth, web]
        case .cli:
            return [any ProviderFetchStrategy]()
        }
    }

    private static func managementAPIStrategy() -> ScriptFetchStrategy {
        ScriptFetchStrategy(
            id: "xai.js",
            provider: .xai,
            bundledPlugin: "xai",
            secretKey: XAISettingsReader.apiKeyEnvironmentKey,
            sourceLabel: "api",
            validateContext: { context in
                _ = try XAISettingsReader.validatedTeamID(environment: context.env)
            },
            resolveValues: { context in
                guard let key = XAISettingsReader.apiKey(environment: context.env) else {
                    return nil
                }
                let settings =
                    XAISettingsReader.teamID(environment: context.env).map {
                        [XAISettingsReader.teamIDEnvironmentKey: $0]
                    } ?? [:]
                return ScriptFetchStrategy.Values(
                    settings: settings,
                    secrets: [XAISettingsReader.apiKeyEnvironmentKey: key])
            },
            isEnabled: { _ in true })
    }
}
