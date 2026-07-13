import Foundation

public struct RateWindow: Codable, Equatable, Sendable {
    public let usedPercent: Double
    public let windowMinutes: Int?
    public let resetsAt: Date?
    /// Optional textual reset description (used by Claude CLI UI scrape).
    public let resetDescription: String?
    /// Optional percent restored on the next regeneration tick for providers with rolling recovery.
    public let nextRegenPercent: Double?
    /// Whether this window was synthesized to stand in for a quota lane the provider did not actually
    /// report, rather than being a real zero-usage window.
    ///
    /// Claude web returns a `0%` five-hour window when `five_hour` is `null` (an account with no live
    /// session but a real weekly lane). Lane classifiers — e.g. the combined "Session + Weekly" menu-bar
    /// metric — must treat such a window as "no session lane present" instead of surfacing a phantom
    /// `5h 0%`/`5h 100%` session. A genuine session, even one freshly reset to 0%, is NOT a placeholder.
    /// Missing values decode as `false` for older cached payloads.
    public let isSyntheticPlaceholder: Bool

    public init(
        usedPercent: Double,
        windowMinutes: Int?,
        resetsAt: Date?,
        resetDescription: String?,
        nextRegenPercent: Double? = nil,
        isSyntheticPlaceholder: Bool = false)
    {
        self.usedPercent = usedPercent
        self.windowMinutes = windowMinutes
        self.resetsAt = resetsAt
        self.resetDescription = resetDescription
        self.nextRegenPercent = nextRegenPercent
        self.isSyntheticPlaceholder = isSyntheticPlaceholder
    }

    private enum CodingKeys: String, CodingKey {
        case usedPercent
        case windowMinutes
        case resetsAt
        case resetDescription
        case nextRegenPercent
        case isSyntheticPlaceholder
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.usedPercent = try container.decode(Double.self, forKey: .usedPercent)
        self.windowMinutes = try container.decodeIfPresent(Int.self, forKey: .windowMinutes)
        self.resetsAt = try container.decodeIfPresent(Date.self, forKey: .resetsAt)
        self.resetDescription = try container.decodeIfPresent(String.self, forKey: .resetDescription)
        self.nextRegenPercent = try container.decodeIfPresent(Double.self, forKey: .nextRegenPercent)
        self.isSyntheticPlaceholder =
            try container.decodeIfPresent(Bool.self, forKey: .isSyntheticPlaceholder) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.usedPercent, forKey: .usedPercent)
        try container.encodeIfPresent(self.windowMinutes, forKey: .windowMinutes)
        try container.encodeIfPresent(self.resetsAt, forKey: .resetsAt)
        try container.encodeIfPresent(self.resetDescription, forKey: .resetDescription)
        try container.encodeIfPresent(self.nextRegenPercent, forKey: .nextRegenPercent)
        // Only persist the flag when set, keeping payloads identical for the common (real-window) case.
        if self.isSyntheticPlaceholder {
            try container.encode(true, forKey: .isSyntheticPlaceholder)
        }
    }

    public var remainingPercent: Double {
        max(0, 100 - self.usedPercent)
    }

    public func backfillingResetTime(from cached: RateWindow?, now: Date = .init()) -> RateWindow {
        if self.resetsAt != nil {
            return self
        }
        guard let cachedReset = cached?.resetsAt, cachedReset > now else { return self }
        let windowMinutes = if let windowMinutes = self.windowMinutes, windowMinutes > 0 {
            windowMinutes
        } else {
            cached?.windowMinutes
        }
        return RateWindow(
            usedPercent: self.usedPercent,
            windowMinutes: windowMinutes,
            resetsAt: cachedReset,
            resetDescription: self.resetDescription ?? cached?.resetDescription,
            nextRegenPercent: self.nextRegenPercent,
            // Preserve the placeholder marker: backfilling a stale reset onto Claude web's null-session
            // placeholder must not let it masquerade as a real session lane.
            isSyntheticPlaceholder: self.isSyntheticPlaceholder)
    }
}

public struct NamedRateWindow: Codable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let window: RateWindow
    /// Whether `window.usedPercent` reflects known quota usage.
    ///
    /// Some providers expose reset metadata for a named quota window before
    /// they expose remaining usage. Keep those windows visible for reset/debug
    /// context, but mark them so clients do not render `usedPercent` as a real
    /// exhausted quota. Missing values decode as `true` for older cached payloads.
    public let usageKnown: Bool

    public init(id: String, title: String, window: RateWindow, usageKnown: Bool = true) {
        self.id = id
        self.title = title
        self.window = window
        self.usageKnown = usageKnown
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case title
        case window
        case usageKnown
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(String.self, forKey: .id)
        self.title = try container.decode(String.self, forKey: .title)
        self.window = try container.decode(RateWindow.self, forKey: .window)
        self.usageKnown = try container.decodeIfPresent(Bool.self, forKey: .usageKnown) ?? true
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.id, forKey: .id)
        try container.encode(self.title, forKey: .title)
        try container.encode(self.window, forKey: .window)
        if !self.usageKnown {
            try container.encode(false, forKey: .usageKnown)
        }
    }
}

public struct ProviderIdentitySnapshot: Codable, Sendable {
    public let providerID: UsageProvider?
    public let accountEmail: String?
    public let accountOrganization: String?
    public let loginMethod: String?

    public init(
        providerID: UsageProvider?,
        accountEmail: String?,
        accountOrganization: String?,
        loginMethod: String?)
    {
        self.providerID = providerID
        self.accountEmail = accountEmail
        self.accountOrganization = accountOrganization
        self.loginMethod = loginMethod
    }

    public func scoped(to provider: UsageProvider) -> ProviderIdentitySnapshot {
        if self.providerID == provider {
            return self
        }
        return ProviderIdentitySnapshot(
            providerID: provider,
            accountEmail: self.accountEmail,
            accountOrganization: self.accountOrganization,
            loginMethod: self.loginMethod)
    }
}

public enum UsageDataConfidence: String, Codable, Equatable, Sendable {
    case exact
    case estimated
    case percentOnly
    case unknown
}

public struct UsageSnapshot: Codable, Sendable {
    public let primary: RateWindow?
    public let secondary: RateWindow?
    public let tertiary: RateWindow?
    public let extraRateWindows: [NamedRateWindow]?
    public let providerCost: ProviderCostSnapshot?
    public let kiroUsage: KiroUsageDetails?
    public let ampUsage: AmpUsageDetails?
    public let zaiUsage: ZaiUsageSnapshot?
    public let minimaxUsage: MiniMaxUsageSnapshot?
    public let deepseekUsage: DeepSeekUsageSummary?
    public let mimoUsage: MiMoUsageSnapshot?
    public let openRouterUsage: OpenRouterUsageSnapshot?
    public let sakanaPayAsYouGo: SakanaPayAsYouGoSnapshot?
    public let crossModelUsage: CrossModelUsageSnapshot?
    public let clawRouterUsage: ClawRouterUsageSnapshot?
    public let sub2APIUsage: Sub2APIUsageDetails?
    public let wayfinderUsage: WayfinderUsageSnapshot?
    public let openAIAPIUsage: OpenAIAPIUsageSnapshot?
    public let codexResetCredits: CodexRateLimitResetCreditsSnapshot?
    public let claudeAdminAPIUsage: ClaudeAdminAPIUsageSnapshot?
    public let mistralUsage: MistralUsageSnapshot?
    public let deepgramUsage: DeepgramUsageSnapshot?
    public let poeUsage: PoeUsageHistorySnapshot?
    public let cursorRequests: CursorRequestUsage?
    /// Live-only marker for optional Command Code subscription lookup failure.
    public let commandCodeSubscriptionEnrichmentUnavailable: Bool
    /// Live-only marker that Command Code returned a recognized subscription plan.
    public let commandCodeHasSubscriptionPlan: Bool
    /// Live-only marker that Command Code's monthly grant has no remaining credits.
    public let commandCodeMonthlyGrantDepleted: Bool
    public let subscriptionExpiresAt: Date?
    public let subscriptionRenewsAt: Date?
    public let updatedAt: Date
    public let identity: ProviderIdentitySnapshot?
    public let dataConfidence: UsageDataConfidence

    private enum CodingKeys: String, CodingKey {
        case primary
        case secondary
        case tertiary
        case extraRateWindows
        case providerCost
        case kiroUsage
        case ampUsage
        case mimoUsage
        case openRouterUsage
        case sakanaPayAsYouGo
        case crossModelUsage
        case clawRouterUsage
        case sub2APIUsage
        case wayfinderUsage
        case openAIAPIUsage
        case codexResetCredits
        case claudeAdminAPIUsage
        case mistralUsage
        case deepgramUsage
        case poeUsage
        case subscriptionExpiresAt
        case subscriptionRenewsAt
        case updatedAt
        case identity
        case dataConfidence
        case accountEmail
        case accountOrganization
        case loginMethod
    }

    public init(
        primary: RateWindow?,
        secondary: RateWindow?,
        tertiary: RateWindow? = nil,
        extraRateWindows: [NamedRateWindow]? = nil,
        kiroUsage: KiroUsageDetails? = nil,
        ampUsage: AmpUsageDetails? = nil,
        providerCost: ProviderCostSnapshot? = nil,
        zaiUsage: ZaiUsageSnapshot? = nil,
        minimaxUsage: MiniMaxUsageSnapshot? = nil,
        deepseekUsage: DeepSeekUsageSummary? = nil,
        mimoUsage: MiMoUsageSnapshot? = nil,
        openRouterUsage: OpenRouterUsageSnapshot? = nil,
        sakanaPayAsYouGo: SakanaPayAsYouGoSnapshot? = nil,
        crossModelUsage: CrossModelUsageSnapshot? = nil,
        clawRouterUsage: ClawRouterUsageSnapshot? = nil,
        sub2APIUsage: Sub2APIUsageDetails? = nil,
        wayfinderUsage: WayfinderUsageSnapshot? = nil,
        openAIAPIUsage: OpenAIAPIUsageSnapshot? = nil,
        codexResetCredits: CodexRateLimitResetCreditsSnapshot? = nil,
        claudeAdminAPIUsage: ClaudeAdminAPIUsageSnapshot? = nil,
        mistralUsage: MistralUsageSnapshot? = nil,
        deepgramUsage: DeepgramUsageSnapshot? = nil,
        poeUsage: PoeUsageHistorySnapshot? = nil,
        cursorRequests: CursorRequestUsage? = nil,
        commandCodeSubscriptionEnrichmentUnavailable: Bool = false,
        commandCodeHasSubscriptionPlan: Bool = false,
        commandCodeMonthlyGrantDepleted: Bool = false,
        subscriptionExpiresAt: Date? = nil,
        subscriptionRenewsAt: Date? = nil,
        updatedAt: Date,
        identity: ProviderIdentitySnapshot? = nil,
        dataConfidence: UsageDataConfidence = .unknown)
    {
        self.primary = primary
        self.secondary = secondary
        self.tertiary = tertiary
        self.extraRateWindows = extraRateWindows
        self.kiroUsage = kiroUsage
        self.ampUsage = ampUsage
        self.providerCost = providerCost
        self.zaiUsage = zaiUsage
        self.minimaxUsage = minimaxUsage
        self.deepseekUsage = deepseekUsage
        self.mimoUsage = mimoUsage
        self.openRouterUsage = openRouterUsage
        self.sakanaPayAsYouGo = sakanaPayAsYouGo
        self.crossModelUsage = crossModelUsage
        self.clawRouterUsage = clawRouterUsage
        self.sub2APIUsage = sub2APIUsage
        self.wayfinderUsage = wayfinderUsage
        self.openAIAPIUsage = openAIAPIUsage
        self.codexResetCredits = codexResetCredits
        self.claudeAdminAPIUsage = claudeAdminAPIUsage
        self.mistralUsage = mistralUsage
        self.deepgramUsage = deepgramUsage
        self.poeUsage = poeUsage
        self.cursorRequests = cursorRequests
        self.commandCodeSubscriptionEnrichmentUnavailable = commandCodeSubscriptionEnrichmentUnavailable
        self.commandCodeHasSubscriptionPlan = commandCodeHasSubscriptionPlan
        self.commandCodeMonthlyGrantDepleted = commandCodeMonthlyGrantDepleted
        self.subscriptionExpiresAt = subscriptionExpiresAt
        self.subscriptionRenewsAt = subscriptionRenewsAt
        self.updatedAt = updatedAt
        self.identity = identity
        self.dataConfidence = dataConfidence
    }

    public func with(extraRateWindows: [NamedRateWindow]?) -> UsageSnapshot {
        self.replacing(extraRateWindows: .value(extraRateWindows))
    }

    public func withCodexResetCredits(_ resetCredits: CodexRateLimitResetCreditsSnapshot?) -> UsageSnapshot {
        self.replacing(codexResetCredits: .value(resetCredits))
    }

    public func with(primary: RateWindow?, secondary: RateWindow?) -> UsageSnapshot {
        self.replacing(
            primary: .value(primary),
            secondary: .value(secondary))
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.primary = try container.decodeIfPresent(RateWindow.self, forKey: .primary)
        self.secondary = try container.decodeIfPresent(RateWindow.self, forKey: .secondary)
        self.tertiary = try container.decodeIfPresent(RateWindow.self, forKey: .tertiary)
        self.extraRateWindows = try container.decodeIfPresent([NamedRateWindow].self, forKey: .extraRateWindows)
        self.providerCost = try container.decodeIfPresent(ProviderCostSnapshot.self, forKey: .providerCost)
        self.kiroUsage = try container.decodeIfPresent(KiroUsageDetails.self, forKey: .kiroUsage)
        self.ampUsage = try container.decodeIfPresent(AmpUsageDetails.self, forKey: .ampUsage)
        self.zaiUsage = nil // Not persisted, fetched fresh each time
        self.minimaxUsage = nil // Not persisted, fetched fresh each time
        self.deepseekUsage = nil // Not persisted, fetched fresh each time
        self.mimoUsage = try container.decodeIfPresent(MiMoUsageSnapshot.self, forKey: .mimoUsage)
        self.openRouterUsage = try container.decodeIfPresent(OpenRouterUsageSnapshot.self, forKey: .openRouterUsage)
        self.sakanaPayAsYouGo = try container.decodeIfPresent(
            SakanaPayAsYouGoSnapshot.self,
            forKey: .sakanaPayAsYouGo)
        self.crossModelUsage = try container.decodeIfPresent(CrossModelUsageSnapshot.self, forKey: .crossModelUsage)
        self.clawRouterUsage = try container.decodeIfPresent(ClawRouterUsageSnapshot.self, forKey: .clawRouterUsage)
        self.sub2APIUsage = try container.decodeIfPresent(Sub2APIUsageDetails.self, forKey: .sub2APIUsage)
        self.wayfinderUsage = try container.decodeIfPresent(WayfinderUsageSnapshot.self, forKey: .wayfinderUsage)
        self.openAIAPIUsage = try container.decodeIfPresent(OpenAIAPIUsageSnapshot.self, forKey: .openAIAPIUsage)
        self.codexResetCredits = try container.decodeIfPresent(
            CodexRateLimitResetCreditsSnapshot.self,
            forKey: .codexResetCredits)
        self.claudeAdminAPIUsage = try container.decodeIfPresent(
            ClaudeAdminAPIUsageSnapshot.self,
            forKey: .claudeAdminAPIUsage)
        self.mistralUsage = try container.decodeIfPresent(MistralUsageSnapshot.self, forKey: .mistralUsage)
        self.deepgramUsage = try container.decodeIfPresent(DeepgramUsageSnapshot.self, forKey: .deepgramUsage)
        self.poeUsage = try container.decodeIfPresent(PoeUsageHistorySnapshot.self, forKey: .poeUsage)
        self.cursorRequests = nil // Not persisted, fetched fresh each time
        self.commandCodeSubscriptionEnrichmentUnavailable = false // Live-only fetch state
        self.commandCodeHasSubscriptionPlan = false // Live-only fetch state
        self.commandCodeMonthlyGrantDepleted = false // Live-only fetch state
        self.subscriptionExpiresAt = try container.decodeIfPresent(Date.self, forKey: .subscriptionExpiresAt)
        self.subscriptionRenewsAt = try container.decodeIfPresent(Date.self, forKey: .subscriptionRenewsAt)
        self.updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        if let dataConfidence = try container.decodeIfPresent(String.self, forKey: .dataConfidence) {
            self.dataConfidence = UsageDataConfidence(rawValue: dataConfidence) ?? .unknown
        } else {
            self.dataConfidence = .unknown
        }
        if let identity = try container.decodeIfPresent(ProviderIdentitySnapshot.self, forKey: .identity) {
            self.identity = identity
        } else {
            let email = try container.decodeIfPresent(String.self, forKey: .accountEmail)
            let organization = try container.decodeIfPresent(String.self, forKey: .accountOrganization)
            let loginMethod = try container.decodeIfPresent(String.self, forKey: .loginMethod)
            if email != nil || organization != nil || loginMethod != nil {
                self.identity = ProviderIdentitySnapshot(
                    providerID: nil,
                    accountEmail: email,
                    accountOrganization: organization,
                    loginMethod: loginMethod)
            } else {
                self.identity = nil
            }
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        // Stable JSON schema: keep window keys present (encode `nil` as `null`).
        try container.encode(self.primary, forKey: .primary)
        try container.encode(self.secondary, forKey: .secondary)
        try container.encode(self.tertiary, forKey: .tertiary)
        try container.encodeIfPresent(self.extraRateWindows, forKey: .extraRateWindows)
        try container.encodeIfPresent(self.providerCost, forKey: .providerCost)
        try container.encodeIfPresent(self.kiroUsage, forKey: .kiroUsage)
        try container.encodeIfPresent(self.ampUsage, forKey: .ampUsage)
        try container.encodeIfPresent(self.mimoUsage, forKey: .mimoUsage)
        try container.encodeIfPresent(self.openRouterUsage, forKey: .openRouterUsage)
        try container.encodeIfPresent(self.sakanaPayAsYouGo, forKey: .sakanaPayAsYouGo)
        try container.encodeIfPresent(self.crossModelUsage, forKey: .crossModelUsage)
        try container.encodeIfPresent(self.clawRouterUsage, forKey: .clawRouterUsage)
        try container.encodeIfPresent(self.sub2APIUsage, forKey: .sub2APIUsage)
        try container.encodeIfPresent(self.wayfinderUsage, forKey: .wayfinderUsage)
        try container.encodeIfPresent(self.openAIAPIUsage, forKey: .openAIAPIUsage)
        try container.encodeIfPresent(self.codexResetCredits, forKey: .codexResetCredits)
        try container.encodeIfPresent(self.claudeAdminAPIUsage, forKey: .claudeAdminAPIUsage)
        try container.encodeIfPresent(self.mistralUsage, forKey: .mistralUsage)
        try container.encodeIfPresent(self.deepgramUsage, forKey: .deepgramUsage)
        try container.encodeIfPresent(self.poeUsage, forKey: .poeUsage)
        try container.encodeIfPresent(self.subscriptionExpiresAt, forKey: .subscriptionExpiresAt)
        try container.encodeIfPresent(self.subscriptionRenewsAt, forKey: .subscriptionRenewsAt)
        try container.encode(self.updatedAt, forKey: .updatedAt)
        try container.encodeIfPresent(self.identity, forKey: .identity)
        if self.dataConfidence != .unknown {
            try container.encode(self.dataConfidence, forKey: .dataConfidence)
        }
        try container.encodeIfPresent(self.identity?.accountEmail, forKey: .accountEmail)
        try container.encodeIfPresent(self.identity?.accountOrganization, forKey: .accountOrganization)
        try container.encodeIfPresent(self.identity?.loginMethod, forKey: .loginMethod)
    }

    public func identity(for provider: UsageProvider) -> ProviderIdentitySnapshot? {
        guard let identity, identity.providerID == provider else { return nil }
        return identity
    }

    public func automaticPerplexityWindow() -> RateWindow? {
        let fallbackWindows = self.orderedPerplexityFallbackWindows()
        guard let primary = self.primary else {
            return fallbackWindows.first
        }
        if primary.remainingPercent > 0 || fallbackWindows.isEmpty {
            return primary
        }
        return fallbackWindows.first
    }

    public func orderedPerplexityDisplayWindows() -> [RateWindow] {
        let fallbackWindows = self.orderedPerplexityFallbackWindows()
        guard let primary = self.primary else {
            return fallbackWindows
        }
        if primary.remainingPercent > 0 || fallbackWindows.isEmpty {
            return [primary] + fallbackWindows
        }
        return fallbackWindows + [primary]
    }

    public func switcherWeeklyWindow(for provider: UsageProvider, showUsed: Bool) -> RateWindow? {
        switch provider {
        case .factory:
            // Factory prefers secondary window
            return self.secondary ?? self.primary
        case .perplexity:
            return self.automaticPerplexityWindow()
        case .cursor:
            // Cursor: fall back to on-demand budget when the included plan is exhausted (only in
            // "show remaining" mode). The secondary/tertiary lanes are Total/Auto/API breakdowns,
            // not extra capacity, so they should not replace the remaining paid quota indicator.
            if !showUsed,
               let primary = self.primary,
               primary.remainingPercent <= 0,
               let providerCost = self.providerCost,
               providerCost.limit > 0
            {
                let usedPercent = max(0, min(100, (providerCost.used / providerCost.limit) * 100))
                return RateWindow(
                    usedPercent: usedPercent,
                    windowMinutes: nil,
                    resetsAt: providerCost.resetsAt,
                    resetDescription: nil)
            }
            return self.primary ?? self.secondary
        default:
            return self.primary ?? self.secondary
        }
    }

    public func accountEmail(for provider: UsageProvider) -> String? {
        self.identity(for: provider)?.accountEmail
    }

    public func accountOrganization(for provider: UsageProvider) -> String? {
        self.identity(for: provider)?.accountOrganization
    }

    public func loginMethod(for provider: UsageProvider) -> String? {
        self.identity(for: provider)?.loginMethod
    }

    public var hasRateLimitWindows: Bool {
        self.primary != nil || self.secondary != nil || self.tertiary != nil ||
            !(self.extraRateWindows?.isEmpty ?? true)
    }

    public func rateLimitsUnavailable(for provider: UsageProvider) -> Bool {
        UsageLimitsAvailability.resolve(provider: provider, snapshot: self).isUnavailable
    }

    public func withIdentity(_ identity: ProviderIdentitySnapshot?) -> UsageSnapshot {
        self.replacing(identity: .value(identity))
    }

    public func withDataConfidence(_ dataConfidence: UsageDataConfidence) -> UsageSnapshot {
        self.replacing(dataConfidence: .value(dataConfidence))
    }

    public func scoped(to provider: UsageProvider) -> UsageSnapshot {
        guard let identity else { return self }
        let scopedIdentity = identity.scoped(to: provider)
        if scopedIdentity.providerID == identity.providerID {
            return self
        }
        return self.withIdentity(scopedIdentity)
    }

    public func backfillingResetTimes(from cached: UsageSnapshot?, now: Date = .init()) -> UsageSnapshot {
        guard let cached else { return self }
        guard Self.identitiesMatch(self.identity, cached.identity) else { return self }
        // Amp's percentage-based daily quota supersedes the legacy rolling-replenishment cadence. Do not attach
        // that older exact reset to the new daily window; other providers retain the shared backfill behavior.
        let cachedPrimary: RateWindow? = if self.identity?.providerID == .amp,
                                            self.primary?.resetDescription == "resets daily"
        {
            nil
        } else {
            cached.primary
        }
        let primary = self.primary?.backfillingResetTime(from: cachedPrimary, now: now)
        let secondary = self.secondary?.backfillingResetTime(from: cached.secondary, now: now)
        let tertiary = self.tertiary?.backfillingResetTime(from: cached.tertiary, now: now)
        if primary == self.primary, secondary == self.secondary, tertiary == self.tertiary {
            return self
        }
        return self.replacing(
            primary: .value(primary),
            secondary: .value(secondary),
            tertiary: .value(tertiary))
    }

    private func orderedPerplexityFallbackWindows() -> [RateWindow] {
        let fallbackWindows = [self.tertiary, self.secondary].compactMap(\.self)
        let usableFallback = fallbackWindows.filter { $0.remainingPercent > 0 }
        let exhaustedFallback = fallbackWindows.filter { $0.remainingPercent <= 0 }
        return usableFallback + exhaustedFallback
    }

    private static func identitiesMatch(_ lhs: ProviderIdentitySnapshot?, _ rhs: ProviderIdentitySnapshot?) -> Bool {
        if lhs == nil, rhs == nil {
            return true
        }
        guard let lhs, let rhs else { return false }
        let lhsEmail = lhs.accountEmail?.trimmingCharacters(in: .whitespacesAndNewlines)
        let rhsEmail = rhs.accountEmail?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let lhsEmail, let rhsEmail, !lhsEmail.isEmpty, !rhsEmail.isEmpty {
            return lhsEmail == rhsEmail
        }
        return true
    }

    private enum Replacement<Value> {
        case unchanged
        case value(Value)

        func resolving(_ current: Value) -> Value {
            switch self {
            case .unchanged: current
            case let .value(value): value
            }
        }
    }

    private func replacing(
        primary: Replacement<RateWindow?> = .unchanged,
        secondary: Replacement<RateWindow?> = .unchanged,
        tertiary: Replacement<RateWindow?> = .unchanged,
        extraRateWindows: Replacement<[NamedRateWindow]?> = .unchanged,
        codexResetCredits: Replacement<CodexRateLimitResetCreditsSnapshot?> = .unchanged,
        identity: Replacement<ProviderIdentitySnapshot?> = .unchanged,
        dataConfidence: Replacement<UsageDataConfidence> = .unchanged) -> UsageSnapshot
    {
        UsageSnapshot(
            primary: primary.resolving(self.primary),
            secondary: secondary.resolving(self.secondary),
            tertiary: tertiary.resolving(self.tertiary),
            extraRateWindows: extraRateWindows.resolving(self.extraRateWindows),
            kiroUsage: self.kiroUsage,
            ampUsage: self.ampUsage,
            providerCost: self.providerCost,
            zaiUsage: self.zaiUsage,
            minimaxUsage: self.minimaxUsage,
            deepseekUsage: self.deepseekUsage,
            mimoUsage: self.mimoUsage,
            openRouterUsage: self.openRouterUsage,
            sakanaPayAsYouGo: self.sakanaPayAsYouGo,
            crossModelUsage: self.crossModelUsage,
            clawRouterUsage: self.clawRouterUsage,
            sub2APIUsage: self.sub2APIUsage,
            wayfinderUsage: self.wayfinderUsage,
            openAIAPIUsage: self.openAIAPIUsage,
            codexResetCredits: codexResetCredits.resolving(self.codexResetCredits),
            claudeAdminAPIUsage: self.claudeAdminAPIUsage,
            mistralUsage: self.mistralUsage,
            deepgramUsage: self.deepgramUsage,
            poeUsage: self.poeUsage,
            cursorRequests: self.cursorRequests,
            commandCodeSubscriptionEnrichmentUnavailable: self.commandCodeSubscriptionEnrichmentUnavailable,
            commandCodeHasSubscriptionPlan: self.commandCodeHasSubscriptionPlan,
            commandCodeMonthlyGrantDepleted: self.commandCodeMonthlyGrantDepleted,
            subscriptionExpiresAt: self.subscriptionExpiresAt,
            subscriptionRenewsAt: self.subscriptionRenewsAt,
            updatedAt: self.updatedAt,
            identity: identity.resolving(self.identity),
            dataConfidence: dataConfidence.resolving(self.dataConfidence))
    }
}

public struct AccountInfo: Equatable, Sendable {
    public let email: String?
    public let plan: String?

    public var hasIdentity: Bool {
        self.email?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ||
            self.plan?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    public init(email: String?, plan: String?) {
        self.email = email
        self.plan = plan
    }
}

public struct CodexCLIAccountSnapshot: Sendable {
    public let usage: UsageSnapshot?
    public let credits: CreditsSnapshot?
    public let identity: ProviderIdentitySnapshot?

    public init(
        usage: UsageSnapshot?,
        credits: CreditsSnapshot?,
        identity: ProviderIdentitySnapshot? = nil)
    {
        self.usage = usage
        self.credits = credits
        self.identity = identity
    }
}

public enum UsageError: LocalizedError, Sendable {
    case noSessions
    case noRateLimitsFound
    case decodeFailed

    public var errorDescription: String? {
        switch self {
        case .noSessions:
            "No Codex sessions found yet. Run at least one Codex prompt first."
        case .noRateLimitsFound:
            "Found sessions, but no rate limit events yet."
        case .decodeFailed:
            "Could not parse Codex session log."
        }
    }

    public static func isNoRateLimitsFoundDescription(_ text: String?) -> Bool {
        text?.trimmingCharacters(in: .whitespacesAndNewlines) == UsageError.noRateLimitsFound.errorDescription
    }
}

public enum UsageLimitsAvailability: Equatable, Sendable {
    case available
    case unavailable

    public var isUnavailable: Bool {
        self == .unavailable
    }

    public static func resolve(
        provider: UsageProvider,
        snapshot: UsageSnapshot?,
        account: AccountInfo? = nil,
        lastErrorDescription: String? = nil) -> Self
    {
        if provider == .claude {
            guard snapshot == nil else { return .available }
            return ClaudeStatusProbe.isSubscriptionQuotaUnavailableDescription(lastErrorDescription)
                ? .unavailable
                : .available
        }

        if provider == .doubao || provider == .antigravity {
            guard let snapshot,
                  snapshot.identity(for: provider) != nil
            else {
                return .available
            }
            return snapshot.hasRateLimitWindows ? .available : .unavailable
        }

        guard provider == .codex else { return .available }

        if let snapshot {
            guard snapshot.identity(for: provider) != nil else { return .available }
            return snapshot.hasRateLimitWindows ? .available : .unavailable
        }

        guard UsageError.isNoRateLimitsFoundDescription(lastErrorDescription),
              account?.hasIdentity == true
        else {
            return .available
        }
        return .unavailable
    }
}

// MARK: - Codex RPC client (local process)

private struct RPCAccountResponse: Decodable {
    let account: RPCAccountDetails?
    let requiresOpenaiAuth: Bool?
}

private enum RPCAccountDetails: Decodable {
    case apiKey
    case chatgpt(email: String, planType: String)

    enum CodingKeys: String, CodingKey {
        case type
        case email
        case planType
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type.lowercased() {
        case "apikey":
            self = .apiKey
        case "chatgpt":
            let email = try container.decodeIfPresent(String.self, forKey: .email) ?? "unknown"
            let plan = try container.decodeIfPresent(String.self, forKey: .planType) ?? "unknown"
            self = .chatgpt(email: email, planType: plan)
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type,
                in: container,
                debugDescription: "Unknown account type \(type)")
        }
    }
}

private struct RPCRateLimitsResponse: Decodable, Encodable {
    let rateLimits: RPCRateLimitSnapshot
    let rateLimitsByLimitId: [String: RPCRateLimitSnapshot]?

    enum CodingKeys: String, CodingKey {
        case rateLimits
        case rateLimitsByLimitId
        case rateLimitsByLimitIdSnake = "rate_limits_by_limit_id"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.rateLimits = try container.decode(RPCRateLimitSnapshot.self, forKey: .rateLimits)
        self.rateLimitsByLimitId = (try? container.decodeIfPresent(
            [String: RPCRateLimitSnapshot].self,
            forKey: .rateLimitsByLimitId))
            ?? (try? container.decodeIfPresent(
                [String: RPCRateLimitSnapshot].self,
                forKey: .rateLimitsByLimitIdSnake))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.rateLimits, forKey: .rateLimits)
        try container.encodeIfPresent(self.rateLimitsByLimitId, forKey: .rateLimitsByLimitId)
    }
}

private struct RPCRateLimitSnapshot: Decodable, Encodable {
    let limitId: String?
    let limitName: String?
    let primary: RPCRateLimitWindow?
    let secondary: RPCRateLimitWindow?
    let credits: RPCCreditsSnapshot?
    let individualLimit: RPCSpendControlLimitSnapshot?
    let planType: String?
    let rateLimitReachedType: String?

    enum CodingKeys: String, CodingKey {
        case limitId
        case limitIdSnake = "limit_id"
        case limitName
        case limitNameSnake = "limit_name"
        case primary
        case secondary
        case credits
        case individualLimit
        case individualLimitSnake = "individual_limit"
        case planType
        case planTypeSnake = "plan_type"
        case rateLimitReachedType
        case rateLimitReachedTypeSnake = "rate_limit_reached_type"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.limitId = (try? container.decodeIfPresent(String.self, forKey: .limitId))
            ?? (try? container.decodeIfPresent(String.self, forKey: .limitIdSnake))
        self.limitName = (try? container.decodeIfPresent(String.self, forKey: .limitName))
            ?? (try? container.decodeIfPresent(String.self, forKey: .limitNameSnake))
        self.primary = try? container.decodeIfPresent(RPCRateLimitWindow.self, forKey: .primary)
        self.secondary = try? container.decodeIfPresent(RPCRateLimitWindow.self, forKey: .secondary)
        self.credits = try? container.decodeIfPresent(RPCCreditsSnapshot.self, forKey: .credits)
        self.individualLimit = (try? container.decodeIfPresent(
            RPCSpendControlLimitSnapshot.self,
            forKey: .individualLimit))
            ?? (try? container.decodeIfPresent(RPCSpendControlLimitSnapshot.self, forKey: .individualLimitSnake))
        self.planType = (try? container.decodeIfPresent(String.self, forKey: .planType))
            ?? (try? container.decodeIfPresent(String.self, forKey: .planTypeSnake))
        self.rateLimitReachedType = (try? container.decodeIfPresent(String.self, forKey: .rateLimitReachedType))
            ?? (try? container.decodeIfPresent(String.self, forKey: .rateLimitReachedTypeSnake))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(self.limitId, forKey: .limitId)
        try container.encodeIfPresent(self.limitName, forKey: .limitName)
        try container.encodeIfPresent(self.primary, forKey: .primary)
        try container.encodeIfPresent(self.secondary, forKey: .secondary)
        try container.encodeIfPresent(self.credits, forKey: .credits)
        try container.encodeIfPresent(self.individualLimit, forKey: .individualLimit)
        try container.encodeIfPresent(self.planType, forKey: .planType)
        try container.encodeIfPresent(self.rateLimitReachedType, forKey: .rateLimitReachedType)
    }
}

private struct RPCRateLimitWindow: Decodable, Encodable {
    let usedPercent: Double
    let windowDurationMins: Int?
    let resetsAt: Int?
}

private struct RPCCreditsSnapshot: Decodable, Encodable {
    let hasCredits: Bool
    let unlimited: Bool
    let balance: String?
}

private struct RPCSpendControlLimitSnapshot: Decodable, Encodable {
    let limit: Double?
    let used: Double?
    let remainingPercent: Double?
    let resetsAt: Int?

    enum CodingKeys: String, CodingKey {
        case limit
        case used
        case remainingPercent
        case remainingPercentSnake = "remaining_percent"
        case resetsAt
        case resetsAtSnake = "resets_at"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.limit = Self.decodeFlexibleDouble(container, forKey: .limit)
        self.used = Self.decodeFlexibleDouble(container, forKey: .used)
        self.remainingPercent = Self.decodeFlexibleDouble(container, forKey: .remainingPercent)
            ?? Self.decodeFlexibleDouble(container, forKey: .remainingPercentSnake)
        self.resetsAt = Self.decodeFlexibleInt(container, forKey: .resetsAt)
            ?? Self.decodeFlexibleInt(container, forKey: .resetsAtSnake)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(self.limit, forKey: .limit)
        try container.encodeIfPresent(self.used, forKey: .used)
        try container.encodeIfPresent(self.remainingPercent, forKey: .remainingPercent)
        try container.encodeIfPresent(self.resetsAt, forKey: .resetsAt)
    }

    private static func decodeFlexibleDouble(
        _ container: KeyedDecodingContainer<CodingKeys>,
        forKey key: CodingKeys) -> Double?
    {
        if let value = try? container.decodeIfPresent(Double.self, forKey: key) {
            return value
        }
        if let value = try? container.decodeIfPresent(Int.self, forKey: key) {
            return Double(value)
        }
        if let value = try? container.decodeIfPresent(String.self, forKey: key) {
            return Double(value.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return nil
    }

    private static func decodeFlexibleInt(
        _ container: KeyedDecodingContainer<CodingKeys>,
        forKey key: CodingKeys) -> Int?
    {
        if let value = try? container.decodeIfPresent(Int.self, forKey: key) {
            return value
        }
        if let value = try? container.decodeIfPresent(Double.self, forKey: key) {
            return Int(value)
        }
        if let value = try? container.decodeIfPresent(String.self, forKey: key) {
            return Int(value.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return nil
    }
}

private struct RPCRateLimitsErrorBody: Decodable {
    let email: String?
    let planType: String?
    let rateLimit: CodexUsageResponse.RateLimitDetails?
    let credits: CodexUsageResponse.CreditDetails?

    enum CodingKeys: String, CodingKey {
        case email
        case planType = "plan_type"
        case rateLimit = "rate_limit"
        case credits
    }
}

enum RPCWireError: Error, LocalizedError {
    case startFailed(String)
    case requestFailed(String)
    case malformed(String)
    case timeout(method: String)

    var errorDescription: String? {
        switch self {
        case let .startFailed(message):
            "Codex not running. Try running a Codex command first. (\(message))"
        case let .requestFailed(message):
            "Codex connection failed: \(message)"
        case let .malformed(message):
            "Codex returned invalid data: \(message)"
        case let .timeout(method):
            "Codex RPC timed out waiting for `\(method)` reply."
        }
    }
}

/// RPC helper used on background tasks; safe because we confine it to the owning task.
private final class CodexRPCClient: @unchecked Sendable {
    private static let log = CodexBarLog.logger(LogCategories.codexRPC)
    private let process = Process()
    private let stdinPipe = Pipe()
    private let stdoutPipe = Pipe()
    private let stderrPipe = Pipe()
    private let stdoutLineStream: AsyncStream<Data>
    private let stdoutLineContinuation: AsyncStream<Data>.Continuation
    private var nextID = 1
    private let initializeTimeoutSeconds: TimeInterval
    private let requestTimeoutSeconds: TimeInterval

    private final class LineBuffer: @unchecked Sendable {
        private let lock = NSLock()
        private var buffer = Data()

        func appendAndDrainLines(_ data: Data) -> [Data] {
            self.lock.lock()
            defer { self.lock.unlock() }

            self.buffer.append(data)
            var out: [Data] = []
            while let newline = self.buffer.firstIndex(of: 0x0A) {
                let lineData = Data(self.buffer[..<newline])
                self.buffer.removeSubrange(...newline)
                if !lineData.isEmpty {
                    out.append(lineData)
                }
            }
            return out
        }
    }

    private static func debugWriteStderr(_ message: String) {
        #if !os(Linux)
        fputs(message, stderr)
        #endif
    }

    init(
        executable: String = "codex",
        arguments: [String] = ["-s", "read-only", "-a", "untrusted", "app-server"],
        environment: [String: String] = ProcessInfo.processInfo.environment,
        initializeTimeoutSeconds: TimeInterval = 8.0,
        requestTimeoutSeconds: TimeInterval = 3.0,
        resolveExecutable: CodexExecutableResolver = defaultCodexExecutableResolver) throws
    {
        self.initializeTimeoutSeconds = initializeTimeoutSeconds
        self.requestTimeoutSeconds = requestTimeoutSeconds
        var stdoutContinuation: AsyncStream<Data>.Continuation!
        self.stdoutLineStream = AsyncStream<Data> { continuation in
            stdoutContinuation = continuation
        }
        self.stdoutLineContinuation = stdoutContinuation

        let resolution = resolveExecutable(environment, executable)

        guard let resolution else {
            Self.log.warning("Codex RPC binary not found", metadata: ["binary": executable])
            throw CodexStatusProbeError.codexNotInstalled
        }
        let resolvedExec = resolution.executable
        var env = environment
        let loginPATH = resolution.loginPATH ?? LoginShellPathCache.shared.current
        env["PATH"] = PathBuilder.effectivePATH(
            purposes: [.rpc, .nodeTooling],
            env: env,
            loginPATH: loginPATH)

        self.process.environment = env
        self.process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        self.process.arguments = [resolvedExec] + arguments
        self.process.standardInput = self.stdinPipe
        self.process.standardOutput = self.stdoutPipe
        self.process.standardError = self.stderrPipe

        if let message = CodexCLILaunchGate.shared.backgroundSkipMessage(binary: resolvedExec) {
            Self.log.warning("Codex RPC launch skipped after recent launch failure", metadata: ["binary": resolvedExec])
            throw RPCWireError.startFailed(message)
        }

        do {
            try self.process.run()
            Self.log.debug("Codex RPC started", metadata: ["binary": resolvedExec])
        } catch {
            let message = error.localizedDescription
            let throttled = CodexCLILaunchGate.shared.recordLaunchFailure(binary: resolvedExec, message: message)
            Self.log.warning("Codex RPC failed to start", metadata: ["error": message])
            throw RPCWireError.startFailed(throttled ?? message)
        }

        let stdoutHandle = self.stdoutPipe.fileHandleForReading
        let stdoutLineContinuation = self.stdoutLineContinuation
        let stdoutBuffer = LineBuffer()
        stdoutHandle.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                stdoutLineContinuation.finish()
                return
            }

            let lines = stdoutBuffer.appendAndDrainLines(data)

            for lineData in lines {
                stdoutLineContinuation.yield(lineData)
            }
        }

        let stderrHandle = self.stderrPipe.fileHandleForReading
        stderrHandle.readabilityHandler = { handle in
            let data = handle.availableData
            // When the child closes stderr, availableData returns empty and will keep re-firing; clear the handler
            // to avoid a busy read loop on the file-descriptor monitoring queue.
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            guard let text = String(data: data, encoding: .utf8), !text.isEmpty else { return }
            for line in text.split(whereSeparator: \.isNewline) {
                Self.debugWriteStderr("[codex stderr] \(line)\n")
            }
        }
    }

    func initialize(clientName: String, clientVersion: String) async throws {
        _ = try await self.request(
            method: "initialize",
            params: ["clientInfo": ["name": clientName, "version": clientVersion]],
            timeout: self.initializeTimeoutSeconds)
        try self.sendNotification(method: "initialized")
    }

    func fetchAccount() async throws -> RPCAccountResponse {
        let message = try await self.request(method: "account/read")
        return try self.decodeResult(from: message)
    }

    func fetchRateLimits() async throws -> RPCRateLimitsResponse {
        let message = try await self.request(method: "account/rateLimits/read")
        return try self.decodeResult(from: message)
    }

    func shutdown() {
        if self.process.isRunning {
            Self.log.debug("Codex RPC stopping")
            self.process.terminate()
        }
    }

    // MARK: - JSON-RPC helpers

    private struct SendableJSONMessage: @unchecked Sendable {
        let value: [String: Any]
    }

    private func request(
        method: String,
        params: [String: Any]? = nil,
        timeout: TimeInterval? = nil) async throws -> [String: Any]
    {
        let id = self.nextID
        self.nextID += 1
        try self.sendRequest(id: id, method: method, params: params)

        let resolvedTimeout = timeout ?? self.requestTimeoutSeconds
        let wrapped = try await self.withTimeout(seconds: resolvedTimeout, method: method) {
            while true {
                let message = try await self.readNextMessage()

                if message["id"] == nil, let methodName = message["method"] as? String {
                    Self.debugWriteStderr("[codex notify] \(methodName)\n")
                    continue
                }

                guard let messageID = self.jsonID(message["id"]), messageID == id else { continue }

                if let error = message["error"] as? [String: Any], let messageText = error["message"] as? String {
                    throw RPCWireError.requestFailed(messageText)
                }

                return SendableJSONMessage(value: message)
            }
        }
        return wrapped.value
    }

    private func withTimeout<T: Sendable>(
        seconds: TimeInterval,
        method: String,
        body: @escaping @Sendable () async throws -> T) async throws -> T
    {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await body()
            }
            group.addTask { [weak self] in
                try await Task.sleep(for: .seconds(seconds))
                self?.terminateProcessForTimeout(method: method)
                throw RPCWireError.timeout(method: method)
            }
            do {
                guard let result = try await group.next() else {
                    throw RPCWireError.timeout(method: method)
                }
                group.cancelAll()
                return result
            } catch {
                group.cancelAll()
                throw error
            }
        }
    }

    private func terminateProcessForTimeout(method: String) {
        if self.process.isRunning {
            Self.log.warning("Codex RPC timed out on `\(method)`; terminating process")
            self.process.terminate()
        }
    }

    private func sendNotification(method: String, params: [String: Any]? = nil) throws {
        let paramsValue: Any = params ?? [:]
        try self.sendPayload(["method": method, "params": paramsValue])
    }

    private func sendRequest(id: Int, method: String, params: [String: Any]?) throws {
        let paramsValue: Any = params ?? [:]
        let payload: [String: Any] = ["id": id, "method": method, "params": paramsValue]
        try self.sendPayload(payload)
    }

    private func sendPayload(_ payload: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: payload)
        self.stdinPipe.fileHandleForWriting.write(data)
        self.stdinPipe.fileHandleForWriting.write(Data([0x0A]))
    }

    private func readNextMessage() async throws -> [String: Any] {
        for await lineData in self.stdoutLineStream {
            if lineData.isEmpty {
                continue
            }
            if let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] {
                return json
            }
        }
        throw RPCWireError.malformed("codex app-server closed stdout")
    }

    private func decodeResult<T: Decodable>(from message: [String: Any]) throws -> T {
        guard let result = message["result"] else {
            throw RPCWireError.malformed("missing result field")
        }
        let data = try JSONSerialization.data(withJSONObject: result)
        let decoder = JSONDecoder()
        return try decoder.decode(T.self, from: data)
    }

    private func jsonID(_ value: Any?) -> Int? {
        switch value {
        case let int as Int:
            int
        case let number as NSNumber:
            number.intValue
        default:
            nil
        }
    }
}

// MARK: - Public fetcher used by the app

public struct UsageFetcher: Sendable {
    private let environment: [String: String]
    private let initializeTimeoutSeconds: TimeInterval
    private let requestTimeoutSeconds: TimeInterval
    private let codexExecutableResolver: CodexExecutableResolver
    private let codexArguments: [String]

    public init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.environment = environment
        self.initializeTimeoutSeconds = 8.0
        self.requestTimeoutSeconds = 3.0
        self.codexExecutableResolver = defaultCodexExecutableResolver
        self.codexArguments = ["-s", "read-only", "-a", "untrusted", "app-server"]
    }

    init(
        environment: [String: String],
        initializeTimeoutSeconds: TimeInterval,
        requestTimeoutSeconds: TimeInterval,
        codexArguments: [String] = ["-s", "read-only", "-a", "untrusted", "app-server"],
        codexExecutableResolver: @escaping CodexExecutableResolver = defaultCodexExecutableResolver)
    {
        self.environment = environment
        self.initializeTimeoutSeconds = initializeTimeoutSeconds
        self.requestTimeoutSeconds = requestTimeoutSeconds
        self.codexExecutableResolver = codexExecutableResolver
        self.codexArguments = codexArguments
    }

    public func loadLatestUsage(keepCLISessionsAlive: Bool = false) async throws -> UsageSnapshot {
        _ = keepCLISessionsAlive
        guard let usage = try await self.loadLatestCLIAccountSnapshot().usage else {
            throw UsageError.noRateLimitsFound
        }
        return usage
    }

    public func loadLatestCLIAccountSnapshot() async throws -> CodexCLIAccountSnapshot {
        let rpc = try CodexRPCClient(
            arguments: self.codexArguments,
            environment: self.environment,
            initializeTimeoutSeconds: self.initializeTimeoutSeconds,
            requestTimeoutSeconds: self.requestTimeoutSeconds,
            resolveExecutable: self.codexExecutableResolver)
        defer { rpc.shutdown() }
        do {
            try await rpc.initialize(clientName: "codexbar", clientVersion: "0.5.4")
            // The app-server answers on a single stdout stream, so keep requests
            // serialized to avoid starving one reader when multiple awaiters race
            // for the same pipe.
            let limitsResponse = try await rpc.fetchRateLimits()
            let limits = limitsResponse.rateLimits
            let account = try? await rpc.fetchAccount()
            let rateLimitsPlan = Self.normalizedCodexAccountField(limits.planType)
            let identity = ProviderIdentitySnapshot(
                providerID: .codex,
                accountEmail: account?.account.flatMap { details in
                    if case let .chatgpt(email, _) = details {
                        email
                    } else {
                        nil
                    }
                },
                accountOrganization: nil,
                loginMethod: account?.account.flatMap { details in
                    if case let .chatgpt(_, plan) = details {
                        plan
                    } else {
                        nil
                    }
                } ?? rateLimitsPlan)
            let credits = Self.makeCredits(from: limits, rateLimitsByLimitId: limitsResponse.rateLimitsByLimitId)
            let shouldReturnUnavailableUsage = credits == nil || rateLimitsPlan != nil
            let usage = CodexReconciledState.fromCLI(
                primary: Self.makeWindow(from: limits.primary),
                secondary: Self.makeWindow(from: limits.secondary),
                identity: identity)?
                .toUsageSnapshot()
                ?? (shouldReturnUnavailableUsage ? Self.emptyCodexUsageSnapshotIfIdentified(identity: identity) : nil)
            guard usage != nil || credits != nil else {
                throw UsageError.noRateLimitsFound
            }
            return CodexCLIAccountSnapshot(
                usage: usage,
                credits: credits,
                identity: identity)
        } catch {
            let usage = Self.recoverUsageFromRPCError(error)
            let credits = Self.recoverCreditsFromRPCError(error)
            if usage != nil || credits != nil {
                return CodexCLIAccountSnapshot(
                    usage: usage,
                    credits: credits,
                    identity: usage?.identity)
            }
            throw error
        }
    }

    public func loadLatestCredits(keepCLISessionsAlive: Bool = false) async throws -> CreditsSnapshot {
        _ = keepCLISessionsAlive
        guard let credits = try await self.loadLatestCLIAccountSnapshot().credits else {
            throw UsageError.noRateLimitsFound
        }
        return credits
    }

    public func debugRawRateLimits() async -> String {
        do {
            let rpc = try CodexRPCClient(
                arguments: self.codexArguments,
                environment: self.environment,
                initializeTimeoutSeconds: self.initializeTimeoutSeconds,
                requestTimeoutSeconds: self.requestTimeoutSeconds,
                resolveExecutable: self.codexExecutableResolver)
            defer { rpc.shutdown() }
            try await rpc.initialize(clientName: "codexbar", clientVersion: "0.5.4")
            let limits = try await rpc.fetchRateLimits()
            let data = try JSONEncoder().encode(limits)
            return String(data: data, encoding: .utf8) ?? "<unprintable>"
        } catch {
            return "Codex RPC probe failed: \(error)"
        }
    }

    public func loadAccountInfo() -> AccountInfo {
        let account = self.loadAuthBackedCodexAccount()
        return AccountInfo(email: account.email, plan: account.plan)
    }

    public func loadAuthBackedCodexAccount() -> CodexAuthBackedAccount {
        guard let credentials = try? CodexOAuthCredentialsStore.load(env: self.environment) else {
            return CodexAuthBackedAccount(identity: .unresolved, email: nil, plan: nil)
        }

        let payload = credentials.idToken.flatMap(Self.parseJWT)
        let authDict = payload?["https://api.openai.com/auth"] as? [String: Any]
        let profileDict = payload?["https://api.openai.com/profile"] as? [String: Any]

        let email = Self.normalizedCodexAccountField(
            (payload?["email"] as? String) ?? (profileDict?["email"] as? String))
        let plan = Self.normalizedCodexAccountField(
            (authDict?["chatgpt_plan_type"] as? String) ?? (payload?["chatgpt_plan_type"] as? String))
        let accountId = Self.normalizedCodexAccountField(
            credentials.accountId
                ?? (authDict?["chatgpt_account_id"] as? String)
                ?? (payload?["chatgpt_account_id"] as? String))
        let identity = CodexIdentityResolver.resolve(accountId: accountId, email: email)

        return CodexAuthBackedAccount(identity: identity, email: email, plan: plan)
    }

    // MARK: - Helpers

    private static func makeWindow(from rpc: RPCRateLimitWindow?) -> RateWindow? {
        guard let rpc else { return nil }
        let resetsAtDate = rpc.resetsAt.map { Date(timeIntervalSince1970: TimeInterval($0)) }
        let resetDescription = resetsAtDate.map { UsageFormatter.resetDescription(from: $0) }
        return RateWindow(
            usedPercent: rpc.usedPercent,
            windowMinutes: rpc.windowDurationMins,
            resetsAt: resetsAtDate,
            resetDescription: resetDescription)
    }

    private static func makeWindow(from response: CodexUsageResponse.WindowSnapshot?) -> RateWindow? {
        guard let response else { return nil }
        let resetsAtDate = Date(timeIntervalSince1970: TimeInterval(response.resetAt))
        return RateWindow(
            usedPercent: Double(response.usedPercent),
            windowMinutes: response.limitWindowSeconds / 60,
            resetsAt: resetsAtDate,
            resetDescription: UsageFormatter.resetDescription(from: resetsAtDate))
    }

    private static func makeTTYWindow(
        percentLeft: Int?,
        windowMinutes: Int,
        resetsAt: Date?,
        resetDescription: String?) -> RateWindow?
    {
        guard let percentLeft else { return nil }
        return RateWindow(
            usedPercent: max(0, 100 - Double(percentLeft)),
            windowMinutes: windowMinutes,
            resetsAt: resetsAt,
            resetDescription: resetDescription)
    }

    private static func parseCredits(_ balance: String?) -> Double {
        guard let balance, let val = Double(balance) else { return 0 }
        return val
    }

    private static func makeCredits(
        from limits: RPCRateLimitSnapshot,
        rateLimitsByLimitId: [String: RPCRateLimitSnapshot]? = nil) -> CreditsSnapshot?
    {
        let updatedAt = Date()
        let balance = limits.credits.map { self.parseCredits($0.balance) }
        let creditLimit = self.codexCreditLimit(
            from: limits,
            rateLimitsByLimitId: rateLimitsByLimitId,
            updatedAt: updatedAt)
        guard balance != nil || creditLimit != nil else { return nil }
        return CreditsSnapshot(
            remaining: balance ?? 0,
            events: [],
            updatedAt: updatedAt,
            codexCreditLimit: creditLimit)
    }

    private static func codexCreditLimit(
        from limits: RPCRateLimitSnapshot,
        rateLimitsByLimitId: [String: RPCRateLimitSnapshot]?,
        updatedAt: Date) -> CodexCreditLimitSnapshot?
    {
        let candidates = [limits] + (rateLimitsByLimitId?.values.sorted {
            ($0.limitName ?? $0.limitId ?? "") < ($1.limitName ?? $1.limitId ?? "")
        } ?? [])
        for candidate in candidates {
            if let limit = self.codexCreditLimit(from: candidate, updatedAt: updatedAt) {
                return limit
            }
        }
        return nil
    }

    private static func codexCreditLimit(
        from snapshot: RPCRateLimitSnapshot,
        updatedAt: Date) -> CodexCreditLimitSnapshot?
    {
        guard let individualLimit = snapshot.individualLimit else { return nil }
        guard let limit = individualLimit.limit, limit > 0 else { return nil }
        let used: Double = if let used = individualLimit.used {
            used
        } else if let remainingPercent = individualLimit.remainingPercent {
            limit * max(0, min(100, 100 - remainingPercent)) / 100
        } else {
            0
        }
        let remainingPercent = individualLimit.remainingPercent ?? max(0, min(100, 100 - (used / limit * 100)))
        let resetsAt = individualLimit.resetsAt.flatMap { value -> Date? in
            guard value > 0 else { return nil }
            return Date(timeIntervalSince1970: TimeInterval(value))
        }
        return CodexCreditLimitSnapshot(
            title: self.codexCreditLimitTitle(from: snapshot.limitName),
            used: used,
            limit: limit,
            remainingPercent: remainingPercent,
            resetsAt: resetsAt,
            updatedAt: updatedAt)
    }

    private static func codexCreditLimitTitle(from limitName: String?) -> String {
        let trimmed = limitName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty {
            return "Monthly credit limit"
        }
        return trimmed
    }

    private static func emptyCodexUsageSnapshotIfIdentified(identity: ProviderIdentitySnapshot) -> UsageSnapshot? {
        guard identity.accountEmail != nil || identity.loginMethod != nil else { return nil }
        return UsageSnapshot(
            primary: nil,
            secondary: nil,
            tertiary: nil,
            updatedAt: Date(),
            identity: identity)
    }

    private static func recoverUsageFromRPCError(_ error: Error) -> UsageSnapshot? {
        guard let body = self.decodeRateLimitsErrorBody(from: error) else { return nil }
        let identity = ProviderIdentitySnapshot(
            providerID: .codex,
            accountEmail: self.normalizedCodexAccountField(body.email),
            accountOrganization: nil,
            loginMethod: self.normalizedCodexAccountField(body.planType))
        guard let state = CodexReconciledState.fromCLI(
            primary: self.makeWindow(from: body.rateLimit?.primaryWindow),
            secondary: self.makeWindow(from: body.rateLimit?.secondaryWindow),
            identity: identity)
        else {
            return nil
        }
        if body.rateLimit?.hasWindowDecodeFailure == true,
           state.session == nil
        {
            return nil
        }
        return state.toUsageSnapshot()
    }

    private static func recoverCreditsFromRPCError(_ error: Error) -> CreditsSnapshot? {
        guard let credits = self.decodeRateLimitsErrorBody(from: error)?.credits else { return nil }
        guard let remaining = credits.balance else { return nil }
        return CreditsSnapshot(remaining: remaining, events: [], updatedAt: Date())
    }

    private static func decodeRateLimitsErrorBody(from error: Error) -> RPCRateLimitsErrorBody? {
        guard case let RPCWireError.requestFailed(message) = error else { return nil }
        guard let json = self.extractJSONObject(after: "body=", in: message) else { return nil }
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(RPCRateLimitsErrorBody.self, from: data)
    }

    private static func extractJSONObject(after marker: String, in text: String) -> String? {
        guard let markerRange = text.range(of: marker) else { return nil }
        let suffix = text[markerRange.upperBound...]
        guard let start = suffix.firstIndex(of: "{") else { return nil }

        var depth = 0
        var inString = false
        var isEscaped = false

        for index in suffix[start...].indices {
            let character = suffix[index]

            if inString {
                if isEscaped {
                    isEscaped = false
                } else if character == "\\" {
                    isEscaped = true
                } else if character == "\"" {
                    inString = false
                }
                continue
            }

            switch character {
            case "\"":
                inString = true
            case "{":
                depth += 1
            case "}":
                depth -= 1
                if depth == 0 {
                    return String(suffix[start...index])
                }
            default:
                break
            }
        }

        return nil
    }

    private static func normalizedCodexAccountField(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }

    public static func parseJWT(_ token: String) -> [String: Any]? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        let payloadPart = parts[1]

        var padded = String(payloadPart)
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while padded.count % 4 != 0 {
            padded.append("=")
        }
        guard let data = Data(base64Encoded: padded) else { return nil }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return json
    }
}

#if DEBUG
extension UsageFetcher {
    static func _mapCodexRPCLimitsForTesting(
        primary: (usedPercent: Double, windowMinutes: Int, resetsAt: Int?)?,
        secondary: (usedPercent: Double, windowMinutes: Int, resetsAt: Int?)?,
        planType: String? = nil) throws -> UsageSnapshot
    {
        let identity = ProviderIdentitySnapshot(
            providerID: .codex,
            accountEmail: nil,
            accountOrganization: nil,
            loginMethod: self.normalizedCodexAccountField(planType))
        guard let state = CodexReconciledState.fromCLI(
            primary: primary.map(self.makeTestingWindow),
            secondary: secondary.map(self.makeTestingWindow),
            identity: identity)
        else {
            if let usage = self.emptyCodexUsageSnapshotIfIdentified(identity: identity) {
                return usage
            }
            throw UsageError.noRateLimitsFound
        }
        return state.toUsageSnapshot()
    }

    static func _mapCodexStatusForTesting(_ status: CodexStatusSnapshot) throws -> UsageSnapshot {
        guard let state = CodexReconciledState.fromCLI(
            primary: self.makeTTYWindow(
                percentLeft: status.fiveHourPercentLeft,
                windowMinutes: 300,
                resetsAt: status.fiveHourResetsAt,
                resetDescription: status.fiveHourResetDescription),
            secondary: self.makeTTYWindow(
                percentLeft: status.weeklyPercentLeft,
                windowMinutes: 10080,
                resetsAt: status.weeklyResetsAt,
                resetDescription: status.weeklyResetDescription),
            identity: nil)
        else {
            throw UsageError.noRateLimitsFound
        }
        return state.toUsageSnapshot()
    }

    public static func _recoverCodexRPCUsageFromErrorForTesting(_ message: String) -> UsageSnapshot? {
        self.recoverUsageFromRPCError(RPCWireError.requestFailed(message))
    }

    public static func _recoverCodexRPCCreditsFromErrorForTesting(_ message: String) -> CreditsSnapshot? {
        self.recoverCreditsFromRPCError(RPCWireError.requestFailed(message))
    }

    private static func makeTestingWindow(
        _ value: (usedPercent: Double, windowMinutes: Int, resetsAt: Int?))
        -> RateWindow
    {
        let resetsAt = value.resetsAt.map { Date(timeIntervalSince1970: TimeInterval($0)) }
        return RateWindow(
            usedPercent: value.usedPercent,
            windowMinutes: value.windowMinutes,
            resetsAt: resetsAt,
            resetDescription: resetsAt.map { UsageFormatter.resetDescription(from: $0) })
    }
}
#endif
