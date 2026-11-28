import Foundation

public enum MistralProviderDescriptor {
    public static let descriptor: ProviderDescriptor = Self.makeDescriptor()
    private static let credentials = ProviderCredentialAdapter(
        supportsAPIKeyOverride: true,
        environmentProjections: [.apiKey(MistralBudgetFetchStrategy.environmentKey)],
        tokenAccountSupport: TokenAccountSupport(
            title: "Session tokens",
            subtitle: "Store multiple Mistral Cookie headers.",
            placeholder: "Cookie: …",
            injection: .cookieHeader,
            requiresManualCookieSource: true,
            cookieName: nil),
        authDetector: { env, _ in MistralBudgetFetchStrategy.apiKey(in: env) == nil ? [] : ["api"] },
        accountEnvironmentOverride: { env, _ in
            // An explicitly selected cookie account must not use another account's configured key.
            env.removeValue(forKey: MistralBudgetFetchStrategy.environmentKey)
        })

    static func makeDescriptor() -> ProviderDescriptor {
        ProviderDescriptor(
            id: .mistral,
            menuBarMetrics: ProviderMenuBarMetricCapabilities(supported: [.automatic, .primary, .monthlyPlan]),
            settingsSection: .init(MistralProviderSettingsKey.self, cookieSettings: MistralProviderSettings.self),
            credentials: self.credentials,
            metadata: ProviderMetadata(
                id: .mistral,
                displayName: "Mistral",
                sessionLabel: "Balance",
                weeklyLabel: "",
                opusLabel: nil,
                supportsOpus: false,
                supportsCredits: false,
                creditsHint: "",
                toggleTitle: "Show Mistral usage",
                cliName: "mistral",
                defaultEnabled: false,
                isPrimaryProvider: false,
                usesAccountFallback: false,
                usesDetailBackedWindow: true,
                browserCookieOrder: ProviderBrowserCookieDefaults.defaultImportOrder,
                dashboardURL: "https://admin.mistral.ai/organization/usage",
                statusPageURL: nil,
                statusLinkURL: "https://status.mistral.ai"),
            branding: ProviderBranding(
                iconStyle: .init(provider: .mistral),
                iconResourceName: "ProviderIcon-mistral",
                color: ProviderColor(hex: 0xFF5229),
                confettiPalette: [
                    ProviderColor(hex: 0xFF5229),
                    ProviderColor(hex: 0xFFAF01),
                    ProviderColor(hex: 0xFFE000),
                ]),
            tokenCost: ProviderTokenCostConfig(
                supportsTokenCost: true,
                noDataMessage: { "Mistral cost history needs a billing web session." },
                menuHintLines: [.literal("Reported by Mistral billing usage.")],
                showsCostMenuSection: false,
                primaryValue: .latestDaily,
                chartCalendar: CostUsageBucketTimeZone.calendar(identifier: "UTC")),
            presentation: ProviderUsagePresentation(
                rateWindowLabeler: { metadata, snapshot, _ in
                    ProviderRateWindowLabels(
                        primary: snapshot.primary == nil ? metadata.sessionLabel : "Included API",
                        secondary: metadata.weeklyLabel,
                        tertiary: metadata.opusLabel ?? "Sonnet",
                        showsTertiary: metadata.supportsOpus)
                },
                extraRateWindowSelector: { snapshot in
                    (snapshot.extraRateWindows ?? []).filter { $0.id == "mistral-monthly-plan" }
                },
                menuBarLayoutPrimaryLabel: "Included API",
                menuBarWindowResolver: { context in
                    switch context.metric {
                    case .automatic:
                        .resolved(context.snapshot.mistralUsage == nil
                            ? context.snapshot.primary ?? context.snapshot.extraRateWindows?
                            .first(where: { $0.id == "mistral-monthly-plan" })?.window
                            : nil)
                    case .monthlyPlan:
                        .resolved(context.snapshot.extraRateWindows?.first { $0.id == "mistral-monthly-plan" }?.window)
                    default:
                        .unhandled
                    }
                },
                widgetRowResolver: self.widgetRows,
                menuCard: ProviderMenuCardPresentation(
                    usesProviderCostHistoryAsPrimaryDashboard: true,
                    primaryCostHistoryResolver: { snapshot, tokenSnapshot in
                        if let projected = snapshot?.mistralUsage?.toCostUsageTokenSnapshot() {
                            return projected
                        }
                        return snapshot == nil ? tokenSnapshot : nil
                    },
                    showsPrimaryBalanceDescription: true,
                    hidesPrimaryResetWithoutDate: true,
                    extraRateWindowUsesResetDescriptionAsDetail: { $0.id == "mistral-monthly-plan" }),
                menu: ProviderMenuDescriptorPresentation(primaryDescriptionIsDetail: { _ in true }),
                optionalDetails: .init(hiddenTitlesWithoutOptionalUsage: [MistralWebFetchStrategy.creditDetailTitle])),
            fetchPlan: ProviderFetchPlan(
                sourceModes: [.auto, .web, .api],
                pipeline: ProviderFetchPipeline(
                    resolveStrategies: { context in
                        switch context.sourceMode {
                        case .api: [MistralBudgetFetchStrategy()]
                        case .web: [MistralWebFetchStrategy()]
                        case .auto: [MistralBudgetFetchStrategy(), MistralWebFetchStrategy()]
                        case .cli, .oauth: []
                        }
                    },
                    resolveFallbackError: self.resolveFallbackError)),
            cli: ProviderCLIConfig(
                name: "mistral",
                aliases: ["mistral-ai"],
                versionDetector: nil,
                browserSupportExemption: { _, _, settings in
                    // A pasted Cookie header needs no browser import, so it works on Linux too.
                    settings?.mistral?.cookieSource == .manual &&
                        CookieHeaderNormalizer.normalize(settings?.mistral?.manualCookieHeader) != nil
                }))
    }

    private static func resolveFallbackError(_ prior: (any Error)?, _ error: any Error) -> any Error {
        guard let budgetError = prior as? MistralBudgetError else { return error }
        if case MistralSettingsError.missingCookie = error { return budgetError }
        #if os(macOS)
        if case MistralCookieImportError.noCookies = error { return budgetError }
        #endif
        return error
    }

    private static func widgetRows(
        _ rows: [WidgetSnapshot.WidgetUsageRowSnapshot],
        snapshot: UsageSnapshot,
        metric: ProviderMenuBarMetric) -> [WidgetSnapshot.WidgetUsageRowSnapshot]
    {
        guard metric == .monthlyPlan,
              let plan = snapshot.extraRateWindows?.first(where: { $0.id == "mistral-monthly-plan" }),
              plan.usageKnown
        else { return rows }
        return [WidgetSnapshot.WidgetUsageRowSnapshot(
            id: plan.id,
            title: plan.title,
            percentLeft: plan.window.remainingPercent,
            window: plan.window)]
    }
}

struct MistralWebFetchStrategy: ProviderFetchStrategy {
    struct BrowserUsage {
        let snapshot: UsageSnapshot
        let diagnostic: String?
    }

    static let creditDetailTitle = "Credits"
    private static let logger = CodexBarLog.logger(LogCategories.provider(.mistral))
    let id: String = "mistral.web"
    let kind: ProviderFetchKind = .web
    var transport: any ProviderHTTPTransport = ProviderHTTPClient.shared

    func isAvailable(_ context: ProviderFetchContext) async -> Bool {
        context.settings?.mistral?.cookieSource != .off
    }

    func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        let cookieSource = context.settings?.mistral?.cookieSource ?? .auto
        let session = try Self.resolveCookieSession(context: context)
        do {
            let usage = try await Self.fetchUsageWithVibe(
                cookieHeader: session.cookieHeader,
                csrfToken: session.csrfToken,
                timeout: context.webTimeout,
                transport: self.transport)
            return self.makeResult(usage: usage.snapshot, sourceLabel: "web", diagnostic: usage.diagnostic)
        } catch MistralUsageError.invalidCredentials where cookieSource != .manual {
            #if os(macOS)
            CookieHeaderCache.clear(provider: .mistral)
            let excludedSourceLabels = if session.wasCached {
                Set<String>()
            } else {
                Set([session.sourceLabel].compactMap(\.self))
            }
            let sessions: AnySequence<MistralCookieImporter.SessionInfo>
            do {
                sessions = try MistralCookieImporter.sessionCandidates(
                    browserDetection: context.browserDetection,
                    excludingSourceLabels: excludedSourceLabels)
            } catch MistralCookieImportError.noCookies {
                throw MistralUsageError.invalidCredentials
            }
            let (usage, session) = try await Self.fetchUsageFromSessions(
                sessions,
                timeout: context.webTimeout,
                transport: self.transport)
            CookieHeaderCache.store(
                provider: .mistral,
                cookieHeader: session.cookieHeader,
                sourceLabel: session.sourceLabel)
            return self.makeResult(usage: usage.snapshot, sourceLabel: "web", diagnostic: usage.diagnostic)
            #else
            throw MistralUsageError.invalidCredentials
            #endif
        }
    }

    #if os(macOS)
    static func fetchUsageFromSessions(
        _ sessions: some Sequence<MistralCookieImporter.SessionInfo>,
        timeout: TimeInterval,
        transport: ProviderHTTPTransport = ProviderHTTPClient.shared) async throws
        -> (usage: BrowserUsage, session: MistralCookieImporter.SessionInfo)
    {
        for session in sessions {
            do {
                let usage = try await Self.fetchUsageWithVibe(
                    cookieHeader: session.cookieHeader,
                    csrfToken: session.csrfToken,
                    timeout: timeout,
                    transport: transport)
                return (usage, session)
            } catch MistralUsageError.invalidCredentials {
                continue
            }
        }
        throw MistralUsageError.invalidCredentials
    }
    #endif

    static func fetchUsageWithVibe(
        cookieHeader: String,
        csrfToken: String?,
        timeout: TimeInterval,
        transport: ProviderHTTPTransport = ProviderHTTPClient.shared) async throws -> BrowserUsage
    {
        let now = Date()
        let deadline = now.addingTimeInterval(timeout)
        let billing: Result<MistralUsageSnapshot, MistralUsageError>
        do {
            billing = try await .success(MistralUsageFetcher.fetchUsage(
                cookieHeader: cookieHeader,
                csrfToken: csrfToken,
                timeout: timeout,
                transport: transport))
        } catch let error as MistralUsageError where error.allowsPartialBilling {
            billing = .failure(error)
        }
        // Authorization failures still leave through the existing alternate-session recovery path.
        let snapshot = try? billing.get()
        var remaining = deadline.timeIntervalSinceNow
        let budgets: MistralSubscriptionBudgets? = if remaining > 0 {
            try await Self.fetchOptionalSubscriptionBudgets(
                cookieHeader: cookieHeader,
                timeout: min(remaining, 4),
                transport: transport)
        } else {
            nil
        }
        remaining = deadline.timeIntervalSinceNow
        // Require usable data from Admin before calling the separate console origin.
        let vibeResult: MistralUsageFetcher.MistralVibeUsageResult? = if budgets?.vibe == nil,
                                                                         snapshot != nil || budgets != nil,
                                                                         let csrfToken,
                                                                         remaining > 0
        {
            try await Self.fetchOptionalVibeUsage(
                csrfToken: csrfToken,
                cookieHeader: cookieHeader,
                timeout: min(remaining, 4),
                transport: transport)
        } else {
            nil
        }
        remaining = deadline.timeIntervalSinceNow
        let credits: MistralCreditsSnapshot? = if remaining > 0 {
            try await Self.fetchOptionalCredits(
                cookieHeader: cookieHeader,
                csrfToken: csrfToken,
                timeout: min(remaining, 4),
                transport: transport)
        } else {
            nil
        }
        var result: UsageSnapshot
        let diagnostic: String?
        switch billing {
        case let .success(billed):
            result = billed.with(credits: credits).toUsageSnapshot()
            diagnostic = nil
        case let .failure(error):
            let details = credits.flatMap { Self.partialCreditDetail($0) }.map { [$0] } ?? []
            guard budgets != nil || !details.isEmpty else { throw error }
            result = UsageSnapshot(primary: nil, secondary: nil, details: details, updatedAt: now)
            diagnostic = error.partialBillingDiagnostic
        }
        if let budgets {
            result = Self.attachSubscriptionBudgets(to: result, budgets: budgets)
        }
        return BrowserUsage(snapshot: Self.attachVibeWindow(to: result, vibeResult: vibeResult), diagnostic: diagnostic)
    }

    private static func partialCreditDetail(_ credits: MistralCreditsSnapshot) -> ProviderDetailSection? {
        try? ProviderDetailSection(title: self.creditDetailTitle, rows: [
            .init(label: "Balance", value: credits.formattedAvailableAmount, usageValue: credits.availableAmount),
        ])
    }

    static func fetchOptionalSubscriptionBudgets(
        cookieHeader: String,
        timeout: TimeInterval,
        transport: ProviderHTTPTransport = ProviderHTTPClient.shared) async throws
        -> MistralSubscriptionBudgets?
    {
        do {
            return try await MistralUsageFetcher.fetchSubscriptionBudgets(
                cookieHeader: cookieHeader,
                timeout: timeout,
                transport: transport)
        } catch {
            if error is CancellationError || (error as? URLError)?.code == .cancelled || Task.isCancelled {
                throw CancellationError()
            }
            self.logOptionalFailure("subscription allowance page", error: error)
            return nil
        }
    }

    static func fetchOptionalCredits(
        cookieHeader: String,
        csrfToken: String?,
        timeout: TimeInterval,
        transport: ProviderHTTPTransport = ProviderHTTPClient.shared) async throws
        -> MistralCreditsSnapshot?
    {
        do {
            return try await MistralUsageFetcher.fetchCredits(
                cookieHeader: cookieHeader,
                csrfToken: csrfToken,
                timeout: timeout,
                transport: transport)
        } catch {
            if error is CancellationError || (error as? URLError)?.code == .cancelled || Task.isCancelled {
                throw CancellationError()
            }
            self.logOptionalFailure("credits", error: error)
            return nil
        }
    }

    static func fetchOptionalVibeUsage(
        csrfToken: String,
        cookieHeader: String? = nil,
        timeout: TimeInterval,
        transport: ProviderHTTPTransport = ProviderHTTPClient.shared) async throws
        -> MistralUsageFetcher.MistralVibeUsageResult?
    {
        do {
            return try await MistralUsageFetcher.fetchVibeUsage(
                csrfToken: csrfToken,
                cookieHeader: cookieHeader,
                timeout: timeout,
                transport: transport)
        } catch {
            if error is CancellationError || (error as? URLError)?.code == .cancelled || Task.isCancelled {
                throw CancellationError()
            }
            self.logOptionalFailure("Vibe allowance", error: error)
            return nil
        }
    }

    static func attachSubscriptionBudgets(
        to usageSnapshot: UsageSnapshot,
        budgets: MistralSubscriptionBudgets) -> UsageSnapshot
    {
        let apiWindow = budgets.api.map { budget in
            RateWindow(
                usedPercent: budget.usagePercentage,
                windowMinutes: nil,
                resetsAt: budget.resetsAt,
                resetDescription: Self.budgetDescription(budget))
        }
        var extraWindows = usageSnapshot.extraRateWindows?.filter { $0.id != "mistral-monthly-plan" } ?? []
        if let vibe = budgets.vibe {
            let vibeWindow = RateWindow(
                usedPercent: vibe.usagePercentage,
                windowMinutes: nil,
                resetsAt: vibe.resetsAt,
                resetDescription: Self.budgetDescription(vibe))
            extraWindows.append(NamedRateWindow(
                id: "mistral-monthly-plan",
                title: "Monthly Plan",
                window: vibeWindow))
        }
        return usageSnapshot
            .with(primary: apiWindow, secondary: usageSnapshot.secondary)
            .with(extraRateWindows: extraWindows)
    }

    private static func budgetDescription(_ budget: MistralSubscriptionBudget) -> String {
        let used = UsageFormatter.currencyString(budget.usedAmount, currencyCode: budget.currencyCode)
        let limit = UsageFormatter.currencyString(budget.limit, currencyCode: budget.currencyCode)
        let remaining = UsageFormatter.currencyString(budget.remainingAmount, currencyCode: budget.currencyCode)
        return "\(used) / \(limit) · \(UsageFormatter.remainingString(from: remaining))"
    }

    static func attachVibeWindow(
        to usageSnapshot: UsageSnapshot,
        vibeResult: MistralUsageFetcher.MistralVibeUsageResult?) -> UsageSnapshot
    {
        guard let vibeResult else { return usageSnapshot }
        let window = RateWindow(
            usedPercent: vibeResult.usagePercentage,
            windowMinutes: nil,
            resetsAt: vibeResult.resetAt,
            resetDescription: nil)
        let named = NamedRateWindow(id: "mistral-monthly-plan", title: "Monthly Plan", window: window)
        let existing = usageSnapshot.extraRateWindows?.filter { $0.id != named.id } ?? []
        return usageSnapshot.with(extraRateWindows: existing + [named])
    }

    func shouldFallback(on _: Error, context _: ProviderFetchContext) -> Bool {
        false
    }

    func diagnostic(forPriorFailure error: Error) -> String? {
        guard let error = error as? MistralBudgetError else { return nil }
        return error.errorDescription
    }

    private static func logOptionalFailure(_ source: String, error: any Error) {
        let reason = switch error {
        case MistralUsageError.invalidCredentials: "session rejected"
        case MistralUsageError.parseFailed: "no usable data in response"
        case let MistralUsageError.httpStatus(status): "HTTP \(status)"
        case let MistralUsageError.apiError(detail): detail
        case let error as URLError: "network error (\(error.code.rawValue))"
        default: "request failed"
        }
        self.logger.debug("Mistral optional source unavailable", metadata: ["source": source, "reason": reason])
    }

    private static func resolveCookieSession(context: ProviderFetchContext) throws
        -> (cookieHeader: String, csrfToken: String?, sourceLabel: String?, wasCached: Bool)
    {
        if let settings = context.settings?.mistral, settings.cookieSource == .manual {
            if let header = CookieHeaderNormalizer.normalize(settings.manualCookieHeader) {
                let pairs = CookieHeaderNormalizer.pairs(from: header)
                let hasSessionCookie = pairs.contains { $0.name.hasPrefix("ory_session_") }
                if hasSessionCookie {
                    let csrfToken = pairs.first { $0.name == "csrftoken" }?.value
                    return (header, csrfToken, nil, false)
                }
            }
            throw MistralSettingsError.invalidCookie
        }

        #if os(macOS)
        if let cached = CookieHeaderCache.load(provider: .mistral),
           !cached.cookieHeader.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            let pairs = CookieHeaderNormalizer.pairs(from: cached.cookieHeader)
            let csrfToken = pairs.first { $0.name == "csrftoken" }?.value
            return (cached.cookieHeader, csrfToken, cached.sourceLabel, true)
        }
        let session = try MistralCookieImporter.importSession(browserDetection: context.browserDetection)
        CookieHeaderCache.store(
            provider: .mistral,
            cookieHeader: session.cookieHeader,
            sourceLabel: session.sourceLabel)
        return (session.cookieHeader, session.csrfToken, session.sourceLabel, false)
        #else
        throw MistralSettingsError.missingCookie
        #endif
    }
}
