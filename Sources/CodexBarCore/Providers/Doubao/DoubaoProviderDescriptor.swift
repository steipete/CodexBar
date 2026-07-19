import Foundation

public enum DoubaoProviderDescriptor {
    public static let descriptor: ProviderDescriptor = Self.makeDescriptor()

    public static func primaryLabel(window: RateWindow?) -> String? {
        guard window?.windowMinutes == nil,
              window?.resetDescription?.localizedCaseInsensitiveContains("request") == true
        else {
            return nil
        }
        return "Requests"
    }

    static func makeDescriptor() -> ProviderDescriptor {
        ProviderDescriptor(
            id: .doubao,
            metadata: ProviderMetadata(
                id: .doubao,
                displayName: "Doubao",
                sessionLabel: "5-hour",
                weeklyLabel: "Weekly",
                opusLabel: "Monthly",
                supportsOpus: true,
                supportsCredits: false,
                creditsHint: "",
                toggleTitle: "Show Doubao usage",
                cliName: "doubao",
                defaultEnabled: false,
                isPrimaryProvider: false,
                usesAccountFallback: false,
                browserCookieOrder: nil,
                dashboardURL: "https://console.volcengine.com/ark/region:ark+cn-beijing/openManagement?LLM=%7B%7D&advancedActiveKey=subscribe",
                statusPageURL: nil),
            branding: ProviderBranding(
                iconStyle: .doubao,
                iconResourceName: "ProviderIcon-doubao",
                color: ProviderColor(red: 51 / 255, green: 112 / 255, blue: 255 / 255),
                confettiPalette: [
                    ProviderColor(hex: 0x0057FF),
                    ProviderColor(hex: 0xEFC5BA),
                    ProviderColor(hex: 0x493530),
                ]),
            tokenCost: ProviderTokenCostConfig(
                supportsTokenCost: false,
                noDataMessage: { "Doubao cost summary is not available." }),
            fetchPlan: ProviderFetchPlan(
                sourceModes: [.auto, .cli, .api],
                pipeline: ProviderFetchPipeline(resolveStrategies: self.resolveStrategies)),
            cli: ProviderCLIConfig(
                name: "doubao",
                aliases: ["volcengine", "ark", "bytedance"],
                versionDetector: nil))
    }

    static func resolveStrategies(context: ProviderFetchContext) async -> [any ProviderFetchStrategy] {
        switch context.sourceMode {
        case .auto:
            // Persisted credentials identify a specific account. Do not let an ambient arkcli
            // session silently replace it with another account in auto mode.
            if self.hasConfiguredAPICredentials(environment: context.env) {
                [DoubaoAPIFetchStrategy()]
            } else {
                [DoubaoCLIFetchStrategy()]
            }
        case .cli:
            // Explicit CLI source: arkcli only, no API fallback.
            [DoubaoCLIFetchStrategy()]
        case .api:
            // Explicit API source: AK/SK signed or API key probe only, no SSO fallback.
            [DoubaoAPIFetchStrategy()]
        case .web, .oauth:
            []
        }
    }

    private static func hasConfiguredAPICredentials(environment: [String: String]) -> Bool {
        DoubaoSettingsReader.codingPlanCredentials(environment: environment) != nil ||
            ProviderTokenResolver.doubaoToken(environment: environment) != nil
    }
}

// MARK: - CLI strategy (arkcli SSO)

struct DoubaoCLIFetchStrategy: ProviderFetchStrategy {
    let id: String = "doubao.cli"
    let kind: ProviderFetchKind = .cli
    private let cliUsageLoader: @Sendable ([String: String]) async throws -> DoubaoUsageSnapshot

    init(
        cliUsageLoader: @escaping @Sendable ([String: String]) async throws -> DoubaoUsageSnapshot = { environment in
            try await DoubaoUsageFetcher.fetchCodingPlanUsage(environment: environment)
        })
    {
        self.cliUsageLoader = cliUsageLoader
    }

    func isAvailable(_: ProviderFetchContext) async -> Bool {
        // Keep the strategy available so missing CLI and login failures surface as actionable errors.
        true
    }

    func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        let usage = try await self.cliUsageLoader(context.env)
        return self.makeResult(usage: usage.toUsageSnapshot(), sourceLabel: "cli")
    }

    func shouldFallback(on _: Error, context _: ProviderFetchContext) -> Bool {
        false
    }
}

// MARK: - API strategy (AK/SK signed + Ark API key probe)

struct DoubaoAPIFetchStrategy: ProviderFetchStrategy {
    let id: String = "doubao.api"
    let kind: ProviderFetchKind = .apiToken
    private let signedUsageLoader: @Sendable (DoubaoCodingPlanCredentials) async throws -> DoubaoUsageSnapshot
    private let arkUsageLoader: @Sendable (String) async throws -> DoubaoUsageSnapshot

    init(
        signedUsageLoader: @escaping @Sendable (DoubaoCodingPlanCredentials) async throws
            -> DoubaoUsageSnapshot = { credentials in
                try await DoubaoUsageFetcher.fetchCodingPlanUsage(credentials: credentials)
            },
        arkUsageLoader: @escaping @Sendable (String) async throws -> DoubaoUsageSnapshot = { apiKey in
            try await DoubaoUsageFetcher.fetchUsage(apiKey: apiKey)
        })
    {
        self.signedUsageLoader = signedUsageLoader
        self.arkUsageLoader = arkUsageLoader
    }

    func isAvailable(_ context: ProviderFetchContext) async -> Bool {
        // Explicit API mode always runs so a missing key surfaces an error.
        // Auto mode only tries API when credentials are resolvable.
        context.sourceMode == .api ||
            DoubaoSettingsReader.codingPlanCredentials(environment: context.env) != nil ||
            ProviderTokenResolver.doubaoToken(environment: context.env) != nil
    }

    func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        let apiKey = ProviderTokenResolver.doubaoToken(environment: context.env)
        var signedError: Error?

        // 1) Try AK/SK signed Coding Plan usage (legacy Volcengine API).
        if let credentials = DoubaoSettingsReader.codingPlanCredentials(environment: context.env) {
            do {
                let usage = try await self.signedUsageLoader(credentials)
                return self.makeResult(usage: usage.toUsageSnapshot(), sourceLabel: "api")
            } catch {
                if Self.isCancellation(error) {
                    throw error
                }
                // Preserve the signed error so it surfaces when there is no API key to fall back to.
                signedError = error
            }
        }

        // 2) Fall back to Ark API key probe (rate-limit headers).
        guard let apiKey else {
            // If the signed request failed, surface that error instead of a generic "missing key".
            throw signedError ?? DoubaoUsageError.missingCredentials
        }
        let usage = try await self.arkUsageLoader(apiKey)
        return self.makeResult(usage: usage.toUsageSnapshot(), sourceLabel: "api")
    }

    func shouldFallback(on _: Error, context _: ProviderFetchContext) -> Bool {
        // API strategy never falls back to CLI; explicit API mode stays strict.
        false
    }

    private static func isCancellation(_ error: Error) -> Bool {
        error is CancellationError || (error as? URLError)?.code == .cancelled || Task.isCancelled
    }
}
