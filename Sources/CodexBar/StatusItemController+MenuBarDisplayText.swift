import CodexBarCore
import Foundation

extension StatusItemController {
    func menuBarDisplayText(
        for provider: UsageProvider,
        snapshot: UsageSnapshot?,
        accountScoped: Bool = false,
        now: Date = .init()) -> String?
    {
        // Provider-specific by design: provider payload fields and display modes supply distinct balance/spend text.
        let mode = self.settings.menuBarDisplayMode
        if provider == .openrouter,
           self.settings.menuBarMetricPreference(for: provider, snapshot: snapshot) == .automatic,
           let balance = snapshot?.detailRow(label: "Remaining")?.value
        {
            return balance
        }
        if provider == .opencodego,
           let balance = Self.openCodeGoZenBalanceDisplayText(snapshot: snapshot)
        {
            return balance
        }
        if provider == .deepseek,
           let balance = MenuBarDisplayText.deepSeekBalanceText(snapshot: snapshot)
        {
            return balance
        }
        if provider == .deepinfra,
           let balance = Self.deepInfraBalanceDisplayText(snapshot: snapshot)
        {
            return balance
        }
        if provider == .mimo,
           let balance = Self.miMoBalanceDisplayText(
               snapshot: snapshot,
               preference: self.settings.menuBarMetricPreference(for: provider, snapshot: snapshot))
        {
            return balance
        }
        if provider == .moonshot,
           let balance = Self.moonshotBalanceDisplayText(snapshot: snapshot)
        {
            return balance
        }
        if provider == .poe,
           let balance = Self.poeBalanceDisplayText(snapshot: snapshot)
        {
            return balance
        }
        if provider == .mistral {
            let preference = self.settings.menuBarMetricPreference(for: provider, snapshot: snapshot)
            let hasMonthlyPlan = snapshot?.extraRateWindows?.contains { $0.id == "mistral-monthly-plan" } == true
            if preference != .monthlyPlan || !hasMonthlyPlan,
               let spend = Self.mistralSpendDisplayText(snapshot: snapshot)
            {
                return spend
            }
        }
        if provider == .kiro {
            return Self.kiroDisplayText(
                snapshot: snapshot,
                mode: self.settings.kiroMenuBarDisplayMode,
                showUsed: self.settings.usageBarsShowUsed)
        }
        if mode != .resetTime,
           self.settings.menuBarMetricPreference(for: provider, snapshot: snapshot) == .extraUsage,
           provider != .cursor || mode == .pace,
           let spend = Self.extraUsageSpendDisplayText(snapshot: snapshot)
        {
            return spend
        }

        let percentWindow = self.menuBarPercentWindow(for: provider, snapshot: snapshot, now: now)
        let codexProjection: CodexConsumerProjection? = accountScoped
            ? nil
            : self.store.codexConsumerProjectionIfNeeded(
                for: provider,
                surface: .menuBar,
                snapshotOverride: snapshot,
                now: now)

        // The combined "Session + Weekly" metric (Codex and Claude) shows both lanes in percent mode
        // ("5h 12% · W 45%") and, in pace/both modes, pairs the session usage with the weekly pace.
        let combinedLanes = self.combinedSessionWeeklyLanes(
            for: provider, snapshot: snapshot, projection: codexProjection)

        let pace: UsagePace?
        switch mode {
        case .percent:
            pace = nil
        case .pace, .both:
            guard !accountScoped else {
                pace = nil
                break
            }
            let paceWindow = self.menuBarPaceWindow(
                for: provider,
                snapshot: snapshot,
                projection: codexProjection,
                combinedLanes: combinedLanes,
                percentWindow: percentWindow)
            pace = paceWindow.flatMap { window in
                self.store.weeklyPace(provider: provider, window: window, now: now)
            }
        case .resetTime:
            return MenuBarDisplayText.displayText(
                mode: mode,
                percentWindow: percentWindow,
                showUsed: self.settings.usageBarsShowUsed,
                resetTimeDisplayStyle: self.settings.resetTimeDisplayStyle,
                now: now)
        }
        if mode == .percent,
           !self.settings.usageBarsShowUsed,
           codexProjection?.menuBarFallback == .creditsBalance,
           let creditsRemaining = codexProjection?.credits?.remaining,
           creditsRemaining > 0
        {
            return
                UsageFormatter
                    .creditsString(from: creditsRemaining)
                    .replacingOccurrences(of: " left", with: "")
        }
        if let combinedLanes, mode == .percent {
            if let combinedText = MenuBarDisplayText.combinedSessionWeeklyPercentText(
                sessionWindow: combinedLanes.session,
                weeklyWindow: combinedLanes.weekly,
                showUsed: self.settings.usageBarsShowUsed,
                resetTimeDisplayStyle: self.settings.resetTimeDisplayStyle,
                showsResetTimeWhenExhausted: self.settings.menuBarShowsResetTimeWhenExhausted,
                now: now)
            {
                return combinedText
            }
        }

        let displayPercentWindow: RateWindow? = if let combinedLanes {
            Self.combinedDisplayPercentWindow(lanes: combinedLanes, fallback: percentWindow)
        } else {
            percentWindow
        }
        return MenuBarDisplayText.displayText(
            mode: mode,
            percentWindow: displayPercentWindow,
            pace: pace,
            showUsed: self.settings.usageBarsShowUsed,
            resetTimeDisplayStyle: self.settings.resetTimeDisplayStyle,
            showsResetTimeWhenExhausted: self.settings.menuBarShowsResetTimeWhenExhausted,
            now: now)
    }

    nonisolated static func deepInfraBalanceDisplayText(snapshot: UsageSnapshot?) -> String? {
        guard
            let detail = snapshot?.primary?.resetDescription?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                let balanceDetail = detail.components(separatedBy: " · ").dropLast().last?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                    balanceDetail.hasPrefix("$"),
                    let value = balanceDetail.split(separator: " ", maxSplits: 1).first
        else {
            return nil
        }

        let prefix = balanceDetail.contains(" owed") ? "-" : ""
        return prefix + String(value)
    }

    nonisolated static func miMoBalanceDisplayText(
        snapshot: UsageSnapshot?,
        preference: MenuBarMetricPreference) -> String?
    {
        guard let snapshot, let detail = snapshot.detailRow(label: "Balance")?.value else { return nil }
        if snapshot.primary != nil, preference != .secondary {
            return nil
        }
        return detail.components(separatedBy: " (Paid:").first
    }

    nonisolated static func poeBalanceDisplayText(snapshot: UsageSnapshot?) -> String? {
        // Provider-specific by design: Poe stores its point balance in the login-method payload field.
        self.displayValue(
            from: snapshot?.loginMethod(for: .poe),
            prefix: "Balance:",
            removingSuffix: "")
    }

    nonisolated static func moonshotBalanceDisplayText(snapshot: UsageSnapshot?) -> String? {
        // Provider-specific by design: Moonshot stores cash/voucher balance text in its login-method payload.
        self.displayValue(
            from: snapshot?.loginMethod(for: .moonshot),
            prefix: "Balance:",
            removingSuffix: "")
            .flatMap { value in
                value
                    .split(separator: "·", maxSplits: 1)
                    .first?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
    }

    nonisolated static func mistralSpendDisplayText(snapshot: UsageSnapshot?) -> String? {
        self.displayValue(
            from: snapshot?.identity?.loginMethod,
            prefix: "API spend:",
            removingSuffix: " this month")
    }

    nonisolated static func extraUsageSpendDisplayText(snapshot: UsageSnapshot?) -> String? {
        guard let cost = snapshot?.providerCost,
              cost.limit > 0,
              cost.used >= 0
        else {
            return nil
        }
        return UsageFormatter.currencyString(cost.used, currencyCode: cost.currencyCode)
    }

    nonisolated static func openCodeGoZenBalanceDisplayText(snapshot: UsageSnapshot?) -> String? {
        guard snapshot?.primary == nil,
              snapshot?.secondary == nil,
              let cost = snapshot?.providerCost,
              cost.period == "Zen balance"
        else {
            return nil
        }
        return UsageFormatter.currencyString(cost.used, currencyCode: cost.currencyCode)
    }

    nonisolated static func kiroDisplayText(
        snapshot: UsageSnapshot?,
        mode: KiroMenuBarDisplayMode,
        showUsed: Bool)
        -> String?
    {
        guard mode != .hidden else { return nil }
        guard let snapshot else {
            return MenuBarDisplayText.percentText(window: snapshot?.primary, showUsed: showUsed)
        }
        let percentText = MenuBarDisplayText.percentText(
            window: snapshot.primary,
            showUsed: showUsed)
        let creditsLeft = snapshot.detailRow(label: "Credits left")?.value
        let creditsUsed = snapshot.detailRow(label: "Credits used")?.value
        let creditsTotal = snapshot.detailRow(label: "Credits total")?.value
        let usedTotal = [creditsUsed, creditsTotal].compactMap(\.self).joined(separator: " / ")

        switch mode {
        case .automatic, .creditsLeft:
            if let creditsLeft, creditsTotal != "0" {
                return creditsLeft
            }
            return percentText
        case .hidden:
            return nil
        case .percentLeft:
            return MenuBarDisplayText.percentText(window: snapshot.primary, showUsed: false)
        case .creditsAndPercent:
            guard creditsTotal != "0" else { return percentText }
            guard let percentText else { return creditsLeft }
            return creditsLeft.map { "\($0) · \(percentText)" } ?? percentText
        case .usedAndTotal:
            guard creditsTotal != "0" else { return percentText }
            return usedTotal.isEmpty ? percentText : usedTotal
        case .overageCreditsWhenExhausted:
            return self.kiroOverageDisplayText(
                snapshot: snapshot,
                format: .credits,
                fallback: creditsLeft ?? percentText,
                percentFallback: percentText)
        case .overageCostWhenExhausted:
            return self.kiroOverageDisplayText(
                snapshot: snapshot,
                format: .cost,
                fallback: creditsLeft ?? percentText,
                percentFallback: percentText)
        case .overageCreditsAndCostWhenExhausted:
            return self.kiroOverageDisplayText(
                snapshot: snapshot,
                format: .creditsAndCost,
                fallback: creditsLeft ?? percentText,
                percentFallback: percentText)
        }
    }

    private enum KiroOverageDisplayFormat {
        case credits
        case cost
        case creditsAndCost
    }

    private nonisolated static func kiroOverageDisplayText(
        snapshot: UsageSnapshot,
        format: KiroOverageDisplayFormat,
        fallback: String?,
        percentFallback: String?)
        -> String?
    {
        guard snapshot.detailRow(label: "Credits total")?.value != "0" else { return percentFallback }
        guard snapshot.detailRow(label: "Credits left")?.value == "0" else { return fallback }
        guard
            snapshot.detailRow(label: "Overages")?.value
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
                .hasPrefix("enabled") == true
        else {
            return fallback
        }

        let credits = snapshot.detailRow(label: "Overage usage")?.value
            .replacingOccurrences(of: " credits", with: " over")
        let cost = snapshot.detailRow(label: "Overage cost").map { "\($0.value) over" }

        switch format {
        case .credits:
            return credits ?? cost ?? fallback
        case .cost:
            return cost ?? credits ?? fallback
        case .creditsAndCost:
            if let credits, let cost {
                let creditsValue = credits.replacingOccurrences(of: " over", with: "")
                let costValue = cost.replacingOccurrences(of: " over", with: "")
                return "\(creditsValue) · \(costValue)"
            }
            return credits ?? cost ?? fallback
        }
    }

    private nonisolated static func displayValue(
        from text: String?,
        prefix: String,
        removingSuffix suffix: String)
        -> String?
    {
        guard let rawValue = text?.trimmingCharacters(in: .whitespacesAndNewlines),
              rawValue.hasPrefix(prefix)
        else {
            return nil
        }
        let valueStart = rawValue.index(rawValue.startIndex, offsetBy: prefix.count)
        var value = rawValue[valueStart...].trimmingCharacters(in: .whitespacesAndNewlines)
        if !suffix.isEmpty, value.hasSuffix(suffix) {
            value = String(value.dropLast(suffix.count)).trimmingCharacters(
                in: .whitespacesAndNewlines)
        }
        return value.isEmpty ? nil : value
    }

    private func menuBarPercentWindow(for provider: UsageProvider, snapshot: UsageSnapshot?, now: Date)
        -> RateWindow?
    {
        self.menuBarMetricWindow(for: provider, snapshot: snapshot, now: now)
    }

    /// Resolves the session (5h) and weekly (7d) lanes for the combined "Session + Weekly" menu-bar
    /// metric, or nil when that metric is not active for `provider`. Codex resolves its lanes through the
    /// consumer projection; Claude has none, so it classifies by window cadence — a 7-day window the OAuth
    /// mapper parked in `primary` (the five_hour fallback) must not be mislabeled as a 5-hour session lane.
    private func combinedSessionWeeklyLanes(
        for provider: UsageProvider,
        snapshot: UsageSnapshot?,
        projection: CodexConsumerProjection?) -> (session: RateWindow?, weekly: RateWindow?)?
    {
        // Provider-specific by design: only Codex and Claude expose the combined session-and-weekly menu metric.
        guard provider == .codex || provider == .claude,
              self.settings.menuBarMetricPreference(for: provider, snapshot: snapshot) == .primaryAndSecondary
        else { return nil }
        // A Claude account that only exposes an enterprise/extra-usage spend limit has no real
        // session/weekly lanes; defer to the resolver's spend-limit routing instead of rendering an
        // empty or 0% placeholder lane under the combined metric.
        if provider == .claude,
           let snapshot,
           MenuBarMetricWindowResolver.claudeSpendLimitWindow(snapshot: snapshot) != nil
        {
            return nil
        }
        let session = Self.combinedSessionLane(snapshot: snapshot, projection: projection)
        let weekly: RateWindow? = if let projection {
            projection.menuBarSelectableRateWindow(for: .weekly)
        } else {
            Self.rateWindow(in: snapshot, matchingCadenceMinutes: Self.weeklyWindowMinutes)
        }
        return (session, weekly)
    }

    /// Reset dates for every lane whose menu-bar text is currently rendered as a reset time, so the
    /// countdown scheduler can refresh each of them. Reset-time mode drives a single window. The smart
    /// "reset time when exhausted" option can surface BOTH combined session/weekly lanes in percent mode,
    /// while pace/both render the one lane chosen by `combinedDisplayPercentWindow` — mirror that presentation
    /// here rather than scheduling whichever lane happened to drive the icon.
    func menuBarDisplayedResetDates(for provider: UsageProvider, now: Date) -> [Date] {
        let snapshot = self.store.menuBarSnapshot(for: provider.instanceID)
        let layoutResolution = self.settings.menuBarLayoutResolution(for: provider)
        if !layoutResolution.usesLegacyRendering,
           self.settings.menuBarIconStyle == .iconAndPercent
        {
            let showsReset = layoutResolution.layout
                .flattenedTokens(conditionals: self.settings.menuBarLayoutConditionals)
                .contains { $0 == .resetCountdown || $0 == .resetAbsolute }
            guard showsReset else { return [] }
            let window = self.menuBarLayoutWindows(provider: provider, snapshot: snapshot, now: now).automatic
            return window?.resetsAt.map { [$0] } ?? []
        }
        let mode = self.settings.menuBarDisplayMode

        let projection = self.store.codexConsumerProjectionIfNeeded(
            for: provider,
            surface: .menuBar,
            snapshotOverride: snapshot,
            now: now)
        if let lanes = self.combinedSessionWeeklyLanes(
            for: provider, snapshot: snapshot, projection: projection),
            lanes.session != nil || lanes.weekly != nil
        {
            switch mode {
            case .percent:
                // Percent renders both lanes independently, so schedule every exhausted reset.
                return [lanes.session, lanes.weekly]
                    .compactMap(\.self)
                    .filter { $0.remainingPercent <= 0 }
                    .compactMap(\.resetsAt)
            case .pace, .both:
                // Pace/both render one usage lane alongside the weekly pace. Use that exact lane rather
                // than `menuBarMetricWindow`, whose tie-breaking can select the other exhausted window.
                let window = Self.combinedDisplayPercentWindow(
                    lanes: lanes,
                    fallback: self.menuBarMetricWindow(for: provider, snapshot: snapshot, now: now))
                guard let window, window.remainingPercent <= 0 else { return [] }
                return window.resetsAt.map { [$0] } ?? []
            case .resetTime:
                break
            }
        }

        guard let window = self.menuBarMetricWindow(for: provider, snapshot: snapshot, now: now)
        else { return [] }
        // Outside reset-time mode the reset text is only visible once the quota is exhausted.
        if mode != .resetTime, window.remainingPercent > 0 {
            return []
        }
        return window.resetsAt.map { [$0] } ?? []
    }

    /// The combined metric's session (5h) lane. Codex resolves it through the consumer projection; other
    /// providers classify by window cadence. A 5-hour lane the provider only synthesized to stand in for an
    /// absent session — Claude web's null `five_hour` placeholder, flagged at the boundary — is dropped so a
    /// weekly-only account falls back to its weekly lane instead of rendering a phantom `5h 0%`/`5h 100%`
    /// session. A genuine session (even one freshly reset to 0%) is not flagged, so it is kept.
    private static func combinedSessionLane(
        snapshot: UsageSnapshot?,
        projection: CodexConsumerProjection?) -> RateWindow?
    {
        if let projection {
            return projection.menuBarSelectableRateWindow(for: .session)
        }
        guard let session = Self.rateWindow(in: snapshot, matchingCadenceMinutes: Self.sessionWindowMinutes)
        else { return nil }
        if session.isSyntheticPlaceholder {
            return nil
        }
        return session
    }

    /// The window the weekly pace is computed on in pace/both modes. Codex paces on its projected weekly
    /// lane; the combined Session + Weekly metric paces on the weekly lane too (matching Codex); Abacus
    /// has no secondary window so it paces on the primary monthly credits; everything else paces on the
    /// selected percent window.
    private func menuBarPaceWindow(
        for provider: UsageProvider,
        snapshot: UsageSnapshot?,
        projection: CodexConsumerProjection?,
        combinedLanes: (session: RateWindow?, weekly: RateWindow?)?,
        percentWindow: RateWindow?) -> RateWindow?
    {
        if let projection {
            return projection.menuBarSelectableRateWindow(for: .weekly)
        }
        // Provider-specific by design: Abacus publishes its weekly semantic window in the primary lane.
        if provider == .abacus {
            return snapshot?.primary
        }
        if let combinedLanes {
            return combinedLanes.weekly
        }
        return percentWindow
    }

    /// The usage window shown for the combined metric in pace/both modes. It pairs the SESSION usage with
    /// the weekly pace, so the usage component normally comes from the session lane — not the
    /// most-constrained lane that drives the icon/bar. Two exceptions: fall back to the weekly lane when no
    /// session lane exists (the five_hour OAuth fallback or Claude web's filtered null-session
    /// placeholder), and surface the weekly lane when it is exhausted
    /// — it is then the binding cap with no pace to show, and a roomy session number would hide it.
    private static func combinedDisplayPercentWindow(
        lanes: (session: RateWindow?, weekly: RateWindow?),
        fallback: RateWindow?) -> RateWindow?
    {
        if let weekly = lanes.weekly, weekly.remainingPercent <= 0 {
            return weekly
        }
        return lanes.session ?? lanes.weekly ?? fallback
    }

    private static let sessionWindowMinutes = 5 * 60
    private static let weeklyWindowMinutes = 7 * 24 * 60

    /// Returns the first session/weekly snapshot lane whose window cadence matches `minutes`.
    /// Used by the combined Session + Weekly metric for providers without a Codex consumer
    /// projection so a fallback weekly window parked in `primary` is not mislabeled as a session lane.
    private static func rateWindow(in snapshot: UsageSnapshot?, matchingCadenceMinutes minutes: Int) -> RateWindow? {
        [snapshot?.primary, snapshot?.secondary]
            .compactMap(\.self)
            .first { $0.windowMinutes == minutes }
    }
}
