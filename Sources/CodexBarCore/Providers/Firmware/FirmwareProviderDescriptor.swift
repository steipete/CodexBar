import CodexBarMacroSupport
import Foundation

@ProviderDescriptorRegistration
@ProviderDescriptorDefinition
public enum FirmwareProviderDescriptor {
    static func makeDescriptor() -> ProviderDescriptor {
        ProviderDescriptor(
            id: .firmware,
            metadata: ProviderMetadata(
                id: .firmware,
                displayName: "Firmware",
                sessionLabel: "Quota",
                weeklyLabel: "Window",
                opusLabel: nil,
                supportsOpus: false,
                supportsCredits: false,
                creditsHint: "",
                toggleTitle: "Show Firmware usage",
                cliName: "firmware",
                defaultEnabled: false,
                isPrimaryProvider: false,
                usesAccountFallback: false,
                dashboardURL: "https://app.firmware.ai",
                statusPageURL: nil),
            branding: ProviderBranding(
                iconStyle: .firmware,
                iconResourceName: "ProviderIcon-firmware",
                color: ProviderColor(red: 231 / 255, green: 72 / 255, blue: 96 / 255)),
            tokenCost: ProviderTokenCostConfig(
                supportsTokenCost: false,
                noDataMessage: { "Firmware cost summary is not supported." }),
            fetchPlan: ProviderFetchPlan(
                sourceModes: [.auto, .api],
                pipeline: ProviderFetchPipeline(resolveStrategies: { _ in [FirmwareAPIFetchStrategy()] })),
            cli: ProviderCLIConfig(
                name: "firmware",
                aliases: ["firmware.ai"],
                versionDetector: nil))
    }
}

struct FirmwareAPIFetchStrategy: ProviderFetchStrategy {
    let id: String = "firmware.api"
    let kind: ProviderFetchKind = .apiToken

    func isAvailable(_ context: ProviderFetchContext) async -> Bool {
        Self.resolveToken(environment: context.env) != nil
    }

    func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        guard let apiKey = Self.resolveToken(environment: context.env) else {
            throw FirmwareSettingsError.missingToken
        }
        let usage = try await FirmwareQuotaFetcher.fetchUsage(apiKey: apiKey)
        return self.makeResult(
            usage: usage.toUsageSnapshot(),
            sourceLabel: "api")
    }

    func shouldFallback(on _: Error, context _: ProviderFetchContext) -> Bool {
        false
    }

    private static func resolveToken(environment: [String: String]) -> String? {
        ProviderTokenResolver.firmwareToken(environment: environment)
    }
}
