import Foundation

public enum HttpsLMProviderDescriptor {
    public static let descriptor = ProviderDescriptor(
        id: .httpsLM,
        metadata: ProviderMetadata(
            id: .httpsLM,
            displayName: "HTTPS LM",
            sessionLabel: "Models",
            weeklyLabel: "Local",
            opusLabel: nil,
            supportsOpus: false,
            supportsCredits: false,
            creditsHint: "",
            toggleTitle: "Show HTTPS-accessible local LMs (llama.cpp, vLLM, LM Studio)",
            cliName: "https-lm",
            defaultEnabled: false,
            isPrimaryProvider: false,
            usesAccountFallback: false,
            browserCookieOrder: nil,
            dashboardURL: nil,
            statusPageURL: nil,
            statusLinkURL: nil),
        branding: ProviderBranding(
            iconStyle: .httpsLM,
            iconResourceName: "ProviderIcon-ollama",
            color: ProviderColor(red: 147 / 255, green: 51 / 255, blue: 234 / 255)),
        tokenCost: ProviderTokenCostConfig(
            supportsTokenCost: false,
            noDataMessage: { "HTTPS LM is self-hosted — no cost tracking." }),
        fetchPlan: ProviderFetchPlan(
            sourceModes: [.auto, .api],
            pipeline: ProviderFetchPipeline(resolveStrategies: { _ in
                [HttpsLMFetchStrategy()]
            })),
        cli: ProviderCLIConfig(
            name: "https-lm",
            versionDetector: nil))
}

/// Probes an OpenAI-compatible /v1/models endpoint.
struct HttpsLMFetchStrategy: ProviderFetchStrategy {
    let id: String = "https-lm.api"
    let kind: ProviderFetchKind = .localProbe

    func isAvailable(_ context: ProviderFetchContext) async -> Bool {
        true
    }

    func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        let baseURL = context.env["CODEXBAR_HTTPS_LM_URL"] ?? ""

        var modelCount = 0
        var isOnline = false

        if !baseURL.isEmpty {
            do {
                let url = URL(string: "\(baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL)/v1/models")!
                var request = URLRequest(url: url, timeoutInterval: 5)
                request.httpMethod = "GET"

                if let apiKey = context.env["CODEXBAR_HTTPS_LM_API_KEY"], !apiKey.isEmpty {
                    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
                }

                let config = URLSessionConfiguration.ephemeral
                config.timeoutIntervalForRequest = 5
                let session = URLSession(configuration: config)
                let (data, response) = try await session.data(for: request)

                if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 {
                    if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let models = json["data"] as? [[String: Any]]
                    {
                        modelCount = models.count
                        isOnline = true
                    }
                }
            } catch {
                if context.verbose {
                    CodexBarLog.logger(LogCategories.httpsLM)
                        .verbose("HTTPS LM offline: \(baseURL) — \(error.localizedDescription)")
                }
            }
        }

        let usage = UsageSnapshot(
            primary: RateWindow(
                usedPercent: isOnline ? 100.0 : 0.0,
                windowMinutes: nil,
                resetsAt: nil,
                resetDescription: isOnline ? "\(modelCount) models via /v1/models" : (baseURL.isEmpty ? "Not configured" : "Offline")),
            secondary: nil,
            tertiary: nil,
            providerCost: nil,
            zaiUsage: nil,
            minimaxUsage: nil,
            openRouterUsage: nil,
            cursorRequests: nil,
            updatedAt: Date(),
            identity: ProviderIdentitySnapshot(
                providerID: .httpsLM,
                accountEmail: baseURL.isEmpty ? nil : baseURL,
                accountOrganization: nil,
                loginMethod: nil))

        return ProviderFetchResult(
            usage: usage,
            credits: nil,
            dashboard: nil,
            sourceLabel: "https-api",
            strategyID: self.id,
            strategyKind: self.kind)
    }

    func shouldFallback(on _: Error, context _: ProviderFetchContext) -> Bool {
        false
    }
}
