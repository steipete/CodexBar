import Foundation

public enum DeepSeekProviderDescriptor {
    public static let descriptor: ProviderDescriptor = Self.makeDescriptor()

    private static let optionalResolutionJoinGrace: Duration = .seconds(5)

    struct FetchOperations: Sendable {
        let fetchUsage: @Sendable (String, String?, Bool) async throws -> DeepSeekUsageSnapshot
        let resolveAutomaticSession:
            @Sendable (String?, Bool, BrowserDetection, Bool) async -> DeepSeekPlatformTokenImporter.Resolution

        static var live: FetchOperations {
            FetchOperations(
                fetchUsage: { apiKey, platformToken, includeOptionalUsage in
                    try await DeepSeekUsageFetcher.fetchUsage(
                        apiKey: apiKey,
                        platformToken: platformToken,
                        includeOptionalUsage: includeOptionalUsage)
                },
                resolveAutomaticSession: { selectedProfileID, requiresExplicitSelection, browserDetection, verbose in
                    if verbose {
                        return await DeepSeekPlatformTokenImporter.resolveAutomaticSession(
                            selectedProfileID: selectedProfileID,
                            requiresExplicitSelection: requiresExplicitSelection,
                            browserDetection: browserDetection,
                            logger: { print($0) })
                    }
                    return await DeepSeekPlatformTokenImporter.resolveAutomaticSession(
                        selectedProfileID: selectedProfileID,
                        requiresExplicitSelection: requiresExplicitSelection,
                        browserDetection: browserDetection)
                })
        }
    }

    static func makeDescriptor() -> ProviderDescriptor {
        ProviderDescriptor(
            id: .deepseek,
            metadata: ProviderMetadata(
                id: .deepseek,
                displayName: "DeepSeek",
                sessionLabel: "Balance",
                weeklyLabel: "Balance",
                opusLabel: nil,
                supportsOpus: false,
                supportsCredits: false,
                creditsHint: "",
                toggleTitle: "Show DeepSeek usage",
                cliName: "deepseek",
                defaultEnabled: false,
                isPrimaryProvider: false,
                usesAccountFallback: false,
                browserCookieOrder: nil,
                dashboardURL: "https://platform.deepseek.com/usage",
                statusPageURL: nil,
                statusLinkURL: "https://status.deepseek.com"),
            branding: ProviderBranding(
                iconStyle: .deepseek,
                iconResourceName: "ProviderIcon-deepseek",
                color: ProviderColor(red: 0.32, green: 0.49, blue: 0.94)),
            tokenCost: ProviderTokenCostConfig(
                supportsTokenCost: false,
                noDataMessage: { "DeepSeek per-day cost history is not available via API." }),
            fetchPlan: .apiToken(
                strategyID: "deepseek.api",
                resolveToken: { ProviderTokenResolver.deepseekToken(environment: $0) },
                missingCredentialsError: { DeepSeekUsageError.missingCredentials },
                loadUsage: { apiKey, context in
                    try await Self.loadUsage(
                        apiKey: apiKey,
                        context: context,
                        optionalResolutionJoinGrace: Self.optionalResolutionJoinGrace,
                        operations: .live)
                }),
            cli: ProviderCLIConfig(
                name: "deepseek",
                aliases: ["deep-seek", "ds"],
                versionDetector: nil))
    }

    private static func loadUsage(
        apiKey: String,
        context: ProviderFetchContext,
        optionalResolutionJoinGrace: Duration,
        operations: FetchOperations) async throws -> UsageSnapshot
    {
        guard context.includeOptionalUsage else {
            return try await operations.fetchUsage(apiKey, nil, false).toUsageSnapshot()
        }
        if let platformToken = DeepSeekSettingsReader.platformToken(environment: context.env) {
            return try await operations.fetchUsage(apiKey, platformToken, true).toUsageSnapshot()
        }

        return try await self.loadAutomaticUsage(
            apiKey: apiKey,
            context: context,
            optionalResolutionJoinGrace: optionalResolutionJoinGrace,
            operations: operations)
    }

    private static func loadAutomaticUsage(
        apiKey: String,
        context: ProviderFetchContext,
        optionalResolutionJoinGrace: Duration,
        operations: FetchOperations) async throws -> UsageSnapshot
    {
        let profileSelection = DeepSeekSettingsReader.profileSelection(
            environment: context.env,
            selectedTokenAccountID: context.selectedTokenAccountID,
            apiKey: apiKey)
        let resolutionTask = Task<DeepSeekPlatformTokenImporter.Resolution, Error> {
            await operations.resolveAutomaticSession(
                profileSelection.profileID,
                profileSelection.requiresExplicitSelection,
                context.browserDetection,
                context.verbose)
        }
        let resolutionJoin = BoundedTaskJoin(sourceTask: resolutionTask)

        let balance: DeepSeekUsageSnapshot
        do {
            balance = try await operations.fetchUsage(apiKey, nil, false)
        } catch {
            resolutionTask.cancel()
            throw error
        }

        switch await resolutionJoin.value(joinGrace: optionalResolutionJoinGrace) {
        case let .value(resolution):
            try Task.checkCancellation()
            return self.combinedSnapshot(balance: balance, resolution: resolution)
        case .timedOut:
            try Task.checkCancellation()
            return self.combinedSnapshot(
                balance: balance,
                resolution: DeepSeekPlatformTokenImporter.Resolution(
                    profiles: [],
                    selectedSummary: nil,
                    detailedUsageState: .unavailable))
        case let .failure(error):
            if error is CancellationError || Task.isCancelled {
                throw error
            }
            return self.combinedSnapshot(
                balance: balance,
                resolution: DeepSeekPlatformTokenImporter.Resolution(
                    profiles: [],
                    selectedSummary: nil,
                    detailedUsageState: .unavailable))
        }
    }

    private static func combinedSnapshot(
        balance: DeepSeekUsageSnapshot,
        resolution: DeepSeekPlatformTokenImporter.Resolution) -> UsageSnapshot
    {
        DeepSeekUsageSnapshot(
            isAvailable: balance.isAvailable,
            currency: balance.currency,
            totalBalance: balance.totalBalance,
            grantedBalance: balance.grantedBalance,
            toppedUpBalance: balance.toppedUpBalance,
            usageSummary: resolution.selectedSummary,
            detailedUsageState: resolution.detailedUsageState,
            platformProfiles: resolution.profiles,
            updatedAt: balance.updatedAt).toUsageSnapshot()
    }

    static func _loadUsageForTesting(
        apiKey: String,
        context: ProviderFetchContext,
        optionalResolutionJoinGrace: Duration,
        operations: FetchOperations) async throws -> UsageSnapshot
    {
        try await self.loadUsage(
            apiKey: apiKey,
            context: context,
            optionalResolutionJoinGrace: optionalResolutionJoinGrace,
            operations: operations)
    }
}
