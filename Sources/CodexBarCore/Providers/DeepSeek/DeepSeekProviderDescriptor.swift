import Foundation

/// Non-secret verified scope for a DeepSeek refresh whose optional usage detail failed transiently.
public struct DeepSeekTransientOptionalDetailScope: Sendable, Equatable {
    public let profileID: String?
    public let ownerTokenDigest: String?
    public let period: CostReportingPeriod
    public let bucketTimeZoneIdentifier: String

    public init?(
        profileID: String?,
        ownerTokenDigest: String?,
        period: CostReportingPeriod,
        bucketTimeZoneIdentifier: String)
    {
        let normalizedProfileID = profileID?.trimmingCharacters(in: .whitespacesAndNewlines)
        let validProfileID = normalizedProfileID?.isEmpty == false ? normalizedProfileID : nil
        let normalizedDigest = ownerTokenDigest?.trimmingCharacters(in: .whitespacesAndNewlines)
        let validDigest = normalizedDigest?.isEmpty == false ? normalizedDigest : nil
        // Never allow an anonymous scope without at least one positive owner identifier.
        guard validProfileID != nil || validDigest != nil else { return nil }
        self.profileID = validProfileID
        self.ownerTokenDigest = validDigest
        self.period = period
        self.bucketTimeZoneIdentifier = bucketTimeZoneIdentifier
    }
}

/// Live-only DeepSeek optional-detail disposition used to distinguish transient outages from definitive retirement.
public enum DeepSeekHistoryRefreshDisposition: Sendable, Equatable {
    case transientOptionalDetailUnavailable(DeepSeekTransientOptionalDetailScope)
    case optOut
    case authLost
    case requiresProfileSelection
    case monthlyFallback
    case unverifiedOrChangedOwner
}

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

    struct AutomaticSessionRequest: Sendable {
        let profileID: String?
        let requiresExplicitSelection: Bool
        let includePlatformBalance: Bool
        let includeOptionalUsage: Bool
        let period: CostReportingPeriod
        let bucketTimeZoneIdentifier: String
        let browserDetection: BrowserDetection
        let verbose: Bool
    }

    struct FetchOperations: Sendable {
        let fetchUsage:
            @Sendable (String, String?, Bool, CostReportingPeriod, String) async throws -> DeepSeekUsageSnapshot
        let fetchPlatformUsage:
            @Sendable (String, Bool, CostReportingPeriod, String) async throws -> DeepSeekUsageSnapshot
        let resolveAutomaticSession:
            @Sendable (AutomaticSessionRequest) async -> DeepSeekPlatformTokenImporter.Resolution

        init(
            fetchUsage: @escaping @Sendable (String, String?, Bool) async throws -> DeepSeekUsageSnapshot,
            resolveAutomaticSession: @escaping @Sendable (
                String?,
                Bool,
                Bool,
                Bool,
                BrowserDetection,
                Bool) async -> DeepSeekPlatformTokenImporter.Resolution,
            fetchPlatformUsage: (@Sendable (String, Bool) async throws -> DeepSeekUsageSnapshot)? = nil)
        {
            self.fetchUsage = { apiKey, platformToken, includeOptional, _, _ in
                try await fetchUsage(apiKey, platformToken, includeOptional)
            }
            self.fetchPlatformUsage = { platformToken, includeOptional, period, timeZoneIdentifier in
                if let fetchPlatformUsage {
                    return try await fetchPlatformUsage(platformToken, includeOptional)
                }
                return try await DeepSeekUsageFetcher.fetchPlatformUsage(
                    platformToken: platformToken,
                    includeOptionalUsage: includeOptional,
                    period: period,
                    bucketTimeZoneIdentifier: timeZoneIdentifier)
            }
            self.resolveAutomaticSession = { request in
                await resolveAutomaticSession(
                    request.profileID,
                    request.requiresExplicitSelection,
                    request.includePlatformBalance,
                    request.includeOptionalUsage,
                    request.browserDetection,
                    request.verbose)
            }
        }

        init(
            fetchUsage: @escaping @Sendable (
                String,
                String?,
                Bool,
                CostReportingPeriod,
                String) async throws -> DeepSeekUsageSnapshot,
            fetchPlatformUsage: @escaping @Sendable (
                String,
                Bool,
                CostReportingPeriod,
                String) async throws -> DeepSeekUsageSnapshot,
            resolveAutomaticSession: @escaping @Sendable (
                AutomaticSessionRequest) async -> DeepSeekPlatformTokenImporter.Resolution)
        {
            self.fetchUsage = fetchUsage
            self.fetchPlatformUsage = fetchPlatformUsage
            self.resolveAutomaticSession = resolveAutomaticSession
        }

        static var live: FetchOperations {
            FetchOperations(
                fetchUsage: { apiKey, platformToken, includeOptionalUsage, period, timeZoneIdentifier in
                    try await DeepSeekUsageFetcher.fetchUsage(
                        apiKey: apiKey,
                        platformToken: platformToken,
                        includeOptionalUsage: includeOptionalUsage,
                        period: period,
                        bucketTimeZoneIdentifier: timeZoneIdentifier)
                },
                fetchPlatformUsage: { platformToken, includeOptionalUsage, period, timeZoneIdentifier in
                    try await DeepSeekUsageFetcher.fetchPlatformUsage(
                        platformToken: platformToken,
                        includeOptionalUsage: includeOptionalUsage,
                        period: period,
                        bucketTimeZoneIdentifier: timeZoneIdentifier)
                },
                resolveAutomaticSession: { request in
                    if request.verbose {
                        return await DeepSeekPlatformTokenImporter.resolveAutomaticSession(
                            selectedProfileID: request.profileID,
                            requiresExplicitSelection: request.requiresExplicitSelection,
                            includePlatformBalance: request.includePlatformBalance,
                            includeOptionalUsage: request.includeOptionalUsage,
                            period: request.period,
                            bucketTimeZoneIdentifier: request.bucketTimeZoneIdentifier,
                            browserDetection: request.browserDetection,
                            logger: { print($0) })
                    }
                    return await DeepSeekPlatformTokenImporter.resolveAutomaticSession(
                        selectedProfileID: request.profileID,
                        requiresExplicitSelection: request.requiresExplicitSelection,
                        includePlatformBalance: request.includePlatformBalance,
                        includeOptionalUsage: request.includeOptionalUsage,
                        period: request.period,
                        bucketTimeZoneIdentifier: request.bucketTimeZoneIdentifier,
                        browserDetection: request.browserDetection)
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
                widgetSelectable: true,
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
                color: ProviderColor(hex: 0x4D6BFE),
                confettiPalette: [
                    ProviderColor(hex: 0x4D6BFE),
                    ProviderColor(hex: 0x3982FF),
                    ProviderColor(hex: 0x020E36),
                ]),
            tokenCost: ProviderTokenCostConfig(
                supportsTokenCost: true,
                noDataMessage: { "Detailed usage unavailable." },
                isUsageUnavailable: { $0.costUsage == nil },
                showsCostMenuSection: false,
                primaryValue: .latestDaily,
                showsRequestHistory: false),
            presentation: ProviderUsagePresentation(
                menuCard: ProviderMenuCardPresentation(
                    usageNotesResolver: { context in
                        if context.isRefreshing {
                            return .localized([])
                        }
                        let credentialNote: [String]? = switch context.snapshot?.deepseekDetailedUsageState {
                        case .webSessionRequired:
                            ["Sign in to DeepSeek Platform in a Chromium-based browser for detailed usage."]
                        case .profileSelectionRequired:
                            ["Select a DeepSeek browser profile in Settings."]
                        default: nil
                        }
                        if context.snapshot?.primary == nil, let credentialNote {
                            return .localized(credentialNote)
                        }
                        guard context.costSummaryInlineEnabled, context.showOptionalUsage else {
                            return .unhandled
                        }
                        guard context.snapshot?.details.isEmpty == false else {
                            return .localized(credentialNote ?? ["Detailed usage unavailable."])
                        }
                        return .unhandled
                    },
                    showsPrimaryBalanceDescription: true,
                    hidesPrimaryResetWithoutDate: true,
                    movePrimaryDetailToStatus: { _ in true }),
                menu: ProviderMenuDescriptorPresentation(primaryDescriptionIsDetail: { _ in true }),
                optionalDetails: ProviderOptionalDetailsPresentation(
                    hidesAllWithoutOptionalUsage: true,
                    costSummaryTitles: ["Usage", "Spend"])),
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

    fileprivate struct LoadedUsage: Sendable {
        let usage: UsageSnapshot
        let continuation: DeepSeekWideHistoryContinuation?
        let historyDisposition: DeepSeekHistoryRefreshDisposition?
    }

    private static func loadUsage(
        apiKey: String,
        context: ProviderFetchContext,
        optionalResolutionJoinGrace: Duration,
        operations: FetchOperations) async throws -> LoadedUsage
    {
        guard context.includeOptionalUsage else {
            let snapshot = try await operations.fetchUsage(
                apiKey,
                nil,
                false,
                context.costReportingPeriod,
                context.costUsageBucketTimeZoneIdentifier)
            return LoadedUsage(
                usage: snapshot.toUsageSnapshot(),
                continuation: nil,
                historyDisposition: .optOut)
        }
        if let session = DeepSeekSettingsReader.scopedPlatformToken(
            environment: context.env,
            selectedTokenAccountID: context.selectedTokenAccountID,
            apiKey: apiKey)
        {
            let snapshot = try await operations.fetchUsage(
                apiKey,
                session,
                true,
                context.costReportingPeriod,
                context.costUsageBucketTimeZoneIdentifier)
            let disposition = snapshot.historyContinuation == nil
                ? self.scopedTokenHistoryDisposition(snapshot: snapshot, sessionToken: session, context: context)
                : nil
            return LoadedUsage(
                usage: snapshot.toUsageSnapshot(),
                continuation: snapshot.historyContinuation,
                historyDisposition: disposition)
        }

        return try await self.loadAutomaticUsage(
            apiKey: apiKey,
            context: context,
            optionalResolutionJoinGrace: optionalResolutionJoinGrace,
            operations: operations)
    }

    fileprivate static func loadAPIUsage(apiKey: String, context: ProviderFetchContext) async throws -> LoadedUsage {
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
        operations: FetchOperations) async throws -> LoadedUsage
    {
        let profileSelection = DeepSeekSettingsReader.profileSelection(
            environment: context.env,
            selectedTokenAccountID: context.selectedTokenAccountID,
            apiKey: apiKey)
        let resolutionTask = Task<DeepSeekPlatformTokenImporter.Resolution, Error> {
            await operations.resolveAutomaticSession(AutomaticSessionRequest(
                profileID: profileSelection.profileID,
                requiresExplicitSelection: profileSelection.requiresExplicitSelection,
                includePlatformBalance: false,
                includeOptionalUsage: context.includeOptionalUsage,
                period: context.costReportingPeriod,
                bucketTimeZoneIdentifier: context.costUsageBucketTimeZoneIdentifier,
                browserDetection: context.browserDetection,
                verbose: context.verbose))
        }
        let resolutionJoin = BoundedTaskJoin(sourceTask: resolutionTask)

        let balance: DeepSeekUsageSnapshot
        do {
            balance = try await operations.fetchUsage(
                apiKey,
                nil,
                false,
                context.costReportingPeriod,
                context.costUsageBucketTimeZoneIdentifier)
        } catch {
            resolutionTask.cancel()
            throw error
        }

        switch await resolutionJoin.value(joinGrace: optionalResolutionJoinGrace) {
        case let .value(resolution):
            try Task.checkCancellation()
            let disposition = resolution.selectedContinuation == nil
                ? self.automaticResolutionHistoryDisposition(resolution: resolution, context: context)
                : nil
            return LoadedUsage(
                usage: self.combinedSnapshot(balance: balance, resolution: resolution),
                continuation: resolution.selectedContinuation,
                historyDisposition: disposition)
        case .timedOut:
            try Task.checkCancellation()
            return LoadedUsage(
                usage: self.combinedSnapshot(
                    balance: balance,
                    resolution: DeepSeekPlatformTokenImporter.Resolution(
                        profiles: [],
                        selectedSummary: nil,
                        detailedUsageState: .unavailable)),
                continuation: nil,
                historyDisposition: self.automaticJoinFailureHistoryDisposition(
                    profileSelection: profileSelection,
                    context: context))
        case let .failure(error):
            if error is CancellationError || Task.isCancelled {
                throw error
            }
            return LoadedUsage(
                usage: self.combinedSnapshot(
                    balance: balance,
                    resolution: DeepSeekPlatformTokenImporter.Resolution(
                        profiles: [],
                        selectedSummary: nil,
                        detailedUsageState: .unavailable)),
                continuation: nil,
                historyDisposition: self.automaticJoinFailureHistoryDisposition(
                    profileSelection: profileSelection,
                    context: context))
        }
    }

    private static func scopedTokenHistoryDisposition(
        snapshot: DeepSeekUsageSnapshot,
        sessionToken: String,
        context: ProviderFetchContext) -> DeepSeekHistoryRefreshDisposition
    {
        guard context.includeOptionalUsage else { return .optOut }
        if snapshot.usageSummary != nil {
            return .monthlyFallback
        }
        switch snapshot.detailedUsageState {
        case .notRequested:
            return .optOut
        case .webSessionRequired:
            return .authLost
        case .profileSelectionRequired:
            return .requiresProfileSelection
        case .available:
            return .monthlyFallback
        case .unavailable:
            let ownerDigest = DeepSeekPlatformBalanceOwner(
                profileID: "explicit",
                token: sessionToken)?.tokenDigest
            guard let scope = DeepSeekTransientOptionalDetailScope(
                profileID: nil,
                ownerTokenDigest: ownerDigest,
                period: context.costReportingPeriod,
                bucketTimeZoneIdentifier: context.costUsageBucketTimeZoneIdentifier)
            else {
                return .unverifiedOrChangedOwner
            }
            return .transientOptionalDetailUnavailable(scope)
        }
    }

    private static func automaticResolutionHistoryDisposition(
        resolution: DeepSeekPlatformTokenImporter.Resolution,
        context: ProviderFetchContext) -> DeepSeekHistoryRefreshDisposition
    {
        guard context.includeOptionalUsage else { return .optOut }
        if resolution.selectedSummary != nil {
            return .monthlyFallback
        }
        switch resolution.detailedUsageState {
        case .notRequested:
            return .optOut
        case .webSessionRequired:
            return .authLost
        case .profileSelectionRequired:
            return .requiresProfileSelection
        case .available:
            return .monthlyFallback
        case .unavailable:
            let owner = resolution.transientUnavailableOwner ?? resolution.selectedBalance?.platformBalanceOwner
            guard let owner,
                  let scope = DeepSeekTransientOptionalDetailScope(
                      profileID: owner.profileID,
                      ownerTokenDigest: owner.tokenDigest,
                      period: context.costReportingPeriod,
                      bucketTimeZoneIdentifier: context.costUsageBucketTimeZoneIdentifier)
            else {
                return .unverifiedOrChangedOwner
            }
            return .transientOptionalDetailUnavailable(scope)
        }
    }

    private static func automaticJoinFailureHistoryDisposition(
        profileSelection: DeepSeekSettingsReader.ProfileSelection,
        context: ProviderFetchContext) -> DeepSeekHistoryRefreshDisposition
    {
        guard context.includeOptionalUsage else { return .optOut }
        guard !profileSelection.requiresExplicitSelection else { return .requiresProfileSelection }
        guard let scope = DeepSeekTransientOptionalDetailScope(
            profileID: profileSelection.profileID,
            ownerTokenDigest: nil,
            period: context.costReportingPeriod,
            bucketTimeZoneIdentifier: context.costUsageBucketTimeZoneIdentifier)
        else {
            return .unverifiedOrChangedOwner
        }
        return .transientOptionalDetailUnavailable(scope)
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
            platformBalanceOwner: balance.platformBalanceOwner,
            updatedAt: balance.updatedAt).toUsageSnapshot()
    }

    fileprivate static func loadPlatformUsage(
        context: ProviderFetchContext,
        resolutionJoinGrace: Duration = DeepSeekProviderDescriptor.platformResolutionJoinGrace,
        operations: FetchOperations = .live) async throws -> LoadedUsage
    {
        if let session = DeepSeekSettingsReader.scopedPlatformToken(
            environment: context.env,
            selectedTokenAccountID: context.selectedTokenAccountID,
            apiKey: ProviderTokenResolver.token(for: .deepseek, environment: context.env))
        {
            let snapshot = try await operations.fetchPlatformUsage(
                session,
                context.includeOptionalUsage,
                context.costReportingPeriod,
                context.costUsageBucketTimeZoneIdentifier)
            let continuation = context.includeOptionalUsage ? snapshot.historyContinuation : nil
            let disposition = continuation == nil
                ? self.scopedTokenHistoryDisposition(snapshot: snapshot, sessionToken: session, context: context)
                : nil
            return LoadedUsage(
                usage: snapshot.toUsageSnapshot(),
                continuation: continuation,
                historyDisposition: disposition)
        }

        let profileSelection = DeepSeekSettingsReader.profileSelection(
            environment: context.env,
            selectedTokenAccountID: context.selectedTokenAccountID,
            apiKey: ProviderTokenResolver.token(for: .deepseek, environment: context.env))
        let resolutionTask = Task<DeepSeekPlatformTokenImporter.Resolution, Error> {
            await operations.resolveAutomaticSession(AutomaticSessionRequest(
                profileID: profileSelection.profileID,
                requiresExplicitSelection: profileSelection.requiresExplicitSelection,
                includePlatformBalance: true,
                includeOptionalUsage: context.includeOptionalUsage,
                period: context.costReportingPeriod,
                bucketTimeZoneIdentifier: context.costUsageBucketTimeZoneIdentifier,
                browserDetection: context.browserDetection,
                verbose: context.verbose))
        }
        let resolutionJoin = BoundedTaskJoin(sourceTask: resolutionTask)
        let resolution: DeepSeekPlatformTokenImporter.Resolution
        switch await resolutionJoin.value(joinGrace: resolutionJoinGrace) {
        case let .value(value):
            resolution = value
        case .timedOut:
            let timeout = DeepSeekUsageError.networkError("Browser session resolution timed out")
            if let transport = DeepSeekPlatformTransportError(
                owner: nil,
                underlyingError: URLError(.timedOut),
                description: timeout.localizedDescription)
            {
                throw transport
            }
            throw timeout
        case let .failure(error):
            throw error
        }
        try Task.checkCancellation()
        if resolution.selectedBalance == nil, resolution.detailedUsageState == .unavailable {
            if let error = resolution.selectedTransportError { throw error }
            throw DeepSeekUsageError.networkError("Browser session resolution unavailable")
        }
        let balance = resolution.selectedBalance ?? DeepSeekUsageSnapshot(
            hasBalance: false,
            isAvailable: false,
            currency: resolution.selectedSummary?.currency ?? "USD",
            totalBalance: 0,
            grantedBalance: 0,
            toppedUpBalance: 0,
            updatedAt: resolution.selectedSummary?.updatedAt ?? Date())
        let continuation = context.includeOptionalUsage ? resolution.selectedContinuation : nil
        let disposition = continuation == nil
            ? self.automaticResolutionHistoryDisposition(resolution: resolution, context: context)
            : nil
        return LoadedUsage(
            usage: self.combinedSnapshot(balance: balance, resolution: resolution),
            continuation: continuation,
            historyDisposition: disposition)
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
            operations: operations).usage
    }

    static func _loadUsageResultForTesting(
        apiKey: String,
        context: ProviderFetchContext,
        optionalResolutionJoinGrace: Duration,
        operations: FetchOperations) async throws -> ProviderFetchResult
    {
        let loaded = try await self.loadUsage(
            apiKey: apiKey,
            context: context,
            optionalResolutionJoinGrace: optionalResolutionJoinGrace,
            operations: operations)
        return ProviderFetchResult(
            usage: loaded.usage,
            credits: nil,
            dashboard: nil,
            sourceLabel: "api",
            strategyID: "deepseek.api",
            strategyKind: .apiToken,
            deepseekHistoryContinuation: loaded.continuation,
            deepseekHistoryRefreshDisposition: loaded.historyDisposition)
    }

    static func _loadPlatformUsageForTesting(
        context: ProviderFetchContext,
        resolutionJoinGrace: Duration = DeepSeekProviderDescriptor.platformResolutionJoinGrace,
        operations: FetchOperations) async throws -> UsageSnapshot
    {
        try await self.loadPlatformUsage(
            context: context,
            resolutionJoinGrace: resolutionJoinGrace,
            operations: operations).usage
    }

    static func _loadPlatformUsageResultForTesting(
        context: ProviderFetchContext,
        resolutionJoinGrace: Duration = DeepSeekProviderDescriptor.platformResolutionJoinGrace,
        operations: FetchOperations) async throws -> ProviderFetchResult
    {
        let loaded = try await self.loadPlatformUsage(
            context: context,
            resolutionJoinGrace: resolutionJoinGrace,
            operations: operations)
        return ProviderFetchResult(
            usage: loaded.usage,
            credits: nil,
            dashboard: nil,
            sourceLabel: "web",
            strategyID: "deepseek.web",
            strategyKind: .web,
            deepseekHistoryContinuation: loaded.continuation,
            deepseekHistoryRefreshDisposition: loaded.historyDisposition)
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
        let loaded = try await DeepSeekProviderDescriptor.loadAPIUsage(apiKey: apiKey, context: context)
        return self.makeResult(
            usage: loaded.usage,
            sourceLabel: "api",
            deepseekHistoryContinuation: loaded.continuation,
            deepseekHistoryRefreshDisposition: loaded.historyDisposition)
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
        let loaded = try await DeepSeekProviderDescriptor.loadPlatformUsage(context: context)
        return self.makeResult(
            usage: loaded.usage,
            sourceLabel: "web",
            deepseekHistoryContinuation: loaded.continuation,
            deepseekHistoryRefreshDisposition: loaded.historyDisposition)
    }

    func shouldFallback(on _: Error, context _: ProviderFetchContext) -> Bool {
        false
    }
}
