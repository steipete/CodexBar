import Foundation

public enum OllamaLANProviderDescriptor {
    public static let descriptor = ProviderDescriptor(
        id: .ollamaLAN,
        metadata: ProviderMetadata(
            id: .ollamaLAN,
            displayName: "Ollama LAN",
            sessionLabel: "Models",
            weeklyLabel: "LAN",
            opusLabel: nil,
            supportsOpus: false,
            supportsCredits: false,
            creditsHint: "",
            toggleTitle: "Show Ollama LAN models (Tailscale/HTTPS)",
            cliName: "ollama-lan",
            defaultEnabled: false,
            isPrimaryProvider: false,
            usesAccountFallback: false,
            browserCookieOrder: nil,
            dashboardURL: nil,
            statusPageURL: nil,
            statusLinkURL: nil),
        branding: ProviderBranding(
            iconStyle: .ollamaLAN,
            iconResourceName: "ProviderIcon-ollama",
            color: ProviderColor(red: 249 / 255, green: 115 / 255, blue: 22 / 255)),
        tokenCost: ProviderTokenCostConfig(
            supportsTokenCost: false,
            noDataMessage: { "Ollama LAN is free — no cost tracking." }),
        fetchPlan: ProviderFetchPlan(
            sourceModes: [.auto, .api],
            pipeline: ProviderFetchPipeline(resolveStrategies: { _ in
                [OllamaLANFetchStrategy()]
            })),
        cli: ProviderCLIConfig(
            name: "ollama-lan",
            versionDetector: nil))
}

struct OllamaLANFetchStrategy: ProviderFetchStrategy {
    let id: String = "ollama-lan.api"
    let kind: ProviderFetchKind = .localProbe

    func isAvailable(_ context: ProviderFetchContext) async -> Bool {
        true
    }

    func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        // Read LAN endpoint URL from environment or config
        let endpointURL = context.env["CODEXBAR_OLLAMA_LAN_URL"] ?? "http://100.64.0.5:11434"

        let fetcher = OllamaLocalFetcher()
        let endpoint = OllamaLocalEndpoint(url: endpointURL, label: "LAN", type: .lan)

        var modelCount = 0
        var versionString: String?
        var isOnline = false

        do {
            let result = try await fetcher.probe(endpoint: endpoint)
            modelCount = result.models.count
            versionString = result.version
            isOnline = true
        } catch {
            if context.verbose {
                CodexBarLog.logger(LogCategories.ollamaLAN)
                    .verbose("LAN endpoint offline: \(endpointURL) — \(error.localizedDescription)")
            }
        }

        let usage = UsageSnapshot(
            primary: RateWindow(
                usedPercent: isOnline ? 100.0 : 0.0,
                windowMinutes: nil,
                resetsAt: nil,
                resetDescription: isOnline ? "\(modelCount) models available" : "Offline — \(endpointURL)"),
            secondary: nil,
            tertiary: nil,
            providerCost: nil,
            zaiUsage: nil,
            minimaxUsage: nil,
            openRouterUsage: nil,
            cursorRequests: nil,
            updatedAt: Date(),
            identity: ProviderIdentitySnapshot(
                providerID: .ollamaLAN,
                accountEmail: endpointURL,
                accountOrganization: versionString.map { "Ollama v\($0)" },
                loginMethod: nil))

        return ProviderFetchResult(
            usage: usage,
            credits: nil,
            dashboard: nil,
            sourceLabel: "lan-api",
            strategyID: self.id,
            strategyKind: self.kind)
    }

    func shouldFallback(on _: Error, context _: ProviderFetchContext) -> Bool {
        false
    }
}
