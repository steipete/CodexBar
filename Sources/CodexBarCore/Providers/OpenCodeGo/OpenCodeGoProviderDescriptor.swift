import Foundation

public enum OpenCodeGoProviderDescriptor {
    public static let descriptor: ProviderDescriptor = Self.makeDescriptor()
    private static let credentials = ProviderCredentialAdapter(tokenAccountSupport: TokenAccountSupport(
        title: "Session tokens",
        subtitle: "Store multiple OpenCode Go Cookie headers.",
        placeholder: "Cookie: …",
        injection: .cookieHeader,
        requiresManualCookieSource: true,
        cookieName: nil))

    static func makeDescriptor() -> ProviderDescriptor {
        ProviderDescriptor(
            id: .opencodego,
            settingsSection: .init(
                OpenCodeGoProviderSettingsKey.self,
                cookieSettings: { settings in
                    CookieProviderSettings(
                        cookieSource: settings.cookieSource,
                        manualCookieHeader: settings.manualCookieHeader)
                },
                credentialSettings: { context in
                    let settings = context.cookieSettings(for: .opencodego)
                    return OpenCodeProviderSettings(
                        cookieSource: settings.cookieSource,
                        manualCookieHeader: settings.manualCookieHeader,
                        workspaceID: context.config?.workspaceID)
                }),
            credentials: self.credentials,
            config: ProviderConfigCapabilities(workspaceIDValidationOrder: 3),
            metadata: ProviderMetadata(
                id: .opencodego,
                displayName: "OpenCode Go",
                sessionLabel: "5-hour",
                weeklyLabel: "Weekly",
                opusLabel: "Monthly",
                supportsOpus: true,
                supportsCredits: false,
                creditsHint: "",
                toggleTitle: "Show OpenCode Go usage",
                cliName: "opencodego",
                defaultEnabled: false,
                isPrimaryProvider: false,
                usesAccountFallback: false,
                browserCookieOrder: ProviderBrowserCookieDefaults.defaultImportOrder,
                dashboardURL: "https://opencode.ai/auth",
                statusPageURL: nil),
            branding: ProviderBranding(
                iconStyle: .init(provider: .opencodego),
                iconResourceName: "ProviderIcon-opencodego",
                color: ProviderColor(red: 59 / 255, green: 130 / 255, blue: 246 / 255),
                confettiPalette: [
                    ProviderColor(hex: 0x211E1E),
                    ProviderColor(hex: 0xA3BE8C),
                    ProviderColor(hex: 0xCFCECD),
                ]),
            tokenCost: ProviderTokenCostConfig(
                supportsTokenCost: true,
                noDataMessage: {
                    "No OpenCode Go local usage history found in ~/.local/share/opencode/opencode.db."
                }),
            pace: ProviderPaceCapability(
                resetWindowPace: .windowDuration(minutes: ProviderPaceCapability.monthlyWindowSentinelMinutes),
                inferredMonthlyDuration: .windowDuration(minutes: ProviderPaceCapability.monthlyWindowSentinelMinutes),
                primary: .session(maximumMinutes: 300),
                secondary: .weekly),
            history: .alwaysTracked,
            presentation: ProviderUsagePresentation(
                costPresenter: { snapshot in
                    let style: ProviderCostMenuCardStyle = snapshot.providerCost?.period == "Zen balance"
                        ? .zenBalance
                        : .generic
                    return ProviderCostPresentation(menuCardStyle: style)
                },
                planUtilizationSeriesResolver: { snapshot in
                    var series: Set<ProviderPlanUtilizationSeries> = []
                    if snapshot.primary != nil {
                        series.insert(.session)
                    }
                    if snapshot.secondary != nil {
                        series.insert(.weekly)
                    }
                    if snapshot.tertiary != nil {
                        series.insert(.monthly)
                    }
                    return series
                },
                menuCard: ProviderMenuCardPresentation(
                    costVisibilityResolver: { context in
                        context.showOptionalUsage ||
                            (context.snapshot?.primary == nil &&
                                context.snapshot?.secondary == nil &&
                                context.snapshot?.providerCost?.period == "Zen balance")
                    },
                    supportsInlineTokenCostDashboard: true)),
            fetchPlan: ProviderFetchPlan(
                sourceModes: [.auto, .web],
                pipeline: ProviderFetchPipeline(resolveStrategies: self.resolveStrategies)),
            cli: ProviderCLIConfig(
                name: "opencodego",
                versionDetector: nil,
                browserSupportExemption: { sourceMode, _, settings in
                    sourceMode == .auto || settings?.opencodego?.cookieSource == .manual
                }))
    }

    private static func resolveStrategies(context: ProviderFetchContext) async -> [any ProviderFetchStrategy] {
        if context.sourceMode == .web {
            return [OpenCodeGoUsageFetchStrategy()]
        }
        if self.requiresScopedWebStrategy(context: context) {
            return [
                OpenCodeGoUsageFetchStrategy(),
                OpenCodeGoLocalUsageFetchStrategy(),
            ]
        }
        return [
            OpenCodeGoLocalUsageFetchStrategy(),
            OpenCodeGoUsageFetchStrategy(),
        ]
    }

    private static func requiresScopedWebStrategy(context: ProviderFetchContext) -> Bool {
        guard context.sourceMode == .auto else { return false }
        if context.selectedTokenAccountID != nil {
            return true
        }
        if context.settings?.opencodego?.cookieSource == .manual {
            return true
        }
        if self.normalizedWorkspaceID(context.settings?.opencodego?.workspaceID) != nil {
            return true
        }
        return self.normalizedWorkspaceID(context.env["CODEXBAR_OPENCODEGO_WORKSPACE_ID"]) != nil
    }

    private static func normalizedWorkspaceID(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty
        else {
            return nil
        }
        return trimmed
    }
}

struct OpenCodeGoLocalUsageFetchStrategy: ProviderFetchStrategy {
    let id: String = "opencodego.local"
    let kind: ProviderFetchKind = .localProbe

    typealias LocalSnapshotLoader = @Sendable (ProviderFetchContext) throws -> OpenCodeGoUsageSnapshot
    typealias WebUsageOverlayFetcher = @Sendable (ProviderFetchContext, String) async throws
        -> OpenCodeGoUsageSnapshot?

    private let localSnapshotLoader: LocalSnapshotLoader
    private let webUsageOverlayFetcher: WebUsageOverlayFetcher

    private struct OverlayCookie {
        let header: String
        let cachedEntry: CookieHeaderCache.Entry?
    }

    private struct SnapshotResult {
        let snapshot: OpenCodeGoUsageSnapshot
        let webUsageApplied: Bool
        let quotaIsAuthoritative: Bool
    }

    init(
        localSnapshotLoader: @escaping LocalSnapshotLoader = { context in
            try OpenCodeGoLocalUsageReader().fetch(historyDays: context.costUsageHistoryDays)
        },
        webUsageOverlayFetcher: @escaping WebUsageOverlayFetcher = Self.liveWebUsageOverlay)
    {
        self.localSnapshotLoader = localSnapshotLoader
        self.webUsageOverlayFetcher = webUsageOverlayFetcher
    }

    func isAvailable(_: ProviderFetchContext) async -> Bool {
        true
    }

    func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        let result = try await self.snapshot(context: context)
        let usage = result.snapshot.toUsageSnapshot()
        return self.makeResult(
            usage: result.quotaIsAuthoritative ? usage : usage.withDataConfidence(.estimated),
            sourceLabel: result.webUsageApplied ? "local+web" : "local")
    }

    func shouldFallback(on error: Error, context _: ProviderFetchContext) -> Bool {
        error is OpenCodeGoLocalUsageError
    }

    private func snapshot(context: ProviderFetchContext) async throws -> SnapshotResult {
        let snapshot = try self.localSnapshotLoader(context)
        guard context.settings?.opencodego?.cookieSource != .off,
              let cookie = Self.cachedOrManualCookie(context: context)
        else {
            return SnapshotResult(snapshot: snapshot, webUsageApplied: false, quotaIsAuthoritative: false)
        }

        // The server knows the real billing-cycle anchors; the local monthly window is only an
        // estimate anchored at the earliest local row. Overlay the authoritative web windows
        // whenever a session cookie is already available (never a fresh browser import here).
        // URLSession reports task cancellation as URLError.cancelled, so normalize it here to
        // keep a cancelled refresh from completing with a successful local-only result.
        let webSnapshot: OpenCodeGoUsageSnapshot?
        do {
            webSnapshot = try await self.webUsageOverlayFetcher(context, cookie.header)
        } catch OpenCodeGoUsageError.invalidCredentials {
            #if os(macOS)
            if let cached = cookie.cachedEntry {
                _ = CookieHeaderCache.clearIfCurrent(provider: .opencodego, expected: cached)
                return SnapshotResult(snapshot: snapshot, webUsageApplied: false, quotaIsAuthoritative: false)
            }
            #endif
            // A manually configured credential is an explicit account selection. Do not hide its
            // authentication failure behind an unrelated local estimate.
            throw OpenCodeGoUsageError.invalidCredentials
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            return SnapshotResult(snapshot: snapshot, webUsageApplied: false, quotaIsAuthoritative: false)
        }
        if let webSnapshot {
            return SnapshotResult(
                snapshot: snapshot.applyingWebUsage(webSnapshot),
                webUsageApplied: true,
                quotaIsAuthoritative: !webSnapshot.isBalanceOnly)
        }

        guard context.includeOptionalUsage else {
            return SnapshotResult(snapshot: snapshot, webUsageApplied: false, quotaIsAuthoritative: false)
        }
        let workspaceOverride = context.settings?.opencodego?.workspaceID
            ?? context.env["CODEXBAR_OPENCODEGO_WORKSPACE_ID"]
        let zenBalanceStart = ContinuousClock.now
        let zenBalanceTask = Task<Double?, Error> {
            do {
                return try await OpenCodeGoUsageFetcher.fetchOptionalZenBalance(
                    cookieHeader: cookie.header,
                    timeout: context.webTimeout,
                    workspaceIDOverride: workspaceOverride)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                return nil
            }
        }
        let zenBalance = try await OpenCodeGoUsageFetcher.completedOptionalZenBalance(
            from: zenBalanceTask,
            timeout: OpenCodeGoUsageFetcher.optionalZenBalanceJoinTimeout(
                since: zenBalanceStart,
                waitForZenBalance: OpenCodeGoUsageFetchStrategy.shouldWaitForZenBalance(context: context)))
        return SnapshotResult(
            snapshot: snapshot.withZenBalanceUSD(zenBalance),
            webUsageApplied: false,
            quotaIsAuthoritative: false)
    }

    static func liveWebUsageOverlay(
        context: ProviderFetchContext,
        cookieHeader: String) async throws -> OpenCodeGoUsageSnapshot?
    {
        let workspaceOverride = context.settings?.opencodego?.workspaceID
            ?? context.env["CODEXBAR_OPENCODEGO_WORKSPACE_ID"]
        do {
            return try await OpenCodeGoUsageFetcher.fetchUsage(
                cookieHeader: cookieHeader,
                timeout: context.webTimeout,
                workspaceIDOverride: workspaceOverride,
                includeZenBalance: context.includeOptionalUsage,
                waitForZenBalance: OpenCodeGoUsageFetchStrategy.shouldWaitForZenBalance(context: context))
        } catch OpenCodeGoUsageError.invalidCredentials {
            throw OpenCodeGoUsageError.invalidCredentials
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            if Task.isCancelled {
                throw CancellationError()
            }
            return nil
        }
    }

    private static func cachedOrManualCookie(context: ProviderFetchContext) -> OverlayCookie? {
        if let settings = context.settings?.opencodego, settings.cookieSource == .manual {
            guard let header = OpenCodeWebCookieSupport.requestCookieHeader(from: settings.manualCookieHeader) else {
                return nil
            }
            return OverlayCookie(header: header, cachedEntry: nil)
        }

        #if os(macOS)
        let observation = CookieHeaderCache.observeForConditionalMutation(provider: .opencodego)
        guard let cached = observation.entry,
              let header = OpenCodeWebCookieSupport.requestCookieHeader(from: cached.cookieHeader)
        else { return nil }
        return OverlayCookie(header: header, cachedEntry: cached)
        #else
        return nil
        #endif
    }
}

struct OpenCodeGoUsageFetchStrategy: ProviderFetchStrategy {
    let id: String = "opencodego.web"
    let kind: ProviderFetchKind = .web

    /// Usage-snapshot reads (`codexbar usage`, `codexbar serve`) are foreground commands, so a
    /// Zen balance that is merely slower than the subscription page is worth waiting for, bounded
    /// by the optional-balance timeout. Guard and diagnostic commands keep the short optional join
    /// grace so a slow balance cannot consume their deadline.
    static func shouldWaitForZenBalance(context: ProviderFetchContext) -> Bool {
        context.requiresOptionalUsageCompleteness
    }

    func isAvailable(_ context: ProviderFetchContext) async -> Bool {
        guard context.settings?.opencodego?.cookieSource != .off else { return false }
        return true
    }

    func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        let workspaceOverride = context.settings?.opencodego?.workspaceID
            ?? context.env["CODEXBAR_OPENCODEGO_WORKSPACE_ID"]
        let cookieSource = context.settings?.opencodego?.cookieSource ?? .auto
        do {
            let cookieHeader = try Self.resolveCookieHeader(context: context, allowCached: true)
            let snapshot = try await OpenCodeGoUsageFetcher.fetchUsage(
                cookieHeader: cookieHeader,
                timeout: context.webTimeout,
                workspaceIDOverride: workspaceOverride,
                includeZenBalance: context.includeOptionalUsage,
                waitForZenBalance: Self.shouldWaitForZenBalance(context: context))
            return self.makeResult(
                usage: snapshot.toUsageSnapshot(),
                sourceLabel: "web")
        } catch OpenCodeGoUsageError.invalidCredentials where cookieSource != .manual {
            #if os(macOS)
            CookieHeaderCache.clear(provider: .opencodego)
            let cookieHeader = try Self.resolveCookieHeader(context: context, allowCached: false)
            let snapshot = try await OpenCodeGoUsageFetcher.fetchUsage(
                cookieHeader: cookieHeader,
                timeout: context.webTimeout,
                workspaceIDOverride: workspaceOverride,
                includeZenBalance: context.includeOptionalUsage,
                waitForZenBalance: Self.shouldWaitForZenBalance(context: context))
            return self.makeResult(
                usage: snapshot.toUsageSnapshot(),
                sourceLabel: "web")
            #else
            throw OpenCodeGoUsageError.invalidCredentials
            #endif
        }
    }

    func shouldFallback(on error: Error, context: ProviderFetchContext) -> Bool {
        guard context.sourceMode == .auto else { return false }
        // Manual cookies include selected token accounts. Their authentication failures must be
        // surfaced instead of silently falling through to an account-agnostic local estimate.
        guard context.settings?.opencodego?.cookieSource != .manual,
              context.selectedTokenAccountID == nil
        else {
            return false
        }
        return switch error {
        case OpenCodeGoSettingsError.missingCookie,
             OpenCodeGoSettingsError.invalidCookie,
             OpenCodeGoUsageError.invalidCredentials:
            true
        default:
            false
        }
    }

    static func resolveCookieHeader(context: ProviderFetchContext, allowCached: Bool) throws -> String {
        try OpenCodeWebCookieSupport.resolveCookieHeader(
            context: OpenCodeWebCookieSupport.Context(
                settings: context.settings?.opencodego,
                provider: .opencodego,
                browserDetection: context.browserDetection,
                allowCached: allowCached),
            invalidCookie: OpenCodeGoSettingsError.invalidCookie,
            missingCookie: OpenCodeGoSettingsError.missingCookie)
    }
}

enum OpenCodeGoSettingsError: LocalizedError {
    case missingCookie
    case invalidCookie

    var errorDescription: String? {
        switch self {
        case .missingCookie:
            "No OpenCode Go session cookies found in browsers."
        case .invalidCookie:
            "OpenCode Go cookie header is invalid."
        }
    }
}
