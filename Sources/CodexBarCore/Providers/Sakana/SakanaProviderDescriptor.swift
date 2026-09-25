import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum SakanaProviderDescriptor {
    public static let descriptor: ProviderDescriptor = Self.makeDescriptor()
    private static let credentials = ProviderCredentialAdapter(environmentProjections: [
        .cookieHeader(SakanaSettingsReader.cookieHeaderKey),
    ])
    private static let transport: ProviderHTTPClient = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        return ProviderHTTPClient(session: ProviderHTTPClient.redirectGuardedSession(configuration: configuration))
    }()

    static func makeDescriptor() -> ProviderDescriptor {
        ProviderDescriptor(
            id: .sakana,
            credentials: self.credentials,
            metadata: ProviderMetadata(
                id: .sakana,
                displayName: "Sakana AI",
                shortDisplayName: "Sakana",
                sessionLabel: "5-hour",
                weeklyLabel: "Weekly",
                opusLabel: nil,
                supportsOpus: false,
                supportsCredits: false,
                creditsHint: "",
                toggleTitle: "Show Sakana AI usage",
                cliName: "sakana",
                defaultEnabled: false,
                widgetSelectable: false,
                isPrimaryProvider: false,
                usesAccountFallback: false,
                sharePlanLabels: [
                    "standard": "Standard",
                    "standard $20/mo": "Standard",
                    "pro": "Pro",
                    "enterprise": "Enterprise",
                ],
                debugLogUnavailableMessage: "Sakana AI debug log not yet implemented",
                browserCookieOrder: nil,
                dashboardURL: "https://console.sakana.ai/billing",
                statusPageURL: nil),
            branding: ProviderBranding(
                iconStyle: .init(provider: .sakana),
                iconResourceName: "ProviderIcon-sakana",
                color: ProviderColor(red: 0.16, green: 0.46, blue: 0.86),
                confettiPalette: [
                    ProviderColor(hex: 0xE10600),
                    ProviderColor(hex: 0x0D0D0D),
                    ProviderColor(hex: 0xFFFFFF),
                ],
                widgetColor: ProviderColor(red: 41 / 255, green: 117 / 255, blue: 219 / 255)),
            tokenCost: ProviderTokenCostConfig(
                supportsTokenCost: false,
                noDataMessage: { "Sakana AI cost summary is not supported." }),
            presentation: ProviderUsagePresentation(
                optionalDetails: ProviderOptionalDetailsPresentation(hidesAllWithoutOptionalUsage: true)),
            fetchPlan: ProviderFetchPlan(
                sourceModes: [.auto, .web],
                pipeline: ProviderFetchPipeline(resolveStrategies: { context in
                    [ScriptFetchStrategy(
                        id: "sakana.js",
                        provider: .sakana,
                        bundledPlugin: "sakana",
                        secretKey: SakanaSettingsReader.cookieHeaderKey,
                        sourceLabel: "web",
                        kind: .web,
                        transport: Self.transport,
                        timeout: max(20, Self.requestTimeout(context) + 1),
                        resolveValues: Self.scriptValues,
                        isEnabled: { _ in true })]
                })),
            cli: ProviderCLIConfig(
                name: "sakana",
                aliases: ["sakana-ai"],
                versionDetector: nil,
                browserSupportExemption: { sourceMode, environment, _ in
                    guard sourceMode == .auto || sourceMode == .web else { return false }
                    return environment.map { SakanaSettingsReader.cookieHeader(environment: $0) != nil } == true
                }))
    }

    static func scriptValues(_ context: ProviderFetchContext) -> ScriptFetchStrategy.Values? {
        guard let cookie = SakanaSettingsReader.cookieHeader(environment: context.env) else { return nil }
        return .init(
            settings: [
                "OPTIONAL_USAGE": String(context.includeOptionalUsage),
                "TIMEOUT": String(Self.requestTimeout(context)),
            ],
            secrets: [SakanaSettingsReader.cookieHeaderKey: cookie])
    }

    private static func requestTimeout(_ context: ProviderFetchContext) -> TimeInterval {
        context.webTimeout.isFinite ? min(90, max(1, context.webTimeout)) : 15
    }
}
