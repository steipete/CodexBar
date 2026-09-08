import CodexBarCore
import Foundation

extension StatusItemController {
    func storeIconObservationSignature() -> String {
        let showBrandPercent = self.settings.menuBarShowsBrandIconWithPercent
        let mergeIcons = self.shouldMergeIcons
        let visibleProviders = self.store.enabledProvidersForDisplay().map(\.rawValue).sorted().joined(separator: ",")
        let providerSignatures: String
        let primaryProvider: UsageProvider?
        if mergeIcons {
            let primary = self.primaryProviderForUnifiedIcon()
            primaryProvider = primary
            providerSignatures = self.providerStoreIconObservationSignature(
                for: primary,
                showBrandPercent: showBrandPercent)
        } else {
            primaryProvider = nil
            providerSignatures = UsageProvider.allCases
                .filter { self.isVisible($0) }
                .map { self.providerStoreIconObservationSignature(for: $0, showBrandPercent: showBrandPercent) }
                .joined(separator: "||")
        }
        return [
            "merge=\(mergeIcons ? "1" : "0")",
            "visible=\(visibleProviders)",
            "primary=\(primaryProvider?.rawValue ?? "nil")",
            "iconStyle=\(self.store.iconStyle.rawValue)",
            "showUsed=\(self.settings.usageBarsShowUsed ? "1" : "0")",
            "brandPercent=\(showBrandPercent ? "1" : "0")",
            "hideCritters=\(self.settings.menuBarHidesCritters ? "1" : "0")",
            "needsAnimation=\(self.needsMenuBarIconAnimation() ? "1" : "0")",
            providerSignatures,
        ].joined(separator: "|")
    }

    private func providerStoreIconObservationSignature(for provider: UsageProvider, showBrandPercent: Bool) -> String {
        let snapshot = self.store.menuBarSnapshot(for: provider.instanceID)
        let style = self.store.style(for: provider)
        let resolved = self.resolvedMenuBarIconPercents(
            provider: provider,
            snapshot: snapshot,
            style: style,
            showUsed: self.settings.usageBarsShowUsed)
        let creditsRemaining = self.menuBarCreditsRemainingForIcon(provider: provider, snapshot: snapshot)
        let scopedWeekly = MenuBarLayoutSemanticWindowResolver.scopedWeeklyNamedWindow(snapshot: snapshot)
        let displayText = showBrandPercent ? self.menuBarDisplayText(for: provider, snapshot: snapshot) : nil
        let layoutCostSignature = showBrandPercent
            ? self.storedMenuBarLayoutCostSignature(for: provider)
            : nil
        let layoutAccountSignature = showBrandPercent
            ? self.storedMenuBarLayoutAccountSignature(for: provider, snapshot: snapshot)
            : nil
        let layoutPaceSignature = showBrandPercent
            ? self.storedMenuBarLayoutPaceSignature(for: provider, snapshot: snapshot)
            : nil
        let layoutBalanceSignature = showBrandPercent
            ? self.storedMenuBarLayoutBalanceSignature(for: provider, snapshot: snapshot)
            : nil
        let layoutLaneSignature = showBrandPercent
            ? self.storedMenuBarLayoutLaneSignature(for: provider, snapshot: snapshot)
            : nil
        let layoutConditionalWindowSignature = showBrandPercent
            ? self.storedMenuBarLayoutConditionalWindowSignature(for: provider, snapshot: snapshot)
            : nil

        return [
            provider.rawValue,
            "style=\(style.rawValue)",
            "primary=\(Self.iconSignatureValue(resolved?.primary))",
            "weekly=\(Self.iconSignatureValue(resolved?.secondary))",
            "scopedWeekly=\(Self.iconSignatureValue(scopedWeekly?.window.usedPercent))",
            "scopedTitle=\(scopedWeekly?.title ?? "nil")",
            "credits=\(Self.iconSignatureValue(creditsRemaining))",
            "stale=\(self.store.isStale(provider: provider) ? "1" : "0")",
            "status=\(self.store.statusIndicator(for: provider).rawValue)",
            "anim=\(self.shouldAnimate(provider: provider) ? "1" : "0")",
            "refreshing=\(self.store.refreshingProviders.contains(provider.instanceID) ? "1" : "0")",
            "text=\(displayText ?? "nil")",
            "layoutCost=\(layoutCostSignature ?? "nil")",
            "layoutAccount=\(layoutAccountSignature ?? "nil")",
            "layoutPace=\(layoutPaceSignature ?? "nil")",
            "layoutBalance=\(layoutBalanceSignature ?? "nil")",
            "layoutLanes=\(layoutLaneSignature ?? "nil")",
            "layoutCondWindows=\(layoutConditionalWindowSignature ?? "nil")",
        ].joined(separator: "|")
    }

    private func storedMenuBarLayoutAccountSignature(
        for provider: UsageProvider,
        snapshot: UsageSnapshot?)
        -> String?
    {
        let resolution = self.settings.menuBarLayoutResolution(for: provider)
        guard !resolution.usesLegacyRendering,
              resolution.layout.flattenedTokens(conditionals: self.settings.menuBarLayoutConditionals)
                  .contains(.accountLabel),
                  let accountLabel = self.menuBarLayoutAccountLabel(provider: provider, snapshot: snapshot)
        else { return nil }

        var hasher = Hasher()
        hasher.combine(accountLabel)
        return String(hasher.finalize())
    }

    private func storedMenuBarLayoutCostSignature(for provider: UsageProvider) -> String? {
        let resolution = self.settings.menuBarLayoutResolution(for: provider)
        guard !resolution.usesLegacyRendering else { return nil }

        let tokens = resolution.layout.flattenedTokens(conditionals: self.settings.menuBarLayoutConditionals)
        let metrics = self.referencedConditionalMetrics(resolution: resolution)
        let showsToday = tokens.contains(.costToday) || metrics.contains(.costToday)
        let showsLast30Days = tokens.contains(.cost30d) || metrics.contains(.cost30d)
        guard showsToday || showsLast30Days else { return nil }

        let costs = self.menuBarLayoutCosts(provider: provider)
        return [
            "today=\(showsToday ? costs.today ?? "nil" : "unused")",
            "last30Days=\(showsLast30Days ? costs.last30Days ?? "nil" : "unused")",
            // Predicates compare the unrounded amounts, and two token-cost updates can cross a
            // threshold while both format to the same cent, so a conditional also signs the numbers.
            "todayUSD=\(metrics.contains(.costToday) ? Self.exactSignatureValue(costs.todayUSD) : "unused")",
            "last30DaysUSD=\(metrics.contains(.cost30d) ? Self.exactSignatureValue(costs.last30DaysUSD) : "unused")",
        ].joined(separator: ",")
    }

    private func storedMenuBarLayoutBalanceSignature(
        for provider: UsageProvider,
        snapshot: UsageSnapshot?)
        -> String?
    {
        let resolution = self.settings.menuBarLayoutResolution(for: provider)
        guard !resolution.usesLegacyRendering else { return nil }
        let showsBalance = resolution.layout
            .flattenedTokens(conditionals: self.settings.menuBarLayoutConditionals)
            .contains(.balance)
            || self.referencedConditionalMetrics(resolution: resolution).contains(.balance)
        guard showsBalance else { return nil }
        // The rendered text only carries the remaining row. A `balance used` predicate reads the "Used"
        // row instead, which no display token surfaces, so sign both amounts exactly.
        let amounts = MenuBarLayoutBalanceResolver.balanceAmountsUSD(provider: provider, snapshot: snapshot)
        return [
            "text=\(MenuBarLayoutBalanceResolver.balance(provider: provider, snapshot: snapshot) ?? "nil")",
            "remaining=\(Self.exactSignatureValue(amounts.remaining))",
            "used=\(Self.exactSignatureValue(amounts.used))",
        ].joined(separator: ",")
    }

    /// Pace tokens change with the historical dataset, the work-day setting, and the clock — none of
    /// which move the percent fields above. Without this contribution a `historicalPaceRevision` bump
    /// wakes the observer but leaves the signature unchanged, so a custom pace token would keep its
    /// stale value until an unrelated icon change forces a redraw.
    ///
    /// Conditional predicates on pace and run-out have the same dependency with no token to detect, so
    /// they widen the window set and contribute the run-out estimate itself: `runsOutMinutes` moves at
    /// minute granularity while the pace text only moves at whole-percent granularity.
    private func storedMenuBarLayoutPaceSignature(
        for provider: UsageProvider,
        snapshot: UsageSnapshot?)
        -> String?
    {
        let resolution = self.settings.menuBarLayoutResolution(for: provider)
        guard !resolution.usesLegacyRendering else { return nil }

        let metrics = self.referencedConditionalMetrics(resolution: resolution)
        var paceWindows = Set(resolution.layout
            .flattenedTokens(conditionals: self.settings.menuBarLayoutConditionals)
            .compactMap { token -> PercentWindow? in
                guard case let .pace(window) = token else { return nil }
                return window
            })
        if metrics.contains(.sessionPace) {
            paceWindows.insert(.session)
        }
        if metrics.contains(.weeklyPace) {
            paceWindows.insert(.weekly)
        }
        if metrics.contains(.automaticPace) {
            paceWindows.insert(.automatic)
        }
        let needsRunsOut = metrics.contains(.runsOutIn)
        guard !paceWindows.isEmpty || needsRunsOut else { return nil }

        let now = Date()
        let windows = self.menuBarLayoutWindows(provider: provider, snapshot: snapshot, now: now)
        var components = PercentWindow.allCases
            .filter(paceWindows.contains)
            .map { percentWindow in
                let window: RateWindow? = switch percentWindow {
                case .session: windows.session
                case .weekly: windows.weekly
                case .scopedWeekly: nil
                case .automatic: windows.automatic
                }
                let pace = self.store.menuBarLayoutPaceText(
                    provider: provider,
                    window: window,
                    dataConfidence: snapshot?.dataConfidence ?? .unknown,
                    now: now,
                    minimumElapsedPercent: percentWindow == .weekly ? 1 : nil)
                return "\(percentWindow.rawValue)=\(pace ?? "nil")"
            }
        if needsRunsOut {
            let runsOutMinutes = (windows.weekly ?? windows.automatic)
                .flatMap { self.store.weeklyPace(
                    provider: provider,
                    window: $0,
                    dataConfidence: snapshot?.dataConfidence ?? .unknown,
                    now: now) }
                .flatMap(\.etaSeconds)
                .map { Int(($0 / 60).rounded()) }
            components.append("runsOut=\(runsOutMinutes.map { String($0) } ?? "nil")")
        }
        return components.joined(separator: ",")
    }

    /// Direct lane tokens read `snapshot.tertiary` independently of the legacy icon percent
    /// resolver. Without this contribution a Third Party (or equivalent) lane can move while the
    /// observation signature stays put, so the custom token keeps a stale percent until an
    /// unrelated icon change forces a redraw.
    ///
    /// This covers what the layout *renders*, so it signs the displayed reading.
    /// `storedMenuBarLayoutConditionalWindowSignature` covers what conditionals *read*.
    private func storedMenuBarLayoutLaneSignature(
        for provider: UsageProvider,
        snapshot: UsageSnapshot?)
        -> String?
    {
        let resolution = self.settings.menuBarLayoutResolution(for: provider)
        guard !resolution.usesLegacyRendering else { return nil }

        // `selectedLanes` never walks conditional branches, so read the flattened tokens instead: a
        // `lanePercent` inside a then/else branch renders and must be signed like any placed token.
        let lanes = Set(resolution.layout
            .flattenedTokens(conditionals: self.settings.menuBarLayoutConditionals)
            .compactMap(\.selectedLane))
        guard !lanes.isEmpty else { return nil }

        let windows = self.menuBarLayoutWindows(provider: provider, snapshot: snapshot, now: Date())
        let showUsed = self.settings.usageBarsShowUsed
        return MenuBarLayoutLane.allCases
            .filter(lanes.contains)
            .map { lane in
                let percent = showUsed
                    ? Self.laneWindow(lane, in: windows)?.usedPercent
                    : Self.laneWindow(lane, in: windows)?.remainingPercent
                return "\(lane.rawValue)=\(Self.iconSignatureValue(percent))"
            }
            .joined(separator: ",")
    }

    /// Window readings conditional predicates depend on but no display token exposes.
    ///
    /// The rendered percent follows `usageBarsShowUsed` and `remainingPercent` clamps at zero, while
    /// `RateWindow.usedPercent` deliberately preserves raw over-quota values — so a used-direction
    /// predicate such as `primaryLane > 105%` can flip from 104% to 106% while the displayed reading
    /// stays pinned at `0.000`. Countdown predicates depend on `resetsAt`, which no token contributes at
    /// all. Signing the raw used percent covers both directions, since remaining is derived from it.
    private func storedMenuBarLayoutConditionalWindowSignature(
        for provider: UsageProvider,
        snapshot: UsageSnapshot?)
        -> String?
    {
        let resolution = self.settings.menuBarLayoutResolution(for: provider)
        guard !resolution.usesLegacyRendering else { return nil }
        let metrics = self.referencedConditionalMetrics(resolution: resolution)
            .filter(\.readsRateWindow)
        guard !metrics.isEmpty else { return nil }

        let windows = self.menuBarLayoutWindows(provider: provider, snapshot: snapshot, now: Date())
        let scopedWeekly = MenuBarLayoutSemanticWindowResolver
            .scopedWeeklyNamedWindow(snapshot: snapshot)?.window
        return MenuBarConditionalMetric.allCases
            .filter(metrics.contains)
            .map { metric in
                let window: RateWindow? = switch metric {
                case .session, .sessionResetsIn: windows.session
                case .weekly, .weeklyResetsIn: windows.weekly
                case .scopedWeekly, .scopedWeeklyResetsIn: scopedWeekly
                case .automatic, .automaticResetsIn: windows.automatic
                case .primaryLane: windows.primary
                case .secondaryLane: windows.secondary
                case .tertiaryLane: windows.tertiary
                default: nil
                }
                let resetsAt = window?.resetsAt?.timeIntervalSince1970
                return "\(metric.rawValue)=\(Self.iconSignatureValue(window?.usedPercent))" +
                    "@\(Self.exactSignatureValue(resetsAt))"
            }
            .joined(separator: ",")
    }

    private static func laneWindow(_ lane: MenuBarLayoutLane, in windows: MenuBarLayoutWindows) -> RateWindow? {
        switch lane {
        case .primary: windows.primary
        case .secondary: windows.secondary
        case .tertiary: windows.tertiary
        }
    }

    /// Lossless signature component. `iconSignatureValue` rounds to three decimals, which is right for a
    /// rendered percentage but can hide a threshold crossing in an unrounded currency amount or an
    /// epoch timestamp.
    private static func exactSignatureValue(_ value: Double?) -> String {
        guard let value else { return "nil" }
        return String(value.bitPattern)
    }
}
