import CodexBarCore
import Foundation

struct CodexUIErrorMapper {
    private static var codexCLINotSignedInMessage: String {
        L("Codex CLI is not signed in. Run `codex login --device-auth`, then refresh.")
    }

    static func userFacingMessage(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let lower = trimmed.lowercased()
        if self.isAlreadyUserFacing(lower: lower) {
            return trimmed
        }

        if let cachedMessage = self.cachedMessage(raw: trimmed, lower: lower) {
            return cachedMessage
        }

        if self.looksCodexCLIMissing(lower: lower) {
            return L("Codex CLI missing. Install via `npm i -g @openai/codex` (or bun install) and restart.")
        }

        if self.looksCodexCLILoginRequired(lower: lower) {
            return self.codexCLINotSignedInMessage
        }

        if self.looksExpired(lower: lower) {
            return L("Codex session expired. Sign in again.")
        }

        if lower.contains("frame load interrupted") {
            return L("OpenAI web refresh was interrupted. Refresh OpenAI cookies and try again.")
        }

        if self.looksOpenAIWebTimeout(lower: lower) {
            return L("OpenAI web refresh timed out. Refresh OpenAI cookies and try again.")
        }

        if self.looksOpenAIWebNetworkError(lower: lower) {
            return L(
                "OpenAI web refresh hit a network error. " +
                    "Check your connection, then refresh OpenAI cookies and try again.")
        }

        if self.looksInternalTransport(lower: lower) {
            return L("Codex usage is temporarily unavailable. Try refreshing.")
        }

        return trimmed
    }

    private static func cachedMessage(raw: String, lower: String) -> String? {
        let cachedMarker = " Cached values from "
        guard let suffixRange = raw.range(of: cachedMarker) else { return nil }

        let rawPrefix = String(raw[..<suffixRange.lowerBound])
        let stamp = self.cachedStamp(raw: raw, suffixRange: suffixRange, marker: cachedMarker)
        if lower.hasPrefix("last codex credits refresh failed:"),
           let base = self.userFacingMessage(self.failureMessage(
               rawPrefix: rawPrefix,
               prefix: "Last Codex credits refresh failed:"))
        {
            return "\(base) \(L("Cached values from %@.", stamp))"
        }

        if lower.hasPrefix("last openai dashboard refresh failed:"),
           let base = self.userFacingMessage(self.failureMessage(
               rawPrefix: rawPrefix,
               prefix: "Last OpenAI dashboard refresh failed:"))
        {
            return "\(base) \(L("Cached values from %@.", stamp))"
        }

        return nil
    }

    private static func failureMessage(rawPrefix: String, prefix: String) -> String {
        let droppedPrefix = if rawPrefix.lowercased().hasPrefix(prefix.lowercased()) {
            String(rawPrefix.dropFirst(prefix.count))
        } else {
            rawPrefix
        }
        var message = droppedPrefix.trimmingCharacters(in: .whitespacesAndNewlines)
        if message.hasSuffix(".") {
            message.removeLast()
        }
        return message
    }

    private static func cachedStamp(raw: String, suffixRange: Range<String.Index>, marker: String) -> String {
        let start = raw.index(suffixRange.lowerBound, offsetBy: marker.count)
        var stamp = String(raw[start...]).trimmingCharacters(in: .whitespacesAndNewlines)
        if stamp.hasSuffix(".") {
            stamp.removeLast()
        }
        return stamp
    }

    private static func isAlreadyUserFacing(lower: String) -> Bool {
        lower.contains("openai cookies are for")
            || lower.contains("sign in to chatgpt.com")
            || lower.contains("requires a signed-in chatgpt.com session")
            || lower.contains("managed codex account data is unavailable")
            || lower.contains("selected managed codex account is unavailable")
            || lower.contains("codex credits are still loading")
            || lower.contains("codex account changed; importing browser cookies")
            || lower.contains("codex cli is not signed in.")
            || lower.contains("chatgpt rate limits are unavailable.")
            || lower.contains("codex session expired. sign in again.")
            || lower.contains("openai web refresh timed out. refresh openai cookies and try again.")
            || lower.contains(
                "openai web refresh hit a network error. "
                    + "check your connection, then refresh openai cookies and try again.")
            || lower.contains("codex usage is temporarily unavailable. try refreshing.")
    }

    private static func looksCodexCLIMissing(lower: String) -> Bool {
        lower.contains("codex cli missing")
            || lower.contains("codex cli not found")
            || lower.contains("missing cli codex")
            || lower.contains("missing cli 'codex'")
            || lower.contains("missing cli \"codex\"")
            || (lower.contains("binary not found") && lower.contains("codex"))
    }

    private static func looksCodexCLILoginRequired(lower: String) -> Bool {
        lower.contains("codex account authentication required")
            || lower.contains("account authentication required to read rate limits")
            || lower.contains("requiresopenaiauth")
    }

    private static func looksExpired(lower: String) -> Bool {
        lower.contains("token_expired")
            || lower.contains("authentication token is expired")
            || lower.contains("oauth token has expired")
            || lower.contains("provided authentication token is expired")
            || lower.contains("please try signing in again")
            || lower.contains("please sign in again")
            || (lower.contains("401") && lower.contains("unauthorized"))
    }

    private static func looksInternalTransport(lower: String) -> Bool {
        lower.contains("codex connection failed")
            || lower.contains("failed to fetch codex rate limits")
            || lower.contains("/backend-api/")
            || lower.contains("content-type=")
            || lower.contains("body={")
            || lower.contains("body=")
            || lower.contains("get https://")
            || lower.contains("get http://")
            || lower.contains("returned invalid data")
    }

    private static func looksOpenAIWebTimeout(lower: String) -> Bool {
        lower.contains("nsurlerrordomain")
            && (lower.contains("timed out") || lower.contains("error -1001"))
    }

    private static func looksOpenAIWebNetworkError(lower: String) -> Bool {
        lower.contains("nsurlerrordomain")
    }
}

struct CodexConsumerProjection {
    enum Surface {
        case liveCard
        case overrideCard
        case widget
        case menuBar
    }

    enum RateLane: String {
        case session
        case weekly
        case monthly
    }

    static let sessionWindowMinutes = 5 * 60
    static let weeklyWindowMinutes = 7 * 24 * 60
    static let monthlyWindowMinutes = 30 * 24 * 60

    enum SupplementalMetric: String {
        case codeReview
    }

    struct PlanUtilizationLane {
        let role: PlanUtilizationSeriesName
        let window: RateWindow
    }

    enum DashboardVisibility {
        case hidden
        case displayOnly
        case attached
    }

    struct CreditsProjection {
        let snapshot: CreditsSnapshot?
        let userFacingError: String?

        var remaining: Double? {
            self.snapshot?.codexCreditLimit?.remaining ?? self.snapshot?.remaining
        }
    }

    struct UserFacingErrors {
        let usage: String?
        let credits: String?
        let dashboard: String?
    }

    struct Context {
        let snapshot: UsageSnapshot?
        let rawUsageError: String?
        let liveCredits: CreditsSnapshot?
        let rawCreditsError: String?
        let liveDashboard: OpenAIDashboardSnapshot?
        let rawDashboardError: String?
        let dashboardAttachmentAuthorized: Bool
        let dashboardRequiresLogin: Bool
        let now: Date
        let showOptionalCreditsAndExtraUsage: Bool

        init(
            snapshot: UsageSnapshot?,
            rawUsageError: String?,
            liveCredits: CreditsSnapshot?,
            rawCreditsError: String?,
            liveDashboard: OpenAIDashboardSnapshot?,
            rawDashboardError: String?,
            dashboardAttachmentAuthorized: Bool,
            dashboardRequiresLogin: Bool,
            now: Date,
            showOptionalCreditsAndExtraUsage: Bool = true)
        {
            self.snapshot = snapshot
            self.rawUsageError = rawUsageError
            self.liveCredits = liveCredits
            self.rawCreditsError = rawCreditsError
            self.liveDashboard = liveDashboard
            self.rawDashboardError = rawDashboardError
            self.dashboardAttachmentAuthorized = dashboardAttachmentAuthorized
            self.dashboardRequiresLogin = dashboardRequiresLogin
            self.now = now
            self.showOptionalCreditsAndExtraUsage = showOptionalCreditsAndExtraUsage
        }
    }

    enum MenuBarFallback {
        case none
        case creditsBalance
    }

    let visibleRateLanes: [RateLane]
    let supplementalMetrics: [SupplementalMetric]
    let planUtilizationLanes: [PlanUtilizationLane]
    let dashboardVisibility: DashboardVisibility
    let credits: CreditsProjection?
    let menuBarFallback: MenuBarFallback
    let userFacingErrors: UserFacingErrors
    let canShowBuyCredits: Bool
    let hasUsageBreakdown: Bool
    let hasCreditsHistory: Bool
    let extraUsageCost: ProviderCostSnapshot?

    private let rateWindowsByLane: [RateLane: RateWindow]
    private let codeReviewRemainingPercent: Double?
    private let codeReviewLimit: RateWindow?
    private let evaluationTime: Date

    static func make(surface: Surface, context: Context) -> CodexConsumerProjection {
        let allowsLiveAdjuncts = surface != .overrideCard
        let dashboardVisibility = self.dashboardVisibility(surface: surface, context: context)
        let dashboard = allowsLiveAdjuncts && dashboardVisibility != .hidden ? context.liveDashboard : nil

        let rateWindowsByLane = self.rateWindowsByLane(
            snapshot: context.snapshot,
            monthlyCreditLimit: self.monthlyCreditLimit(surface: surface, context: context))
        let visibleRateLanes = self.visibleRateLanes(from: rateWindowsByLane, snapshot: context.snapshot)
        let planUtilizationLanes = self.planUtilizationLanes(from: rateWindowsByLane)

        let extraUsageCost = context.showOptionalCreditsAndExtraUsage
            ? CodexExtraUsageCost.resolving(
                liveCredits: context.liveCredits,
                attached: context.snapshot?.providerCost)
            : nil
        let creditsProjection: CreditsProjection? = if allowsLiveAdjuncts,
                                                       context.liveCredits != nil || context.rawCreditsError != nil
        {
            CreditsProjection(
                snapshot: CodexExtraUsageCost.creditsForDisplay(
                    context.liveCredits, attached: context.snapshot?.providerCost),
                userFacingError: CodexUIErrorMapper.userFacingMessage(context.rawCreditsError))
        } else {
            nil
        }

        let userFacingErrors = UserFacingErrors(
            usage: CodexUIErrorMapper.userFacingMessage(context.rawUsageError),
            credits: allowsLiveAdjuncts ? CodexUIErrorMapper.userFacingMessage(context.rawCreditsError) : nil,
            dashboard: allowsLiveAdjuncts ? CodexUIErrorMapper.userFacingMessage(context.rawDashboardError) : nil)

        let supplementalMetrics: [SupplementalMetric] = if surface == .liveCard,
                                                           dashboardVisibility == .attached,
                                                           dashboard?.codeReviewRemainingPercent != nil
        {
            [.codeReview]
        } else {
            []
        }

        let displayableUsageBreakdown = OpenAIDashboardDailyBreakdown.removingSkillUsageServices(
            from: dashboard?.usageBreakdown ?? [])
        let canShowBuyCredits = surface == .liveCard
        let hasUsageBreakdown = surface == .liveCard
            && dashboardVisibility == .attached
            && !displayableUsageBreakdown.isEmpty
        let hasCreditsHistory = surface == .liveCard
            && dashboardVisibility == .attached
            && !(dashboard?.dailyBreakdown ?? []).isEmpty

        return CodexConsumerProjection(
            visibleRateLanes: visibleRateLanes,
            supplementalMetrics: supplementalMetrics,
            planUtilizationLanes: planUtilizationLanes,
            dashboardVisibility: dashboardVisibility,
            credits: creditsProjection,
            menuBarFallback: self.menuBarFallback(
                creditsRemaining: creditsProjection?.remaining,
                rateWindowsByLane: rateWindowsByLane,
                evaluationTime: context.now),
            userFacingErrors: userFacingErrors,
            canShowBuyCredits: canShowBuyCredits,
            hasUsageBreakdown: hasUsageBreakdown,
            hasCreditsHistory: hasCreditsHistory,
            extraUsageCost: extraUsageCost,
            rateWindowsByLane: rateWindowsByLane,
            codeReviewRemainingPercent: dashboardVisibility == .attached ? dashboard?.codeReviewRemainingPercent : nil,
            codeReviewLimit: dashboardVisibility == .attached ? dashboard?.codeReviewLimit : nil,
            evaluationTime: context.now)
    }

    func displayedRateLanes(showOptionalCreditsAndExtraUsage: Bool) -> [RateLane] {
        self.visibleRateLanes.filter { lane in
            guard lane == .monthly, !showOptionalCreditsAndExtraUsage else { return true }
            return self.rateWindow(for: lane)?.windowMinutes != nil
        }
    }

    func rateWindow(for lane: RateLane) -> RateWindow? {
        guard let window = self.rateWindowsByLane[lane] else { return nil }
        switch lane {
        case .session:
            return Self.sessionDisplayWindow(
                session: window,
                weekly: self.rateWindowsByLane[.weekly],
                evaluationTime: self.evaluationTime)
        case .weekly, .monthly:
            return window
        }
    }

    func sourceRateWindow(for lane: RateLane) -> RateWindow? {
        self.rateWindowsByLane[lane]
    }

    static func sourceRateWindow(for lane: RateLane, snapshot: UsageSnapshot?) -> RateWindow? {
        self.rateWindowsByLane(snapshot: snapshot)[lane]
    }

    func menuBarSelectableRateWindow(for lane: RateLane) -> RateWindow? {
        guard let window = self.rateWindow(for: lane) else { return nil }
        guard window.remainingPercent <= 0,
              let resetAt = window.resetsAt,
              resetAt <= self.evaluationTime
        else {
            return window
        }
        return nil
    }

    /// Automatic keeps the standard session window unless a longer window (e.g. a 30-day
    /// primary) would hide a genuine weekly quota from the menu bar.
    func automaticMenuBarWindow() -> RateWindow? {
        let windows = self.visibleRateLanes.compactMap {
            self.menuBarSelectableRateWindow(for: $0)
        }
        guard let weekly = self.menuBarSelectableRateWindow(for: .weekly),
              windows.contains(where: {
                  $0.windowMinutes.map { $0 > Self.weeklyWindowMinutes } ?? false
              })
        else {
            return windows.first
        }
        return weekly
    }

    static func rateTitle(
        lane: RateLane,
        windowMinutes: Int?,
        sessionLabel: String,
        weeklyLabel: String) -> String
    {
        switch windowMinutes {
        case self.sessionWindowMinutes:
            L(sessionLabel)
        case self.weeklyWindowMinutes:
            L(weeklyLabel)
        case self.monthlyWindowMinutes:
            L("Monthly")
        default:
            switch lane {
            case .session:
                L(sessionLabel)
            case .weekly:
                L(weeklyLabel)
            case .monthly:
                L("Monthly credit limit")
            }
        }
    }

    var nextMenuBarStateChangeAt: Date? {
        self.rateWindowsByLane.values.compactMap { window in
            guard window.remainingPercent <= 0,
                  let resetAt = window.resetsAt,
                  resetAt > self.evaluationTime
            else {
                return nil
            }
            return resetAt
        }.min()
    }

    var hasBindingWeeklyCap: Bool {
        Self.weeklyCapsSession(
            weekly: self.rateWindowsByLane[.weekly],
            evaluationTime: self.evaluationTime)
    }

    func remainingPercent(for metric: SupplementalMetric) -> Double? {
        switch metric {
        case .codeReview:
            self.codeReviewRemainingPercent
        }
    }

    func limitWindow(for metric: SupplementalMetric) -> RateWindow? {
        switch metric {
        case .codeReview:
            self.codeReviewLimit
        }
    }

    private static func dashboardVisibility(surface: Surface, context: Context) -> DashboardVisibility {
        guard surface != .overrideCard else { return .hidden }
        guard context.dashboardRequiresLogin == false, context.liveDashboard != nil else { return .hidden }
        return context.dashboardAttachmentAuthorized ? .attached : .displayOnly
    }

    private static func monthlyCreditLimit(
        surface: Surface,
        context: Context) -> CodexCreditLimitSnapshot?
    {
        switch surface {
        case .menuBar, .overrideCard:
            guard context.showOptionalCreditsAndExtraUsage else { return nil }
            let live = context.liveCredits?.codexCreditLimit
            guard let cost = CodexExtraUsageCost.resolving(
                liveCredits: context.liveCredits, attached: context.snapshot?.providerCost),
                cost.currencyCode == CodexExtraUsageCost.currencyCode, cost.limit > 0
            else { return live }
            if let live, live.updatedAt >= cost.updatedAt {
                return live
            }
            return CodexCreditLimitSnapshot(
                used: cost.used,
                limit: cost.limit,
                remainingPercent: max(0, 100 - cost.used / cost.limit * 100),
                resetsAt: cost.resetsAt,
                updatedAt: cost.updatedAt)
        case .liveCard, .widget:
            return nil
        }
    }

    private static func rateWindowsByLane(
        snapshot: UsageSnapshot?,
        monthlyCreditLimit: CodexCreditLimitSnapshot? = nil) -> [RateLane: RateWindow]
    {
        var windowsByLane: [RateLane: RateWindow] = [:]
        if let snapshot {
            let slottedWindows: [(RateLane, RateWindow)] = [
                self.classifyRateWindow(snapshot.primary, slot: .primary),
                self.classifyRateWindow(snapshot.secondary, slot: .secondary),
            ].compactMap(\.self)

            for (lane, window) in slottedWindows {
                windowsByLane[lane] = window
            }
            guard windowsByLane.isEmpty, !snapshot.hasRateLimitWindows else {
                return windowsByLane
            }
        }
        guard let monthlyCreditLimit else { return windowsByLane }
        windowsByLane[.monthly] = RateWindow(
            usedPercent: monthlyCreditLimit.usedPercent,
            windowMinutes: nil,
            resetsAt: monthlyCreditLimit.resetsAt,
            resetDescription: nil)
        return windowsByLane
    }

    private static func visibleRateLanes(
        from rateWindowsByLane: [RateLane: RateWindow],
        snapshot: UsageSnapshot?) -> [RateLane]
    {
        guard let snapshot else {
            return rateWindowsByLane[.monthly] == nil ? [] : [.monthly]
        }

        let slottedLanes = [
            self.classifyRateWindow(snapshot.primary, slot: .primary)?.0,
            self.classifyRateWindow(snapshot.secondary, slot: .secondary)?.0,
        ].compactMap(\.self)

        var visible: [RateLane] = []
        for lane in slottedLanes where rateWindowsByLane[lane] != nil && !visible.contains(lane) {
            visible.append(lane)
        }
        if visible.isEmpty, rateWindowsByLane[.monthly] != nil, !snapshot.hasRateLimitWindows {
            visible.append(.monthly)
        }
        return visible
    }

    private static func planUtilizationLanes(from rateWindowsByLane: [RateLane: RateWindow]) -> [PlanUtilizationLane] {
        let semanticOrder: [RateLane] = [.session, .weekly, .monthly]
        return semanticOrder.compactMap { lane in
            guard let window = rateWindowsByLane[lane] else { return nil }
            return PlanUtilizationLane(role: self.planUtilizationRole(for: lane), window: window)
        }
    }

    private static func planUtilizationRole(for lane: RateLane) -> PlanUtilizationSeriesName {
        switch lane {
        case .session:
            .session
        case .weekly:
            .weekly
        case .monthly:
            .monthly
        }
    }

    static func planUtilizationSeriesNames(snapshot: UsageSnapshot) -> Set<PlanUtilizationSeriesName> {
        Set(self.rateWindowsByLane(snapshot: snapshot).keys.map { self.planUtilizationRole(for: $0) })
    }

    private enum SnapshotSlot {
        case primary
        case secondary
    }

    private static func classifyRateWindow(_ window: RateWindow?, slot: SnapshotSlot) -> (RateLane, RateWindow)? {
        guard let window else { return nil }

        let lane: RateLane = switch window.windowMinutes {
        case Self.sessionWindowMinutes:
            .session
        case Self.weeklyWindowMinutes:
            .weekly
        case Self.monthlyWindowMinutes:
            .monthly
        default:
            switch slot {
            case .primary:
                .session
            case .secondary:
                .weekly
            }
        }

        return (lane, window)
    }

    /// When Codex's weekly lane is exhausted, it is the binding cap: session quota cannot be used until
    /// the weekly window resets, even if the API still reports room in the 5-hour bucket.
    private static func weeklyCapsSession(weekly: RateWindow?, evaluationTime: Date) -> Bool {
        guard let weekly else { return false }
        guard weekly.remainingPercent <= 0 else { return false }
        return weekly.resetsAt.map { $0 > evaluationTime } ?? true
    }

    private static func sessionDisplayWindow(
        session: RateWindow,
        weekly: RateWindow?,
        evaluationTime: Date) -> RateWindow
    {
        guard self.weeklyCapsSession(weekly: weekly, evaluationTime: evaluationTime) else {
            return session
        }
        let reset = self.bindingReset(
            session: session,
            weekly: weekly,
            evaluationTime: evaluationTime)
        return RateWindow(
            usedPercent: max(session.usedPercent, 100),
            windowMinutes: session.windowMinutes,
            resetsAt: reset.date,
            resetDescription: reset.description,
            nextRegenPercent: session.nextRegenPercent,
            isSyntheticPlaceholder: session.isSyntheticPlaceholder)
    }

    private static func bindingReset(
        session: RateWindow,
        weekly: RateWindow?,
        evaluationTime: Date) -> (date: Date?, description: String?)
    {
        guard let weekly else { return (nil, nil) }
        let sessionIsExhausted = session.remainingPercent <= 0 &&
            (session.resetsAt.map { $0 > evaluationTime } ?? true)
        guard sessionIsExhausted else {
            return (weekly.resetsAt, weekly.resetDescription)
        }
        guard let sessionReset = session.resetsAt, let weeklyReset = weekly.resetsAt else {
            return (nil, nil)
        }
        if sessionReset > weeklyReset {
            return (sessionReset, session.resetDescription)
        }
        return (weeklyReset, weekly.resetDescription)
    }

    private static func menuBarFallback(
        creditsRemaining: Double?,
        rateWindowsByLane: [RateLane: RateWindow],
        evaluationTime: Date) -> MenuBarFallback
    {
        guard let creditsRemaining, creditsRemaining > 0 else { return .none }
        let hasExhaustedLane = rateWindowsByLane.values.contains {
            $0.remainingPercent <= 0 && ($0.resetsAt.map { $0 > evaluationTime } ?? true)
        }
        let hasNoRateWindows = rateWindowsByLane.isEmpty
        return (hasExhaustedLane || hasNoRateWindows) ? .creditsBalance : .none
    }

    var hasExhaustedRateLane: Bool {
        self.rateWindowsByLane.values.contains {
            $0.remainingPercent <= 0 && ($0.resetsAt.map { $0 > self.evaluationTime } ?? true)
        }
    }
}

extension UsageStore {
    func codexConsumerProjectionIfNeeded(
        for provider: UsageProvider,
        surface: CodexConsumerProjection.Surface,
        snapshotOverride: UsageSnapshot? = nil,
        errorOverride: String? = nil,
        creditsOverride: CreditsSnapshot? = nil,
        now: Date = Date()) -> CodexConsumerProjection?
    {
        guard provider == .codex else { return nil }
        return self.codexConsumerProjection(
            surface: surface,
            snapshotOverride: snapshotOverride,
            errorOverride: errorOverride,
            creditsOverride: creditsOverride,
            now: now)
    }

    func codexConsumerProjection(
        surface: CodexConsumerProjection.Surface,
        snapshotOverride: UsageSnapshot? = nil,
        errorOverride: String? = nil,
        creditsOverride: CreditsSnapshot? = nil,
        now: Date = Date()) -> CodexConsumerProjection
    {
        let snapshot = surface == .overrideCard ? snapshotOverride : snapshotOverride ?? self.snapshots[.codex]
        let rawUsageError = surface == .overrideCard ? errorOverride : errorOverride ?? self.errors[.codex]
        let liveCredits = surface == .overrideCard ? creditsOverride : self.credits
        let rawCreditsError = surface == .overrideCard ? nil : self.lastCreditsError
        let context = CodexConsumerProjection.Context(
            snapshot: snapshot,
            rawUsageError: rawUsageError,
            liveCredits: liveCredits,
            rawCreditsError: rawCreditsError,
            liveDashboard: self.openAIDashboard,
            rawDashboardError: self.lastOpenAIDashboardError,
            dashboardAttachmentAuthorized: self.openAIDashboardAttachmentAuthorized,
            dashboardRequiresLogin: self.openAIDashboardRequiresLogin,
            now: now,
            showOptionalCreditsAndExtraUsage: self.settings.showOptionalCreditsAndExtraUsage)
        return CodexConsumerProjection.make(surface: surface, context: context)
    }

    func codexMenuBarCreditsRemaining(snapshotOverride: UsageSnapshot? = nil, now: Date = Date()) -> Double? {
        let projection = self.codexConsumerProjection(
            surface: .menuBar,
            snapshotOverride: snapshotOverride,
            now: now)
        guard projection.menuBarFallback == .creditsBalance else { return nil }
        return projection.credits?.remaining
    }

    func codexMenuBarMetricWindow(snapshot: UsageSnapshot, now: Date = Date()) -> RateWindow? {
        let projection = self.codexConsumerProjection(
            surface: .menuBar,
            snapshotOverride: snapshot,
            now: now)
        let windows = projection.displayedRateLanes(
            showOptionalCreditsAndExtraUsage: self.settings.showOptionalCreditsAndExtraUsage).compactMap {
            projection.menuBarSelectableRateWindow(for: $0)
        }
        let first = windows.first
        let second = windows.dropFirst().first

        switch self.settings.menuBarMetricPreference(for: .codex, snapshot: snapshot) {
        case .secondary, .tertiary:
            return second ?? first
        case .extraUsage:
            return projection.extraUsageCost.flatMap { cost in
                guard cost.limit > 0 else { return nil }
                let usedPercent = max(0, min(100, (cost.used / cost.limit) * 100))
                return RateWindow(
                    usedPercent: usedPercent,
                    windowMinutes: nil,
                    resetsAt: cost.resetsAt,
                    resetDescription: nil)
            } ?? first
        case .average:
            guard self.settings.menuBarMetricSupportsAverage(for: .codex),
                  let primary = first,
                  let secondary = second
            else {
                return first
            }
            let usedPercent = (primary.usedPercent + secondary.usedPercent) / 2
            return RateWindow(
                usedPercent: usedPercent, windowMinutes: nil, resetsAt: nil, resetDescription: nil)
        case .primaryAndSecondary:
            return windows.prefix(2).max(by: { $0.usedPercent < $1.usedPercent })
        case .automatic:
            return projection.automaticMenuBarWindow()
        case .primary, .monthlyPlan:
            return first
        }
    }
}
