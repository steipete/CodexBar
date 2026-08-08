import Foundation

public enum DeepSeekProviderDescriptor {
    public static let descriptor: ProviderDescriptor = Self.makeDescriptor()
    private static let credentials = ProviderCredentialAdapter(
        environmentProjections: [
            .cookieHeader(DeepSeekSettingsReader.platformTokenEnvironmentKey),
            ProviderCredentialEnvironmentProjection(
                key: DeepSeekSettingsReader.profileIDEnvironmentKey,
                value: { $0.sanitizedDeepSeekProfileID }),
            ProviderCredentialEnvironmentProjection(
                key: DeepSeekSettingsReader.profileScopeEnvironmentKey,
                value: { $0.sanitizedDeepSeekProfileScope }),
        ],
        tokenResolver: { kind, environment, _ in
            guard kind == .primary, let token = DeepSeekSettingsReader.apiKey(environment: environment) else {
                return nil
            }
            return ProviderTokenResolution(token: token, source: .environment)
        },
        tokenAccountSupport: TokenAccountSupport(
            title: "API tokens",
            subtitle: "Store multiple DeepSeek API keys.",
            placeholder: "Paste API key…",
            injection: .environment(key: DeepSeekSettingsReader.apiKeyEnvironmentKey),
            requiresManualCookieSource: false,
            cookieName: nil),
        authDetector: { environment, _ in
            DeepSeekSettingsReader.apiKey(environment: environment) == nil ? [] : ["api"]
        },
        missingCredentialMessage: { _ in DeepSeekUsageError.missingCredentials.errorDescription })

    private static let optionalResolutionJoinGrace: Duration = .seconds(5)
    private static let platformResolutionJoinGrace: Duration = .seconds(20)

    struct FetchOperations: Sendable {
        let fetchUsage: @Sendable (String, String?, Bool) async throws -> DeepSeekUsageSnapshot
        let resolveAutomaticSession:
            @Sendable (String?, Bool, Bool, Bool, BrowserDetection, Bool) async
            -> DeepSeekPlatformTokenImporter.Resolution

        static var live: FetchOperations {
            FetchOperations(
                fetchUsage: { apiKey, platformToken, includeOptionalUsage in
                    try await DeepSeekUsageFetcher.fetchUsage(
                        apiKey: apiKey,
                        platformToken: platformToken,
                        includeOptionalUsage: includeOptionalUsage)
                },
                resolveAutomaticSession: { profileID, explicit, includeBalance, includeOptional, detection, verbose in
                    if verbose {
                        return await DeepSeekPlatformTokenImporter.resolveAutomaticSession(
                            selectedProfileID: profileID,
                            requiresExplicitSelection: explicit,
                            includePlatformBalance: includeBalance,
                            includeOptionalUsage: includeOptional,
                            browserDetection: detection,
                            logger: { print($0) })
                    }
                    return await DeepSeekPlatformTokenImporter.resolveAutomaticSession(
                        selectedProfileID: profileID,
                        requiresExplicitSelection: explicit,
                        includePlatformBalance: includeBalance,
                        includeOptionalUsage: includeOptional,
                        browserDetection: detection)
                })
        }
    }

    static func makeDescriptor() -> ProviderDescriptor {
        ProviderDescriptor(
            id: .deepseek,
            credentials: self.credentials,
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
                widgetSelectable: false,
                isPrimaryProvider: false,
                usesAccountFallback: false,
                balanceOnly: true,
                usesDetailBackedWindow: true,
                browserCookieOrder: nil,
                dashboardURL: "https://platform.deepseek.com/usage",
                statusPageURL: nil,
                statusLinkURL: "https://status.deepseek.com"),
            branding: ProviderBranding(
                iconStyle: .init(provider: .deepseek),
                iconResourceName: "ProviderIcon-deepseek",
                color: ProviderColor(red: 0.32, green: 0.49, blue: 0.94),
                confettiPalette: [
                    ProviderColor(hex: 0x4D6BFE),
                    ProviderColor(hex: 0x3982FF),
                    ProviderColor(hex: 0x020E36),
                ],
                widgetColor: ProviderColor(red: 82 / 255, green: 125 / 255, blue: 240 / 255)),
            tokenCost: ProviderTokenCostConfig(
                supportsTokenCost: false,
                noDataMessage: { "DeepSeek per-day cost history is not available via API." }),
            presentation: ProviderUsagePresentation(
                menuCard: ProviderMenuCardPresentation(
                    usageNotesResolver: { context in
                        if context.isRefreshing {
                            return .localized([])
                        }
                        let state = context.snapshot?.deepseekDetailedUsageState
                        if context.snapshot?.primary == nil {
                            if state == .webSessionRequired {
                                return .localized(["Sign in to DeepSeek Platform in Chrome for detailed usage."])
                            }
                            if state == .profileSelectionRequired {
                                return .localized(["Select a DeepSeek Chrome profile in Settings."])
                            }
                        }
                        guard context.tokenCostInlineDashboardEnabled, context.showOptionalUsage else {
                            return .unhandled
                        }
                        guard context.snapshot?.details.isEmpty == false else {
                            if state == .webSessionRequired {
                                return .localized(["Sign in to DeepSeek Platform in Chrome for detailed usage."])
                            }
                            if state == .profileSelectionRequired {
                                return .localized(["Select a DeepSeek Chrome profile in Settings."])
                            }
                            return .localized(["Detailed usage unavailable."])
                        }
                        return .unhandled
                    },
                    showsPrimaryBalanceDescription: true,
                    hidesPrimaryResetWithoutDate: true,
                    movePrimaryDetailToStatus: { _ in true }),
                menu: ProviderMenuDescriptorPresentation(primaryDescriptionIsDetail: { _ in true })),
            fetchPlan: ProviderFetchPlan(
                sourceModes: [.auto, .api, .web],
                pipeline: ProviderFetchPipeline(resolveStrategies: self.resolveStrategies)),
            cli: ProviderCLIConfig(
                name: "deepseek",
                aliases: ["deep-seek", "ds"],
                versionDetector: nil),
            configNormalizer: { config in
                config.deepseekProfileID = config.sanitizedDeepSeekProfileID
                config.deepseekProfileScope = config.sanitizedDeepSeekProfileScope
            })
    }

    private static func resolveStrategies(context: ProviderFetchContext) async -> [any ProviderFetchStrategy] {
        switch context.sourceMode {
        case .api:
            [DeepSeekAPIFetchStrategy()]
        case .web:
            [DeepSeekPlatformFetchStrategy()]
        case .auto:
            if ProviderTokenResolver.token(for: .deepseek, environment: context.env) != nil {
                [DeepSeekAPIFetchStrategy()]
            } else {
                [DeepSeekPlatformFetchStrategy()]
            }
        case .cli, .oauth:
            []
        }
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
        if let session = DeepSeekSettingsReader.scopedPlatformToken(
            environment: context.env,
            selectedTokenAccountID: context.selectedTokenAccountID,
            apiKey: apiKey)
        {
            return try await operations.fetchUsage(apiKey, session, true).toUsageSnapshot()
        }

        return try await self.loadAutomaticUsage(
            apiKey: apiKey,
            context: context,
            optionalResolutionJoinGrace: optionalResolutionJoinGrace,
            operations: operations)
    }

    fileprivate static func loadAPIUsage(apiKey: String, context: ProviderFetchContext) async throws -> UsageSnapshot {
        try await self.loadUsage(
            apiKey: apiKey,
            context: context,
            optionalResolutionJoinGrace: self.optionalResolutionJoinGrace,
            operations: .live)
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
                false,
                context.includeOptionalUsage,
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
            hasBalance: balance.hasBalance,
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

    fileprivate static func loadPlatformUsage(
        context: ProviderFetchContext,
        resolutionJoinGrace: Duration = DeepSeekProviderDescriptor.platformResolutionJoinGrace,
        operations: FetchOperations = .live) async throws -> UsageSnapshot
    {
        if let session = DeepSeekSettingsReader.scopedPlatformToken(
            environment: context.env,
            selectedTokenAccountID: context.selectedTokenAccountID,
            apiKey: ProviderTokenResolver.token(for: .deepseek, environment: context.env))
        {
            return try await DeepSeekUsageFetcher.fetchPlatformUsage(
                platformToken: session,
                includeOptionalUsage: context.includeOptionalUsage).toUsageSnapshot()
        }

        let profileSelection = DeepSeekSettingsReader.profileSelection(
            environment: context.env,
            selectedTokenAccountID: context.selectedTokenAccountID,
            apiKey: ProviderTokenResolver.token(for: .deepseek, environment: context.env))
        let resolutionTask = Task<DeepSeekPlatformTokenImporter.Resolution, Error> {
            await operations.resolveAutomaticSession(
                profileSelection.profileID,
                profileSelection.requiresExplicitSelection,
                true,
                context.includeOptionalUsage,
                context.browserDetection,
                context.verbose)
        }
        let resolutionJoin = BoundedTaskJoin(sourceTask: resolutionTask)
        let resolution: DeepSeekPlatformTokenImporter.Resolution
        switch await resolutionJoin.value(joinGrace: resolutionJoinGrace) {
        case let .value(value):
            resolution = value
        case .timedOut:
            throw DeepSeekUsageError.networkError("Chrome session resolution timed out")
        case let .failure(error):
            throw error
        }
        try Task.checkCancellation()
        if resolution.selectedBalance == nil, resolution.detailedUsageState == .unavailable {
            throw DeepSeekUsageError.networkError("Chrome session resolution unavailable")
        }
        let balance = resolution.selectedBalance ?? DeepSeekUsageSnapshot(
            hasBalance: false,
            isAvailable: false,
            currency: resolution.selectedSummary?.currency ?? "USD",
            totalBalance: 0,
            grantedBalance: 0,
            toppedUpBalance: 0,
            updatedAt: resolution.selectedSummary?.updatedAt ?? Date())
        return self.combinedSnapshot(balance: balance, resolution: resolution)
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

    static func _loadPlatformUsageForTesting(
        context: ProviderFetchContext,
        resolutionJoinGrace: Duration = DeepSeekProviderDescriptor.platformResolutionJoinGrace,
        operations: FetchOperations) async throws -> UsageSnapshot
    {
        try await self.loadPlatformUsage(
            context: context,
            resolutionJoinGrace: resolutionJoinGrace,
            operations: operations)
    }
}

private struct DeepSeekAPIFetchStrategy: ProviderFetchStrategy {
    let id = "deepseek.api"
    let kind: ProviderFetchKind = .apiToken

    func isAvailable(_ context: ProviderFetchContext) async -> Bool {
        context.sourceMode == .api || ProviderTokenResolver.token(for: .deepseek, environment: context.env) != nil
    }

    func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        guard let apiKey = ProviderTokenResolver.token(for: .deepseek, environment: context.env) else {
            throw DeepSeekUsageError.missingCredentials
        }
        let usage = try await DeepSeekProviderDescriptor.loadAPIUsage(apiKey: apiKey, context: context)
        return self.makeResult(usage: usage, sourceLabel: "api")
    }

    func shouldFallback(on _: Error, context _: ProviderFetchContext) -> Bool {
        false
    }
}

private struct DeepSeekPlatformFetchStrategy: ProviderFetchStrategy {
    let id = "deepseek.web"
    let kind: ProviderFetchKind = .web

    func isAvailable(_: ProviderFetchContext) async -> Bool {
        true
    }

    func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        let usage = try await DeepSeekProviderDescriptor.loadPlatformUsage(context: context)
        return self.makeResult(usage: usage, sourceLabel: "web")
    }

    func shouldFallback(on _: Error, context _: ProviderFetchContext) -> Bool {
        false
    }
}
