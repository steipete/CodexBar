import CodexBarMacroSupport
import Foundation

#if os(macOS)
import SweetCookieKit
#endif

@ProviderDescriptorRegistration
@ProviderDescriptorDefinition
public enum MistralProviderDescriptor {
    static func makeDescriptor() -> ProviderDescriptor {
        #if os(macOS)
        let browserOrder = ProviderBrowserCookieDefaults.defaultImportOrder
        #else
        let browserOrder: BrowserCookieImportOrder? = nil
        #endif

        return ProviderDescriptor(
            id: .mistral,
            metadata: ProviderMetadata(
                id: .mistral,
                displayName: "Mistral",
                sessionLabel: "Requests",
                weeklyLabel: "Tokens",
                opusLabel: nil,
                supportsOpus: false,
                supportsCredits: false,
                creditsHint: "Mistral billing totals come from AI Studio cookies when available.",
                toggleTitle: "Show Mistral usage",
                cliName: "mistral",
                defaultEnabled: false,
                isPrimaryProvider: false,
                usesAccountFallback: false,
                browserCookieOrder: browserOrder,
                dashboardURL: "https://console.mistral.ai/usage",
                statusPageURL: nil,
                statusLinkURL: "https://status.mistral.ai"),
            branding: ProviderBranding(
                iconStyle: .mistral,
                iconResourceName: "ProviderIcon-mistral",
                color: ProviderColor(red: 112 / 255, green: 86 / 255, blue: 255 / 255)),
            tokenCost: ProviderTokenCostConfig(
                supportsTokenCost: false,
                noDataMessage: {
                    "Mistral billing totals come from the web dashboard cookie flow; the public API remains available as a model-access fallback."
                }),
            fetchPlan: ProviderFetchPlan(
                sourceModes: [.auto, .web, .api],
                pipeline: ProviderFetchPipeline(resolveStrategies: self.resolveStrategies)),
            cli: ProviderCLIConfig(
                name: "mistral",
                aliases: ["mistralai", "mistral-ai"],
                versionDetector: nil))
    }

    private static func resolveStrategies(context: ProviderFetchContext) async -> [any ProviderFetchStrategy] {
        switch context.sourceMode {
        case .web:
            return [MistralWebFetchStrategy()]
        case .api:
            return [MistralAPIFetchStrategy()]
        case .cli, .oauth:
            return []
        case .auto:
            break
        }

        if context.settings?.mistral?.cookieSource == .off {
            return [MistralAPIFetchStrategy()]
        }

        return [MistralWebFetchStrategy(), MistralAPIFetchStrategy()]
    }
}
