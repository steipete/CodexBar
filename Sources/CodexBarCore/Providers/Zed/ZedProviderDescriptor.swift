import Foundation
import SweetCookieKit

public enum ZedProviderDescriptor {
    public static let descriptor = Self.spec.makeDescriptor(fetchPlan: Self.fetchPlan())

    public static let spec = PluginProviderSpec(
        id: .zed,
        displayName: "Zed",
        sessionLabel: "Edit predictions",
        weeklyLabel: "Billing cycle",
        sharePlanLabels: [
            "zed free": "Zed Free", "zed pro": "Zed Pro", "zed pro trial": "Zed Pro Trial",
            "zed student": "Zed Student", "zed business": "Zed Business",
        ],
        dashboardURL: nil,
        color: ProviderColor(hex: 0x084EFF),
        confetti: [0x084CCF, 0x000000, 0xFFFFFF],
        widgetColor: ProviderColor(hex: 0x409CFF),
        noDataMessage: "Zed cost summary is not supported.",
        presentation: ProviderUsagePresentation(
            costPresenter: { _ in ProviderCostPresentation(menuCardStyle: .hidden) }),
        webSource: .init(
            settingsSection: .init(
                ZedProviderSettingsKey.self,
                cookieSettings: { $0 },
                credentialSettings: { context in
                    CookieProviderSettings(
                        cookieSource: context.config?.cookieSource
                            ?? (context.config?.sanitizedCookieHeader == nil ? .off : .manual),
                        manualCookieHeader: context.config?.sanitizedCookieHeader)
                }),
            browserCookieOrder: ProviderBrowserCookieDefaults.defaultImportOrder,
            mode: .sessionOrAPI,
            field: .init(
                id: "zed-cookie",
                title: "Zed cookie",
                subtitle: "Paste the Cookie request header from zed.dev.",
                placeholder: "Cookie: …")))

    private static func fetchPlan() -> ProviderFetchPlan {
        ProviderFetchPlan(
            sourceModes: [.auto, .api, .web],
            pipeline: ProviderFetchPipeline(resolveStrategies: { context in
                let cookies = context.settings?[ZedProviderSettingsKey.self]?.cookieSource ?? .off
                if context.sourceMode == .api || (context.sourceMode == .auto && cookies == .off) {
                    return [ZedLocalFetchStrategy()]
                }
                return [ScriptFetchStrategy(
                    id: "zed.web",
                    provider: .zed,
                    bundledPlugin: "zed",
                    sourceLabel: "web",
                    kind: .web,
                    resolveValues: { context in
                        guard context.settings?[ZedProviderSettingsKey.self]?.cookieSource != nil,
                              context.settings?[ZedProviderSettingsKey.self]?.cookieSource != .off
                        else { return nil }
                        return .init(settings: ["SOURCE": "web"])
                    },
                    isEnabled: { _ in true })]
            }))
    }
}

struct ZedLocalFetchStrategy: ProviderFetchStrategy {
    let id: String = "zed.local"
    let kind: ProviderFetchKind = .localProbe

    func isAvailable(_: ProviderFetchContext) async -> Bool {
        true
    }

    func fetch(_: ProviderFetchContext) async throws -> ProviderFetchResult {
        let snapshot = try await ZedStatusProbe().fetch()
        return self.makeResult(usage: snapshot, sourceLabel: "local")
    }

    func shouldFallback(on _: Error, context _: ProviderFetchContext) -> Bool {
        false
    }
}

public enum ZedProviderSettingsKey: ProviderSettingsSectionKey {
    public static let providerID = ProviderInstanceID.zed
    public typealias Section = CookieProviderSettings
}
