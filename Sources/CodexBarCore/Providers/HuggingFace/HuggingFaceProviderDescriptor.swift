import Foundation

public enum HuggingFaceProviderDescriptor {
    public static let descriptor: ProviderDescriptor = Self.makeDescriptor()
    private static let credentials = ProviderCredentialAdapter.apiKey(
        environmentKey: HuggingFaceSettingsReader.configAPIKeyEnvironmentKey,
        resolve: { HuggingFaceSettingsReader.apiKey(environment: $0) },
        tokenAccountSupport: TokenAccountSupport(
            title: "API tokens",
            subtitle: "Store multiple Hugging Face access tokens.",
            placeholder: "Paste access token…",
            injection: .environment(key: HuggingFaceSettingsReader.configAPIKeyEnvironmentKey),
            requiresManualCookieSource: false,
            cookieName: nil),
        missingCredentialMessage: { _ in
            "Missing Hugging Face token. Add one in Settings, set HF_TOKEN, or run hf auth login."
        })

    static func makeDescriptor() -> ProviderDescriptor {
        ProviderDescriptor(
            id: .huggingface,
            menuBarMetrics: ProviderMenuBarMetricCapabilities(supported: [.automatic, .secondary]),
            credentials: self.credentials,
            metadata: ProviderMetadata(
                id: .huggingface,
                displayName: "Hugging Face",
                sessionLabel: "Inference",
                weeklyLabel: "ZeroGPU",
                opusLabel: nil,
                supportsOpus: false,
                supportsCredits: false,
                creditsHint: "",
                toggleTitle: "Show Hugging Face usage",
                cliName: "huggingface",
                defaultEnabled: false,
                widgetSelectable: false,
                dashboardURL: "https://huggingface.co/settings/billing",
                statusPageURL: "https://status.huggingface.co"),
            branding: ProviderBranding(
                iconStyle: .init(provider: .huggingface),
                iconResourceName: "ProviderIcon-huggingface",
                color: ProviderColor(hex: 0xFFD21E),
                confettiPalette: [
                    ProviderColor(hex: 0xFFD21E),
                    ProviderColor(hex: 0xFF9D00),
                    ProviderColor(hex: 0x6B7280),
                ]),
            tokenCost: ProviderTokenCostConfig(
                supportsTokenCost: false,
                noDataMessage: { "Hugging Face usage comes from the billing API; cost history is not tracked." }),
            presentation: ProviderUsagePresentation(
                costPresenter: { _ in
                    ProviderCostPresentation(showsGenericFallback: false, menuCardStyle: .hidden)
                }),
            fetchPlan: ProviderFetchPlan(
                sourceModes: [.auto, .api],
                pipeline: ProviderFetchPipeline(resolveStrategies: { _ in [HuggingFaceScriptFetchStrategy.shared] })),
            cli: ProviderCLIConfig(
                name: "huggingface",
                aliases: ["hf"],
                versionDetector: nil))
    }
}

final class HuggingFaceScriptFetchStrategy: ProviderFetchStrategy {
    static let shared = HuggingFaceScriptFetchStrategy()
    let id = "huggingface.js"
    let kind: ProviderFetchKind = .apiToken
    private let gate = AsyncOperationGate()
    private let script: ScriptFetchStrategy

    init(transport: any ProviderHTTPTransport = ProviderHTTPClient.shared) {
        self.script = ScriptFetchStrategy(
            id: "huggingface.js",
            provider: .huggingface,
            bundledPlugin: "huggingface",
            secretKey: "HF_TOKEN",
            sourceLabel: "api",
            transport: transport,
            resolveSecret: { HuggingFaceSettingsReader.apiKey(environment: $0) },
            isEnabled: { _ in true })
    }

    func isAvailable(_ context: ProviderFetchContext) async -> Bool {
        await self.script.isAvailable(context)
    }

    func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        // Keep the token-scoped identity cache alive without overlapping the engine's fetch watchdogs.
        let id = UUID()
        let acquired = await withTaskCancellationHandler {
            await self.gate.acquire(id: id)
        } onCancel: {
            Task { await self.gate.cancel(id: id) }
        }
        guard acquired else { throw CancellationError() }
        do {
            try Task.checkCancellation()
            let result = try await self.script.fetch(context)
            try Task.checkCancellation()
            await self.gate.release(id: id)
            return result
        } catch {
            await self.gate.release(id: id)
            throw error
        }
    }

    func shouldFallback(on _: Error, context _: ProviderFetchContext) -> Bool { false }
}
