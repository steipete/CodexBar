import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif

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
                                return .localized(["Sign in to DeepSeek Platform in Chrome or Safari for detailed usage. Safari requires Full Disk Access for CodexBar."])
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
                                return .localized(["Sign in to DeepSeek Platform in Chrome or Safari for detailed usage. Safari requires Full Disk Access for CodexBar."])
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

    // MARK: - Balance history recording

    /// Stable per-credential key so multiple API keys keep separate histories.
    /// Uses a namespaced non-reversible SHA-256 digest (never raw key fragments),
    /// mirroring the profile-scope pattern in DeepSeekSettingsReader.
    private static func balanceAccountKey(apiKey: String?) -> String {
        guard let apiKey = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines),
              !apiKey.isEmpty
        else { return "default" }
        #if canImport(CryptoKit)
        let input = "com.steipete.codexbar.deepseek-balance-history.v1\0\(apiKey)"
        let digest = SHA256.hash(data: Data(input.utf8))
        return "v1:" + digest.map { String(format: "%02x", $0) }.joined()
        #else
        // Fallback without CryptoKit: still avoid raw fragments; use a simple hash.
        var hasher = Hasher()
        hasher.combine(input)
        return "v1:" + String(hasher.finalize(), radix: 16)
        #endif
    }

    /// Test hook: exposes the digest mapping without persisting anything.
    static func balanceAccountKeyForTesting(apiKey: String?) -> String {
        self.balanceAccountKey(apiKey: apiKey)
    }

    private static let balanceHistoryStore = DeepSeekBalanceHistoryStore()

    /// Records the observed balance and returns a snapshot whose balance detail
    /// includes derived consumption (today / total spend since last recharge).
    private static func usageSnapshotRecordingBalance(
        _ balance: DeepSeekUsageSnapshot,
        apiKey: String?,
        now: Date = Date()) -> UsageSnapshot
    {
        let accountKey = Self.balanceAccountKey(apiKey: apiKey)
        Self.balanceHistoryStore.record(
            balance: balance.totalBalance,
            currency: balance.currency,
            accountKey: accountKey,
            at: now)
        let consumption = Self.balanceHistoryStore.consumptionSummary(
            for: accountKey,
            currentBalance: balance.totalBalance,
            currency: balance.currency,
            now: now)
        return balance.toUsageSnapshot(consumption: consumption)
    }

    private static func loadUsage(
        apiKey: String,
        context: ProviderFetchContext,
        optionalResolutionJoinGrace: Duration,
        operations: FetchOperations) async throws -> UsageSnapshot
    {
        guard context.includeOptionalUsage else {
            let balance = try await operations.fetchUsage(apiKey, nil, false)
            return Self.usageSnapshotRecordingBalance(balance, apiKey: apiKey)
        }
        if let session = DeepSeekSettingsReader.scopedPlatformToken(
            environment: context.env,
            selectedTokenAccountID: context.selectedTokenAccountID,
            apiKey: apiKey)
        {
            let balance = try await operations.fetchUsage(apiKey, session, true)
            return Self.usageSnapshotRecordingBalance(balance, apiKey: apiKey)
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
            return self.combinedSnapshot(balance: balance, resolution: resolution, apiKey: apiKey)
        case .timedOut:
            try Task.checkCancellation()
            return self.combinedSnapshot(
                balance: balance,
                resolution: DeepSeekPlatformTokenImporter.Resolution(
                    profiles: [],
                    selectedSummary: nil,
                    detailedUsageState: .unavailable),
                apiKey: apiKey)
        case let .failure(error):
            if error is CancellationError || Task.isCancelled {
                throw error
            }
            return self.combinedSnapshot(
                balance: balance,
                resolution: DeepSeekPlatformTokenImporter.Resolution(
                    profiles: [],
                    selectedSummary: nil,
                    detailedUsageState: .unavailable),
                apiKey: apiKey)
        }
    }

    private static func combinedSnapshot(
        balance: DeepSeekUsageSnapshot,
        resolution: DeepSeekPlatformTokenImporter.Resolution,
        apiKey: String? = nil) -> UsageSnapshot
    {
        let snapshot = DeepSeekUsageSnapshot(
            hasBalance: balance.hasBalance,
            isAvailable: balance.isAvailable,
            currency: balance.currency,
            totalBalance: balance.totalBalance,
            grantedBalance: balance.grantedBalance,
            toppedUpBalance: balance.toppedUpBalance,
            usageSummary: resolution.selectedSummary,
            detailedUsageState: resolution.detailedUsageState,
            platformProfiles: resolution.profiles,
            updatedAt: balance.updatedAt)
        return Self.usageSnapshotRecordingBalance(snapshot, apiKey: apiKey)
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
        return self.combinedSnapshot(
            balance: balance,
            resolution: resolution,
            apiKey: ProviderTokenResolver.token(for: .deepseek, environment: context.env))
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
