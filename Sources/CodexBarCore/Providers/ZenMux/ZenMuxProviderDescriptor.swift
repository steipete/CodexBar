import Foundation

public enum ZenMuxProviderDescriptor {
    public static let descriptor = Self.spec.makeDescriptor()
    public static let spec = PluginProviderSpec(
        id: .zenmux,
        displayName: "ZenMux",
        sessionLabel: "5-hour quota",
        weeklyLabel: "Weekly quota",
        debugLogUnavailableMessage: "ZenMux debug log not yet implemented",
        dashboardURL: "https://zenmux.ai/platform/management",
        color: .init(hex: 0x6C5CE7),
        confetti: [0x6C5CE7, 0xA29BFE, 0xFFFFFF],
        noDataMessage: "ZenMux cost history is not exposed by the Management API.",
        environmentKey: "ZENMUX_MANAGEMENT_API_KEY",
        presentation: ProviderUsagePresentation(
            costPresenter: { _ in ProviderCostPresentation(menuCardStyle: .payAsYouGoBalance) },
            primaryBindingQuotaLanes: [.secondary],
            menuCard: ProviderMenuCardPresentation(
                primaryDescriptionPlacement: .detailLeft,
                hidesPrimaryResetWithoutDate: true)),
        aliases: ["zen-mux"],
        timeout: 35,
        scriptSettings: { context in
            let includePayg = context.runtime == .app ? context.includeOptionalUsage : context.includeCredits
            return ["INCLUDE_PAYG": includePayg ? "1" : "0"]
        },
        apiKeyField: .init(
            id: "zenmux-management-api-key",
            title: "Management API key",
            subtitle: "Stored in ~/.codexbar/config.json. Standard ZenMux inference API keys are not supported.",
            placeholder: "ZenMux management key…",
            action: ("zenmux-open-management", "Open ZenMux Management", "https://zenmux.ai/platform/management")),
        showsAPIDetail: true,
        availability: .configuredKey)

    static func scriptValues(_ context: ProviderFetchContext) -> ScriptFetchStrategy.Values? {
        self.spec.scriptValues(context)
    }
}
