import Foundation
import SweetCookieKit

public enum MistralProviderDescriptor {
    public static let descriptor: ProviderDescriptor = Self.makeDescriptor()
    /// Extra rate window carrying the Vibe Code plan allowance (settings metric "Monthly Plan").
    public static let monthlyPlanWindowID = "mistral-monthly-plan"
    public static let monthlyPlanWindowTitle = "Monthly Plan"
    private static let credentials = ProviderCredentialAdapter(tokenAccountSupport: TokenAccountSupport(
        title: "Session tokens",
        subtitle: "Store multiple Mistral Cookie headers.",
        placeholder: "Cookie: …",
        injection: .cookieHeader,
        requiresManualCookieSource: true,
        cookieName: nil))

    /// Preserve Chrome-first behavior, then Firefox and Safari; other Chromium forks remain manual-only.
    private static var browserCookieOrder: BrowserCookieImportOrder? {
        #if os(macOS)
        [.chrome, .firefox, .safari]
        #else
        nil
        #endif
    }

    static func makeDescriptor() -> ProviderDescriptor {
        ProviderDescriptor(
            id: .mistral,
            menuBarMetrics: ProviderMenuBarMetricCapabilities(
                supported: [.automatic, .primary, .monthlyPlan],
                // Exposes a "Monthly Plan %" token in the menu bar layout editor for the Vibe plan allowance.
                namedExtras: [monthlyPlanWindowID: self.monthlyPlanWindowTitle]),
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
                browserCookieOrder: self.browserCookieOrder,
                dashboardURL: "https://admin.mistral.ai/organization/usage",
                statusPageURL: nil,
                statusLinkURL: "https://status.mistral.ai"),
            branding: ProviderBranding(
                iconStyle: .init(provider: .mistral),
                iconResourceName: "ProviderIcon-mistral",
                color: ProviderColor(red: 255 / 255, green: 80 / 255, blue: 15 / 255),
                confettiPalette: [
                    ProviderColor(hex: 0xFA500F),
                    ProviderColor(hex: 0xFFAF01),
                    ProviderColor(hex: 0xFFE000),
                ]),
            tokenCost: ProviderTokenCostConfig(
                supportsTokenCost: true,
                noDataMessage: { "Mistral cost history needs a billing web session." },
                menuHintLines: [.literal("Reported by Mistral billing usage.")],
                showsCostMenuSection: false,
                primaryValue: .latestDaily),
            presentation: ProviderUsagePresentation(
                rateWindowLabeler: { metadata, snapshot, _ in
                    ProviderRateWindowLabels(
                        primary: snapshot.primary == nil ? metadata.sessionLabel : "Included API",
                        secondary: metadata.weeklyLabel,
                        tertiary: metadata.opusLabel ?? "Sonnet",
                        showsTertiary: metadata.supportsOpus)
                },
                identityPresenter: { _, snapshot in
                    // Plan labels already use Mistral's display names ("Pro", "API pay-as-you-go"); skip
                    // the default `.capitalized` pass that would turn "API" into "Api".
                    guard let plan = snapshot.mistralUsage?.account?.planLabel, !plan.isEmpty else {
                        return ProviderIdentityPresentation(badge: nil, plan: nil)
                    }
                    return ProviderIdentityPresentation(badge: plan, plan: plan)
                },
                extraRateWindowSelector: { snapshot in
                    snapshot.extraRateWindows?.filter { $0.id == Self.monthlyPlanWindowID } ?? []
                },
                menuBarLayoutPrimaryLabel: "Included API",
                menuBarWindowResolver: { context in
                    switch context.metric {
                    case .automatic:
                        // Plan accounts: show the most constrained allowance (Included API or Vibe plan).
                        // Pay-as-you-go accounts have no allowance window and keep showing API spend.
                        .resolved(ProviderUsagePresentation.mostConstrained(
                            context.snapshot.primary,
                            context.snapshot.extraRateWindows?.first { $0.id == Self.monthlyPlanWindowID }?.window))
                    case .monthlyPlan:
                        .resolved(context.snapshot.extraRateWindows?.first { $0.id == Self.monthlyPlanWindowID }?
                            .window)
                    default:
                        .unhandled
                    }
                }, menuCard: ProviderMenuCardPresentation(
                    usesProviderCostHistoryAsPrimaryDashboard: true,
                    primaryCostHistoryResolver: { snapshot, tokenSnapshot in
                        if let projected = snapshot?.mistralUsage?.toCostUsageTokenSnapshot() {
                            return projected
                        }
                        return snapshot == nil ? tokenSnapshot : nil
                    },
                    showsPrimaryBalanceDescription: true,
                    hidesPrimaryResetWithoutDate: true,
                    extraRateWindowUsesResetDescriptionAsDetail: { $0.id == Self.monthlyPlanWindowID }),
                menu: ProviderMenuDescriptorPresentation(primaryDescriptionIsDetail: { _ in true })),
            fetchPlan: ProviderFetchPlan(
                sourceModes: [.auto, .web],
                pipeline: ProviderFetchPipeline(resolveStrategies: { _ in [MistralWebFetchStrategy()] })),
            cli: ProviderCLIConfig(
                name: "mistral",
                aliases: ["mistral-ai"],
                versionDetector: nil))
    }
}

struct MistralWebFetchStrategy: ProviderFetchStrategy {
    let id: String = "mistral.web"
    let kind: ProviderFetchKind = .web

    func isAvailable(_ context: ProviderFetchContext) async -> Bool {
        guard context.settings?.mistral?.cookieSource != .off else { return false }
        return true
    }

    func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        let cookieSource = context.settings?.mistral?.cookieSource ?? .auto
        let session = try Self.resolveCookieSession(context: context, allowCached: true)
        do {
            let csrf = session.csrfToken
            let usage = try await Self.fetchUsageWithVibe(
                cookieHeader: session.cookieHeader,
                csrfToken: csrf,
                timeout: context.webTimeout)
            return self.makeResult(
                usage: usage,
                sourceLabel: "web")
        } catch MistralUsageError.invalidCredentials where cookieSource != .manual {
            #if os(macOS)
            CookieHeaderCache.clear(provider: .mistral)
            let excludedSourceLabels = if session.wasCached {
                Set<String>()
            } else {
                Set([session.sourceLabel].compactMap(\.self))
            }
            let sessions: [MistralCookieImporter.SessionInfo]
            do {
                sessions = try MistralCookieImporter.importSessions(
                    browserDetection: context.browserDetection,
                    excludingSourceLabels: excludedSourceLabels)
            } catch MistralCookieImportError.noCookies {
                throw MistralUsageError.invalidCredentials
            }
            let (usage, session) = try await Self.fetchUsageFromSessions(
                sessions,
                timeout: context.webTimeout)
            CookieHeaderCache.store(
                provider: .mistral,
                cookieHeader: session.cookieHeader,
                sourceLabel: session.sourceLabel)
            return self.makeResult(
                usage: usage,
                sourceLabel: "web")
            #else
            throw MistralUsageError.invalidCredentials
            #endif
        }
    }

    #if os(macOS)
    static func fetchUsageFromSessions(
        _ sessions: [MistralCookieImporter.SessionInfo],
        timeout: TimeInterval,
        transport: ProviderHTTPTransport = ProviderHTTPClient.shared) async throws
        -> (usage: UsageSnapshot, session: MistralCookieImporter.SessionInfo)
    {
        for session in sessions {
            do {
                let csrf = session.csrfToken
                let usage = try await Self.fetchUsageWithVibe(
                    cookieHeader: session.cookieHeader,
                    csrfToken: csrf,
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
        transport: ProviderHTTPTransport = ProviderHTTPClient.shared) async throws -> UsageSnapshot
    {
        let deadline = Date().addingTimeInterval(timeout)
        let snapshot = try await MistralUsageFetcher.fetchUsage(
            cookieHeader: cookieHeader,
            csrfToken: csrfToken,
            timeout: timeout,
            transport: transport)
        var remaining = deadline.timeIntervalSinceNow
        let budgets: MistralSubscriptionBudgets? = if remaining > 0 {
            try await Self.fetchOptionalSubscriptionBudgets(
                cookieHeader: cookieHeader,
                csrfToken: csrfToken,
                timeout: min(remaining, 4),
                transport: transport)
        } else {
            nil
        }
        remaining = deadline.timeIntervalSinceNow
        let vibeResult: MistralUsageFetcher.MistralVibeUsageResult? = if budgets?.vibe == nil,
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
        remaining = deadline.timeIntervalSinceNow
        let account: MistralAccountSnapshot? = if remaining > 0 {
            try await Self.fetchOptionalAccount(
                cookieHeader: cookieHeader,
                csrfToken: csrfToken,
                timeout: min(remaining, 4),
                transport: transport)
        } else {
            nil
        }
        var result = snapshot.with(credits: credits).with(account: account).toUsageSnapshot()
        if let budgets {
            result = Self.attachSubscriptionBudgets(to: result, budgets: budgets)
        }
        return Self.attachVibeWindow(to: result, vibeResult: vibeResult)
    }

    /// Allowances come from the JSON budget endpoint first. The subscription page scrape fills whatever the
    /// endpoint left out (unavailable endpoint, or a partial record with only one allowance) so an existing
    /// Monthly Plan window never disappears because the JSON answer was incomplete. Both are best-effort.
    static func fetchOptionalSubscriptionBudgets(
        cookieHeader: String,
        csrfToken: String? = nil,
        timeout: TimeInterval,
        transport: ProviderHTTPTransport = ProviderHTTPClient.shared) async throws
        -> MistralSubscriptionBudgets?
    {
        let deadline = Date().addingTimeInterval(timeout)
        let fromEndpoint = try await Self.optional {
            try await MistralUsageFetcher.fetchBudget(
                cookieHeader: cookieHeader,
                csrfToken: csrfToken,
                timeout: timeout,
                transport: transport)
        }
        if let fromEndpoint, fromEndpoint.api != nil, fromEndpoint.vibe != nil {
            return fromEndpoint
        }
        let remaining = deadline.timeIntervalSinceNow
        guard remaining > 0 else { return fromEndpoint }
        let fromPage = try await Self.optional {
            try await MistralUsageFetcher.fetchSubscriptionBudgets(
                cookieHeader: cookieHeader,
                timeout: remaining,
                transport: transport)
        }
        return Self.mergedBudgets(preferred: fromEndpoint, fallback: fromPage)
    }

    /// Field-wise merge: the preferred source wins per allowance, the fallback fills the gaps.
    static func mergedBudgets(
        preferred: MistralSubscriptionBudgets?,
        fallback: MistralSubscriptionBudgets?) -> MistralSubscriptionBudgets?
    {
        guard preferred != nil || fallback != nil else { return nil }
        return MistralSubscriptionBudgets(
            api: preferred?.api ?? fallback?.api,
            vibe: preferred?.vibe ?? fallback?.vibe)
    }

    static func fetchOptionalAccount(
        cookieHeader: String,
        csrfToken: String?,
        timeout: TimeInterval,
        transport: ProviderHTTPTransport = ProviderHTTPClient.shared) async throws
        -> MistralAccountSnapshot?
    {
        try await self.optional {
            try await MistralUsageFetcher.fetchAccount(
                cookieHeader: cookieHeader,
                csrfToken: csrfToken,
                timeout: timeout,
                transport: transport)
        }
    }

    /// Runs a best-effort request: ordinary failures yield nil, cancellation still propagates.
    private static func optional<T>(_ body: () async throws -> T) async throws -> T? {
        do {
            return try await body()
        } catch {
            if error is CancellationError || (error as? URLError)?.code == .cancelled || Task.isCancelled {
                throw CancellationError()
            }
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
        try await self.optional {
            try await MistralUsageFetcher.fetchCredits(
                cookieHeader: cookieHeader,
                csrfToken: csrfToken,
                timeout: timeout,
                transport: transport)
        }
    }

    static func fetchOptionalVibeUsage(
        csrfToken: String,
        cookieHeader: String? = nil,
        timeout: TimeInterval,
        transport: ProviderHTTPTransport = ProviderHTTPClient.shared) async throws
        -> MistralUsageFetcher.MistralVibeUsageResult?
    {
        try await self.optional {
            try await MistralUsageFetcher.fetchVibeUsage(
                csrfToken: csrfToken,
                cookieHeader: cookieHeader,
                timeout: timeout,
                transport: transport)
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
        var extraWindows = usageSnapshot.extraRateWindows?
            .filter { $0.id != MistralProviderDescriptor.monthlyPlanWindowID } ?? []
        if let vibe = budgets.vibe {
            let vibeWindow = RateWindow(
                usedPercent: vibe.usagePercentage,
                windowMinutes: nil,
                resetsAt: vibe.resetsAt,
                resetDescription: Self.budgetDescription(vibe))
            extraWindows.append(NamedRateWindow(
                id: MistralProviderDescriptor.monthlyPlanWindowID,
                title: MistralProviderDescriptor.monthlyPlanWindowTitle,
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
        let named = NamedRateWindow(
            id: MistralProviderDescriptor.monthlyPlanWindowID,
            title: MistralProviderDescriptor.monthlyPlanWindowTitle,
            window: window)
        let existing = usageSnapshot.extraRateWindows?.filter { $0.id != named.id } ?? []
        return usageSnapshot.with(extraRateWindows: existing + [named])
    }

    func shouldFallback(on _: Error, context _: ProviderFetchContext) -> Bool {
        false
    }

    private static func resolveCookieSession(
        context: ProviderFetchContext,
        allowCached: Bool) throws
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
        if allowCached,
           let cached = CookieHeaderCache.load(provider: .mistral),
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
