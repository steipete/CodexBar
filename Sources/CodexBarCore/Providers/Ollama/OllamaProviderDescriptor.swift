import Foundation

public enum OllamaProviderDescriptor {
    public static let descriptor: ProviderDescriptor = Self.makeDescriptor()
    private static let credentials = ProviderCredentialAdapter.apiKey(
        environmentKey: OllamaAPISettingsReader.apiKeyEnvironmentKeys[0],
        resolve: OllamaAPISettingsReader.apiKey,
        tokenAccountSupport: TokenAccountSupport(
            title: "Session tokens",
            subtitle: "Store multiple Ollama Cookie headers or session values.",
            placeholder: "Cookie header or bare session value",
            injection: .cookieHeader,
            requiresManualCookieSource: true,
            cookieName: ollamaDefaultSessionCookieName,
            cookieHeaderNormalizer: {
                normalizedOllamaTokenAccountHeader($0, defaultCookieName: ollamaDefaultSessionCookieName)
            }))

    static func makeDescriptor() -> ProviderDescriptor {
        ProviderDescriptor(
            id: .ollama,
            settingsSection: .init(OllamaProviderSettingsKey.self, cookieSettings: OllamaProviderSettings.self),
            credentials: self.credentials,
            metadata: ProviderMetadata(
                id: .ollama,
                displayName: "Ollama",
                sessionLabel: "Session",
                weeklyLabel: "Weekly",
                opusLabel: nil,
                supportsOpus: false,
                supportsCredits: false,
                creditsHint: "",
                toggleTitle: "Show Ollama usage",
                cliName: "ollama",
                defaultEnabled: false,
                widgetSelectable: false,
                isPrimaryProvider: false,
                usesAccountFallback: false,
                debugPane: ProviderDebugPaneCapabilities(probeLogOrder: 5, errorSimulationOrder: 8),
                browserCookieOrder: ProviderBrowserCookieDefaults.defaultImportOrder,
                dashboardURL: "https://ollama.com/settings",
                statusPageURL: nil),
            branding: ProviderBranding(
                iconStyle: .init(provider: .ollama),
                iconResourceName: "ProviderIcon-ollama",
                color: ProviderColor(red: 136 / 255, green: 136 / 255, blue: 136 / 255),
                confettiPalette: [
                    ProviderColor(hex: 0x000000),
                    ProviderColor(hex: 0xFFFFFF),
                ],
                widgetColor: ProviderColor(red: 32 / 255, green: 32 / 255, blue: 32 / 255)),
            tokenCost: ProviderTokenCostConfig(
                supportsTokenCost: false,
                noDataMessage: { "Ollama cost summary is not supported." }),
            // Resolve monthly pace from calendar reset boundaries, not a fixed 30-day session.
            pace: ProviderPaceCapability(
                resetWindowPace: .windowDuration(minutes: ProviderPaceCapability.monthlyWindowSentinelMinutes),
                inferredMonthlyDuration: .windowDuration(minutes: ProviderPaceCapability.monthlyWindowSentinelMinutes),
                primary: .session(maximumMinutes: 300, requiresDuration: true),
                secondary: .weeklyWithDuration,
                sessionPaceWindowRule: .custom { window, _ in
                    guard let minutes = window.windowMinutes else { return false }
                    return minutes <= 300
                }),
            presentation: ProviderUsagePresentation(
                rateWindowLabeler: { metadata, snapshot, _ in
                    ProviderRateWindowLabels(
                        primary: Self.primaryLabel(window: snapshot.primary) ?? metadata.sessionLabel,
                        secondary: metadata.weeklyLabel,
                        tertiary: metadata.opusLabel ?? "Sonnet",
                        showsTertiary: metadata.supportsOpus)
                },
                // Retain saved history, but chart only currently reported quota periods.
                planUtilizationSeriesResolver: { snapshot in
                    guard snapshot.primary?.windowMinutes == ProviderPaceCapability.monthlyWindowSentinelMinutes else {
                        return ProviderUsagePresentation.standardPlanUtilizationSeries(snapshot: snapshot)
                    }
                    var series: Set<ProviderPlanUtilizationSeries> = [.monthly]
                    if snapshot.secondary != nil {
                        series.insert(.weekly)
                    }
                    return series
                },
                menuCard: ProviderMenuCardPresentation(
                    usageNotesResolver: { context in
                        guard context.snapshot?.identity?.loginMethod == "API key" else { return .unhandled }
                        return .localized([
                            "API key verified. Cloud quotas need browser cookies. Sign in to Ollama.",
                        ])
                    })),
            fetchPlan: ProviderFetchPlan(
                sourceModes: [.auto, .web, .api],
                pipeline: ProviderFetchPipeline(resolveStrategies: self.resolveStrategies)),
            cli: ProviderCLIConfig(
                name: "ollama",
                versionDetector: nil,
                browserSupportExemption: { sourceMode, environment, settings in
                    let hasManualCookie = settings?.ollama?.cookieSource == .manual
                        && !(settings?.ollama?.manualCookieHeader?
                            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
                    if hasManualCookie {
                        return sourceMode == .auto || sourceMode == .web
                    }
                    guard sourceMode == .auto else { return false }
                    let hasEnvironmentToken = environment.map {
                        ProviderTokenResolver.token(for: .ollama, environment: $0) != nil
                    } == true
                    return settings?.ollama?.cookieSource == .off || hasEnvironmentToken
                }))
    }

    /// Keep legacy labels unless the primary window carries the monthly sentinel.
    public static func primaryLabel(window: RateWindow?) -> String? {
        guard window?.windowMinutes == ProviderPaceCapability.monthlyWindowSentinelMinutes else { return nil }
        return "Monthly"
    }

    private static func resolveStrategies(context: ProviderFetchContext) async -> [any ProviderFetchStrategy] {
        switch context.sourceMode {
        case .web:
            return [OllamaStatusFetchStrategy()]
        case .api:
            return [OllamaAPIFetchStrategy()]
        case .cli, .oauth:
            return []
        case .auto:
            break
        }
        if context.settings?.ollama?.cookieSource == .off {
            return [OllamaAPIFetchStrategy()]
        }
        if ProviderTokenResolver.token(for: .ollama, environment: context.env) != nil {
            return [OllamaStatusFetchStrategy(), OllamaAPIFetchStrategy()]
        }
        return [OllamaStatusFetchStrategy()]
    }
}

struct OllamaStatusFetchStrategy: ProviderFetchStrategy {
    let id: String = "ollama.web"
    let kind: ProviderFetchKind = .web

    func isAvailable(_ context: ProviderFetchContext) async -> Bool {
        guard context.settings?.ollama?.cookieSource != .off else { return false }
        return true
    }

    func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        let fetcher = OllamaUsageFetcher(browserDetection: context.browserDetection)
        let manual = Self.manualCookieHeader(from: context)
        let isManualMode = context.settings?.ollama?.cookieSource == .manual
        let logger: ((String) -> Void)? = context.verbose
            ? { msg in CodexBarLog.logger(LogCategories.provider(.ollama)).verbose(msg) }
            : nil
        let snap: OllamaUsageSnapshot = if isManualMode {
            try await fetcher.fetch(
                cookieHeaderOverride: manual,
                manualCookieMode: true,
                logger: logger)
        } else {
            try await Self.fetchAutomatic(
                cached: CookieHeaderCache.load(provider: .ollama),
                fetchCached: { cached in
                    try await fetcher.fetchResolvedCookie(
                        cookieHeaderOverride: cached.cookieHeader,
                        cookieHeaderOverrideSourceLabel: "cached \(cached.sourceLabel)",
                        logger: logger).snapshot
                },
                fetchBrowser: {
                    try await fetcher.fetchResolvedCookie(logger: logger)
                },
                clearCached: { cached in
                    _ = CookieHeaderCache.clearIfCurrent(provider: .ollama, expected: cached)
                },
                storeResolved: { resolved in
                    CookieHeaderCache.store(
                        provider: .ollama,
                        cookieHeader: resolved.cookieHeader,
                        sourceLabel: resolved.sourceLabel)
                })
        }
        return self.makeResult(
            usage: snap.toUsageSnapshot(),
            sourceLabel: "web")
    }

    func shouldFallback(on _: Error, context: ProviderFetchContext) -> Bool {
        context.sourceMode == .auto
            && ProviderTokenResolver.token(for: .ollama, environment: context.env) != nil
    }

    static func manualCookieHeader(from context: ProviderFetchContext) -> String? {
        guard context.settings?.ollama?.cookieSource == .manual else { return nil }
        return context.settings?.ollama?.manualCookieHeader
    }

    static func fetchAutomatic(
        cached: CookieHeaderCache.Entry?,
        fetchCached: (CookieHeaderCache.Entry) async throws -> OllamaUsageSnapshot,
        fetchBrowser: () async throws -> OllamaUsageFetcher.ResolvedCookieFetch,
        clearCached: (CookieHeaderCache.Entry) -> Void,
        storeResolved: (OllamaUsageFetcher.ResolvedCookieFetch) -> Void) async throws -> OllamaUsageSnapshot
    {
        if let cached {
            do {
                return try await fetchCached(cached)
            } catch {
                if self.shouldInvalidateCachedCookie(after: error) {
                    clearCached(cached)
                    // The ollama.com session cookie rotates independently of the user's signed-in state, so a
                    // background refresh can see a cached cookie go stale even when the user never signed out.
                    // BrowserCookieAccessGate already gates browser reads on its own no-UI preflight — it does
                    // NOT always deny a background attempt (Safari never needs Keychain decryption, and a
                    // Chromium browser with a prior "Always Allow" Keychain grant is also read without a
                    // prompt) — so still attempt `fetchBrowser` here rather than assuming it will fail. Only
                    // when that attempt itself fails do we surface the original auth error (not a misleading
                    // "no session cookie" one) instead of finalizing on a user-initiated refresh's explicit
                    // opt-in, mirroring the `shouldTryBrowserCandidates` recovery below.
                    return try await self.fetchBrowserOrRethrow(
                        originalError: error,
                        fetchBrowser: fetchBrowser,
                        storeResolved: storeResolved)
                } else if self.shouldTryBrowserCandidates(afterCachedFailure: error) {
                    return try await self.fetchBrowserOrRethrow(
                        originalError: error,
                        fetchBrowser: fetchBrowser,
                        storeResolved: storeResolved)
                } else {
                    throw error
                }
            }
        }

        let resolved = try await fetchBrowser()
        storeResolved(resolved)
        return resolved.snapshot
    }

    /// Attempts browser-cookie recovery after a cached-cookie failure, surfacing the original failure — not
    /// whatever `fetchBrowser` itself throws — if that attempt also fails with a generic, non-actionable error
    /// (e.g. no browser candidates found). A specific, actionable browser-access diagnosis (Safari needs Full
    /// Disk Access, a Chromium Keychain prompt was declined, etc.) is always more useful than the stale cached
    /// auth error it would otherwise be swapped for, so it is re-thrown as-is instead.
    private static func fetchBrowserOrRethrow(
        originalError: Error,
        fetchBrowser: () async throws -> OllamaUsageFetcher.ResolvedCookieFetch,
        storeResolved: (OllamaUsageFetcher.ResolvedCookieFetch) -> Void) async throws -> OllamaUsageSnapshot
    {
        do {
            let resolved = try await fetchBrowser()
            storeResolved(resolved)
            return resolved.snapshot
        } catch let browserError where self.isActionableBrowserAccessError(browserError) {
            throw browserError
        } catch {
            throw originalError
        }
    }

    static func isActionableBrowserAccessError(_ error: Error) -> Bool {
        switch error {
        case OllamaUsageError.safariCookieAccessDenied,
             OllamaUsageError.browserCookieDecryptionDenied,
             OllamaUsageError.browserCookieDecryptionDisabled:
            true
        default:
            false
        }
    }

    static func shouldInvalidateCachedCookie(after error: Error) -> Bool {
        switch error {
        case OllamaUsageError.invalidCredentials, OllamaUsageError.notLoggedIn:
            true
        default:
            false
        }
    }

    static func shouldTryBrowserCandidates(afterCachedFailure error: Error) -> Bool {
        switch error {
        case let OllamaUsageError.parseFailed(message):
            message == "Missing Ollama usage data."
        default:
            false
        }
    }
}

struct OllamaAPIFetchStrategy: ProviderFetchStrategy {
    let id: String = "ollama.api"
    let kind: ProviderFetchKind = .apiToken

    func isAvailable(_ context: ProviderFetchContext) async -> Bool {
        Self.resolveToken(environment: context.env) != nil
    }

    func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        guard let apiKey = Self.resolveToken(environment: context.env) else {
            throw OllamaUsageError.missingAPIKey
        }
        let snapshot = try await OllamaAPIUsageFetcher.fetchUsage(apiKey: apiKey)
        return self.makeResult(
            usage: snapshot.toUsageSnapshot(),
            sourceLabel: "api")
    }

    func shouldFallback(on _: Error, context: ProviderFetchContext) -> Bool {
        context.sourceMode == .auto
    }

    private static func resolveToken(environment: [String: String]) -> String? {
        ProviderTokenResolver.token(for: .ollama, environment: environment)
    }
}
