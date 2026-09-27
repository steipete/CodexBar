import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum SakanaProviderDescriptor {
    public static let descriptor: ProviderDescriptor = Self.spec.makeDescriptor(credentials: Self.credentials)
    public static let spec = PluginProviderSpec(
        id: .sakana,
        displayName: "Sakana AI",
        shortDisplayName: "Sakana",
        sessionLabel: "5-hour",
        weeklyLabel: "Weekly",
        sharePlanLabels: [
            "standard": "Standard",
            "standard $20/mo": "Standard",
            "pro": "Pro",
            "enterprise": "Enterprise",
        ],
        debugLogUnavailableMessage: "Sakana AI debug log not yet implemented",
        dashboardURL: "https://console.sakana.ai/billing",
        color: .init(red: 0.16, green: 0.46, blue: 0.86),
        confetti: [0xE10600, 0x0D0D0D, 0xFFFFFF],
        widgetColor: .init(hex: 0x2975DB),
        noDataMessage: "Sakana AI cost summary is not supported.",
        presentation: ProviderUsagePresentation(
            optionalDetails: ProviderOptionalDetailsPresentation(hidesAllWithoutOptionalUsage: true)),
        aliases: ["sakana-ai"],
        webSource: .init(
            settingsSection: nil,
            timeout: .web(minimum: 20, maximum: 90, padding: 1, nonFinite: 15),
            transport: Self.transport,
            browserSupportExemption: { sourceMode, environment, _ in
                guard sourceMode == .auto || sourceMode == .web else { return false }
                return environment.map { SakanaSettingsReader.cookieHeader(environment: $0) != nil } == true
            },
            resolveValues: Self.scriptValues,
            field: .init(
                id: "sakana-cookie",
                title: "Cookie header",
                subtitle: "Stored in ~/.codexbar/config.json. Copy the Sakana AI console Cookie request header.",
                placeholder: "Cookie: ...",
                action: (
                    id: "sakana-open-dashboard",
                    title: "Open Sakana AI Console",
                    url: "https://console.sakana.ai/billing")),
            detailLine: "web",
            availability: { SakanaSettingsReader.cookieHeader(environment: $0) != nil }))

    private static let credentials = ProviderCredentialAdapter(environmentProjections: [
        .cookieHeader(SakanaSettingsReader.cookieHeaderKey),
    ])
    private static let transport: ProviderHTTPClient = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        return ProviderHTTPClient(session: ProviderHTTPClient.redirectGuardedSession(configuration: configuration))
    }()

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
