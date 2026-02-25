import CodexBarMacroSupport
import Foundation

@ProviderDescriptorRegistration
@ProviderDescriptorDefinition
public enum JulesProviderDescriptor {
    static func makeDescriptor() -> ProviderDescriptor {
        ProviderDescriptor(
            id: .jules,
            metadata: ProviderMetadata(
                id: .jules,
                displayName: "Jules",
                sessionLabel: "Sessions",
                weeklyLabel: "Active",
                opusLabel: nil,
                supportsOpus: false,
                supportsCredits: false,
                creditsHint: "",
                toggleTitle: "Show Jules usage",
                cliName: "jules",
                defaultEnabled: false,
                isPrimaryProvider: false,
                usesAccountFallback: false,
                dashboardURL: "https://jules.google.com",
                statusPageURL: nil,
                statusLinkURL: nil),
            branding: ProviderBranding(
                iconStyle: .jules,
                iconResourceName: "ProviderIcon-jules",
                color: ProviderColor(red: 66 / 255, green: 133 / 255, blue: 244 / 255)), // Google Blue
            tokenCost: ProviderTokenCostConfig(
                supportsTokenCost: false,
                noDataMessage: { "Jules cost summary is not supported." }),
            fetchPlan: ProviderFetchPlan(
                sourceModes: [.auto, .cli],
                pipeline: ProviderFetchPipeline(resolveStrategies: { _ in [JulesFetchStrategy()] })),
            cli: ProviderCLIConfig(
                name: "jules",
                versionDetector: { _ in ProviderVersionDetector.genericVersion(command: "jules", argument: "--version") }))
    }
}
