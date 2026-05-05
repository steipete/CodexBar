import CodexBarCore
import Foundation

struct CodexUIErrorMapper {
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

        if self.looksExpired(lower: lower) {
            return "Codex session expired. Sign in again."
        }

        if lower.contains("frame load interrupted") {
            return "OpenAI web refresh was interrupted. Refresh OpenAI cookies and try again."
        }

        if self.looksOpenAIWebTimeout(lower: lower) {
            return "OpenAI web refresh timed out. Refresh OpenAI cookies and try again."
        }

        if self.looksOpenAIWebNetworkError(lower: lower) {
            return "OpenAI web refresh hit a network error. "
                + "Check your connection, then refresh OpenAI cookies and try again."
        }

        if self.looksInternalTransport(lower: lower) {
            return "Codex usage is temporarily unavailable. Try refreshing."
        }

        return trimmed
    }

    private static func cachedMessage(raw: String, lower: String) -> String? {
        let cachedMarker = " Cached values from "
        guard let suffixRange = raw.range(of: cachedMarker) else { return nil }

        let suffix = String(raw[suffixRange.lowerBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        if lower.hasPrefix("last codex credits refresh failed:"),
           let base = self.userFacingMessage(String(raw[..<suffixRange.lowerBound]))
        {
            return "\(base) \(suffix)"
        }

        if lower.hasPrefix("last openai dashboard refresh failed:"),
           let base = self.userFacingMessage(String(raw[..<suffixRange.lowerBound]))
        {
            return "\(base) \(suffix)"
        }

        return nil
    }

    private static func isAlreadyUserFacing(lower: String) -> Bool {
        lower.contains("openai cookies are for")
            || lower.contains("sign in to chatgpt.com")
            || lower.contains("requires a signed-in chatgpt.com session")
            || lower.contains("managed codex account data is unavailable")
            || lower.contains("selected managed codex account is unavailable")
            || lower.contains("codex credits are still loading")
            || lower.contains("codex account changed; importing browser cookies")
            || lower.contains("codex session expired. sign in again.")
            || lower.contains("openai web refresh timed out. refresh openai cookies and try again.")
            || lower.contains(
                "openai web refresh hit a network error. "
                    + "check your connection, then refresh openai cookies and try again.")
            || lower.contains("codex usage is temporarily unavailable. try refreshing.")
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
    }

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
            self.snapshot?.remaining
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

    private let rateWindowsByLane: [RateLane: RateWindow]
    private let codeReviewRemainingPercent: Double?
    private let codeReviewLimit: RateWindow?

    static func make(surface: Surface, context: Context) -> CodexConsumerProjection {
        let allowsLiveAdjuncts = surface != .overrideCard
        let dashboardVisibility = self.dashboardVisibility(surface: surface, context: context)
        let dashboard = allowsLiveAdjuncts && dashboardVisibility != .hidden ? context.liveDashboard : nil

        let rateWindowsByLane = self.rateWindowsByLane(snapshot: context.snapshot)
        let visibleRateLanes = self.visibleRateLanes(from: rateWindowsByLane, snapshot: context.snapshot)
        let planUtilizationLanes = self.planUtilizationLanes(from: rateWindowsByLane)

        let creditsProjection: CreditsProjection? = if allowsLiveAdjuncts,
                                                       context.liveCredits != nil || context.rawCreditsError != nil
        {
            CreditsProjection(
                snapshot: context.liveCredits,
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
                rateWindowsByLane: rateWindowsByLane),
            userFacingErrors: userFacingErrors,
            canShowBuyCredits: canShowBuyCredits,
            hasUsageBreakdown: hasUsageBreakdown,
            hasCreditsHistory: hasCreditsHistory,
            rateWindowsByLane: rateWindowsByLane,
            codeReviewRemainingPercent: dashboardVisibility == .attached ? dashboard?.codeReviewRemainingPercent : nil,
            codeReviewLimit: dashboardVisibility == .attached ? dashboard?.codeReviewLimit : nil)
    }

    func rateWindow(for lane: RateLane) -> RateWindow? {
        self.rateWindowsByLane[lane]
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

    private static func rateWindowsByLane(snapshot: UsageSnapshot?) -> [RateLane: RateWindow] {
        guard let snapshot else { return [:] }

        var windowsByLane: [RateLane: RateWindow] = [:]
        let slottedWindows: [(RateLane, RateWindow)] = [
            self.classifyRateWindow(snapshot.primary, slot: .primary),
            self.classifyRateWindow(snapshot.secondary, slot: .secondary),
        ].compactMap(\.self)

        for (lane, window) in slottedWindows {
            windowsByLane[lane] = window
        }
        return windowsByLane
    }

    private static func visibleRateLanes(
        from rateWindowsByLane: [RateLane: RateWindow],
        snapshot: UsageSnapshot?) -> [RateLane]
    {
        guard let snapshot else { return [] }

        let slottedLanes = [
            self.classifyRateWindow(snapshot.primary, slot: .primary)?.0,
            self.classifyRateWindow(snapshot.secondary, slot: .secondary)?.0,
        ].compactMap(\.self)

        var visible: [RateLane] = []
        for lane in slottedLanes where rateWindowsByLane[lane] != nil && !visible.contains(lane) {
            visible.append(lane)
        }
        return visible
    }

    private static func planUtilizationLanes(from rateWindowsByLane: [RateLane: RateWindow]) -> [PlanUtilizationLane] {
        let semanticOrder: [RateLane] = [.session, .weekly]
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
        }
    }

    private enum SnapshotSlot {
        case primary
        case secondary
    }

    private static func classifyRateWindow(_ window: RateWindow?, slot: SnapshotSlot) -> (RateLane, RateWindow)? {
        guard let window else { return nil }

        let lane: RateLane = switch window.windowMinutes {
        case 300:
            .session
        case 10080:
            .weekly
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

    private static func menuBarFallback(
        creditsRemaining: Double?,
        rateWindowsByLane: [RateLane: RateWindow]) -> MenuBarFallback
    {
        guard let creditsRemaining, creditsRemaining > 0 else { return .none }
        let hasExhaustedLane = rateWindowsByLane.values.contains { $0.remainingPercent <= 0 }
        let hasNoRateWindows = rateWindowsByLane.isEmpty
        return (hasExhaustedLane || hasNoRateWindows) ? .creditsBalance : .none
    }

    var hasExhaustedRateLane: Bool {
        self.rateWindowsByLane.values.contains { $0.remainingPercent <= 0 }
    }
}

extension UsageStore {
    func codexConsumerProjectionIfNeeded(
        for provider: UsageProvider,
        surface: CodexConsumerProjection.Surface,
        snapshotOverride: UsageSnapshot? = nil,
        errorOverride: String? = nil,
        now: Date = Date()) -> CodexConsumerProjection?
    {
        guard provider == .codex else { return nil }
        return self.codexConsumerProjection(
            surface: surface,
            snapshotOverride: snapshotOverride,
            errorOverride: errorOverride,
            now: now)
    }

    func codexConsumerProjection(
        surface: CodexConsumerProjection.Surface,
        snapshotOverride: UsageSnapshot? = nil,
        errorOverride: String? = nil,
        now: Date = Date()) -> CodexConsumerProjection
    {
        let context = CodexConsumerProjection.Context(
            snapshot: snapshotOverride ?? self.snapshots[.codex],
            rawUsageError: errorOverride ?? self.errors[.codex],
            liveCredits: self.credits,
            rawCreditsError: self.lastCreditsError,
            liveDashboard: self.openAIDashboard,
            rawDashboardError: self.lastOpenAIDashboardError,
            dashboardAttachmentAuthorized: self.openAIDashboardAttachmentAuthorized,
            dashboardRequiresLogin: self.openAIDashboardRequiresLogin,
            now: now)
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
}
