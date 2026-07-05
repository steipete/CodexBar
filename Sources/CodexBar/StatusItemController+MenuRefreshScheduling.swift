import AppKit
import CodexBarCore
import QuartzCore

extension StatusItemController {
    private static let providerSwitcherMenuRebuildDebounceNanoseconds: UInt64 = 0

    private struct ScheduledOpenMenuRebuild {
        let provider: UsageProvider?
        let shouldCloseHostedSubviewMenus: Bool
        let resyncReadinessBaselineAfterRebuild: Bool
        let beforeRebuild: (@MainActor () -> Bool)?
    }

    func didMenuAdjunctReadinessChange() -> Bool {
        let signature = self.menuAdjunctReadinessSignature()
        defer { self.recordMenuAdjunctReadinessBaseline(signature) }
        return signature != self.lastMenuAdjunctReadinessSignature
    }

    /// Resyncs the readiness baseline to the data the menu was just built from.
    ///
    /// Because the baseline is no longer recomputed on every store change while all menus are closed,
    /// it can drift from the live store state. When a root menu opens and is actually rebuilt (or is
    /// already fresh for the current `menuContentVersion`), the baseline must be re-anchored here;
    /// otherwise a later open-menu store change that happens to revert to the stale baseline value would
    /// be treated as "unchanged" and skip a needed rebuild, leaving the visible menu showing the older
    /// content. Callers must **not** invoke this when `refreshMenuForOpenIfNeeded` preserved stale
    /// content during an in-flight refresh — that would record live store data while the visible menu
    /// still shows older content and mask the refresh-completion update.
    func resyncMenuAdjunctReadinessBaseline() {
        self.recordMenuAdjunctReadinessBaseline(self.menuAdjunctReadinessSignature())
    }

    /// Resyncs a root-menu baseline after open and handles the narrow race where a store change
    /// has updated live data but its deferred observation task has not invalidated menus yet.
    ///
    /// If a previously fresh menu sees new live data before the observer version tick, invalidate all
    /// menus first and rebuild only the opened menu. The matching observer can then skip the expensive
    /// readiness comparison while still invalidating menu-observed state that is not in the signature.
    func resyncMenuAdjunctReadinessBaselineForRootOpen(
        _ menu: NSMenu,
        provider: UsageProvider?,
        menuWasFreshBeforeOpen: Bool)
    {
        let signature = self.menuAdjunctReadinessSignature()
        let menuKey = ObjectIdentifier(menu)
        let menuRenderedCurrentSignature =
            self.menuSession.renderedVersion(for: menuKey) == self.menuSession.contentVersion &&
            self.menuReadinessSignatures[menuKey] == signature
        guard signature != self.lastMenuAdjunctReadinessSignature else {
            guard menuWasFreshBeforeOpen, !menuRenderedCurrentSignature else {
                self.lastMenuAdjunctReadinessBaselineVersion = self.menuSession.contentVersion
                return
            }
            guard !self.isMenuDataRefreshInFlight else { return }
            self.invalidateMenus()
            self.populateMenu(menu, provider: provider)
            self.markMenuFresh(menu)
            self.rememberRootOpenHandledMenuObservation(signature: signature)
            self.recordMenuAdjunctReadinessBaseline(signature)
            return
        }

        if menuWasFreshBeforeOpen {
            if self.isMenuDataRefreshInFlight, !menuRenderedCurrentSignature {
                return
            }
            if menuRenderedCurrentSignature {
                self.recordMenuAdjunctReadinessBaseline(signature)
                return
            }
            self.invalidateMenus()
            self.populateMenu(menu, provider: provider)
            self.markMenuFresh(menu)
            self.rememberRootOpenHandledMenuObservation(signature: signature)
        }
        self.recordMenuAdjunctReadinessBaseline(signature)
    }

    private func recordMenuAdjunctReadinessBaseline(_ signature: String) {
        self.lastMenuAdjunctReadinessSignature = signature
        self.lastMenuAdjunctReadinessBaselineVersion = self.menuSession.contentVersion
    }

    private func rememberRootOpenHandledMenuObservation(signature: String) {
        self.rootOpenHandledMenuObservationSignature = signature
        Task { @MainActor [weak self] in
            await Task.yield()
            if self?.rootOpenHandledMenuObservationSignature == signature {
                self?.rootOpenHandledMenuObservationSignature = nil
            }
        }
    }

    func consumeRootOpenHandledMenuObservationIfNeeded() -> Bool {
        guard let handledSignature = self.rootOpenHandledMenuObservationSignature else { return false }
        let signature = self.menuAdjunctReadinessSignature()
        guard signature == handledSignature else {
            self.rootOpenHandledMenuObservationSignature = nil
            return false
        }
        self.rootOpenHandledMenuObservationSignature = nil
        self.recordMenuAdjunctReadinessBaseline(signature)
        return true
    }

    func menuAdjunctReadinessSignature() -> String {
        let dashboard = self.store.openAIDashboard
        let dashboardUsageBreakdown = OpenAIDashboardDailyBreakdown.removingSkillUsageServices(
            from: dashboard?.usageBreakdown ?? [])
        var parts = [
            "costEnabled=\(self.settings.costUsageEnabled ? "1" : "0")",
            "costStyle=\(self.settings.costSummaryDisplayStyle.rawValue)",
            "openAIAttached=\(self.store.openAIDashboardAttachmentAuthorized ? "1" : "0")",
            "openAILogin=\(self.store.openAIDashboardRequiresLogin ? "1" : "0")",
            "openAIUpdated=\(Self.millisecondsSinceEpoch(dashboard?.updatedAt))",
            "openAIDaily=\(Self.dashboardBreakdownReadinessSignature(dashboard?.dailyBreakdown ?? []))",
            "openAIUsage=\(Self.dashboardBreakdownReadinessSignature(dashboardUsageBreakdown))",
            "credits=\(self.store.credits == nil ? "0" : "1")",
            "planHistoryRevision=\(self.store.planUtilizationHistoryRevision)",
            "claudeSwapRevision=\(self.store.claudeSwapRevision)",
        ]

        for provider in self.store.enabledProvidersForDisplay() {
            let tokenSignature = self.tokenSnapshotReadinessSignature(for: provider)
            let usageHistoryVisible = self.store.supportsPlanUtilizationHistory(for: provider) &&
                !self.store.shouldHidePlanUtilizationMenuItem(for: provider)
            parts.append(
                [
                    provider.rawValue,
                    "token=\(tokenSignature)",
                    "statusComponents=\(self.statusComponentsRenderSignature(for: provider))",
                    "refreshing=\(self.store.shouldShowRefreshingMenuCardIndicator(for: provider) ? "1" : "0")",
                    "usageHistory=\(usageHistoryVisible ? "1" : "0")",
                ].joined(separator: ":"))
        }

        return parts.joined(separator: "|")
    }

    static func dashboardBreakdownReadinessSignature(
        _ breakdown: [OpenAIDashboardDailyBreakdown]) -> String
    {
        breakdown
            .map { day in
                let services = day.services
                    .map { "\($0.service)=\(Self.formatDoubleForSignature($0.creditsUsed))" }
                    .joined(separator: ",")
                return [
                    day.day,
                    Self.formatDoubleForSignature(day.totalCreditsUsed),
                    services,
                ].joined(separator: ":")
            }
            .joined(separator: ";")
    }

    private func tokenSnapshotReadinessSignature(for provider: UsageProvider) -> String {
        guard let snapshot = self.store.tokenSnapshot(for: provider) else { return "none" }
        let daily = snapshot.daily
            .map { entry in
                [
                    entry.date,
                    "\(entry.totalTokens ?? -1)",
                    Self.formatOptionalDoubleForSignature(entry.costUSD),
                ].joined(separator: ",")
            }
            .joined(separator: ";")
        let projects = snapshot.projects
            .map { project in
                let sources = project.sources
                    .map { source in
                        [
                            source.name,
                            source.path ?? "",
                            "\(source.totalTokens ?? -1)",
                            Self.formatOptionalDoubleForSignature(source.totalCostUSD),
                        ].joined(separator: ",")
                    }
                    .joined(separator: "|")
                return [
                    project.name,
                    project.path ?? "",
                    "\(project.totalTokens ?? -1)",
                    Self.formatOptionalDoubleForSignature(project.totalCostUSD),
                    sources,
                ].joined(separator: ",")
            }
            .joined(separator: ";")
        return [
            "sessionTokens=\(snapshot.sessionTokens ?? -1)",
            "sessionCost=\(Self.formatOptionalDoubleForSignature(snapshot.sessionCostUSD))",
            "lastTokens=\(snapshot.last30DaysTokens ?? -1)",
            "lastCost=\(Self.formatOptionalDoubleForSignature(snapshot.last30DaysCostUSD))",
            "updated=\(Int(snapshot.updatedAt.timeIntervalSince1970 * 1000))",
            "daily=\(daily)",
            "projects=\(projects)",
        ].joined(separator: ",")
    }

    private static func millisecondsSinceEpoch(_ date: Date?) -> Int {
        guard let date else { return -1 }
        return Int(date.timeIntervalSince1970 * 1000)
    }

    private static func formatOptionalDoubleForSignature(_ value: Double?) -> String {
        guard let value else { return "nil" }
        return self.formatDoubleForSignature(value)
    }

    /// The signature is only ever compared for equality against the previous signature, so it does
    /// not need a human-readable decimal form. `String(format: "%.8f", …)` is a surprisingly hot
    /// cost here because it runs for every daily/service value across every enabled provider on each
    /// store mutation. The raw bit pattern is both exact (no rounding collisions) and far cheaper.
    private static func formatDoubleForSignature(_ value: Double) -> String {
        String(value.bitPattern, radix: 16)
    }

    func performMenuMutationWithoutAnimation(_ updates: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        updates()
    }

    func deferSwitcherMenuRebuildIfStillVisible(_ menu: NSMenu, provider: UsageProvider?) {
        self.providerSwitcherUpdateToken &+= 1
        let updateToken = self.providerSwitcherUpdateToken
        #if DEBUG
        let debounceNanoseconds = self._test_providerSwitcherMenuRebuildDebounceNanoseconds ?? (
            self._test_openMenuRebuildObserver == nil ? Self.providerSwitcherMenuRebuildDebounceNanoseconds : 0)
        #else
        let debounceNanoseconds = Self.providerSwitcherMenuRebuildDebounceNanoseconds
        #endif
        #if DEBUG
        let usesTaskSchedulerForTesting = self._test_openMenuRefreshYieldOverride != nil
            || self._test_openMenuRebuildObserver != nil
        #else
        let usesTaskSchedulerForTesting = false
        #endif
        if debounceNanoseconds == 0, !usesTaskSchedulerForTesting {
            self.scheduleProviderSwitcherTrackingMenuRebuildIfStillVisible(
                menu,
                provider: provider)
            { [weak self] in
                guard let self else { return false }
                return self.providerSwitcherUpdateToken == updateToken
            }
            return
        }
        self.scheduleOpenMenuRebuildIfStillVisible(
            menu,
            provider: provider,
            closeHostedSubviewMenusBeforeRebuild: true,
            debounceNanoseconds: debounceNanoseconds)
        { [weak self] in
            guard let self else { return false }
            return self.providerSwitcherUpdateToken == updateToken
        }
    }

    private func scheduleProviderSwitcherTrackingMenuRebuildIfStillVisible(
        _ menu: NSMenu,
        provider: UsageProvider?,
        beforeRebuild: @escaping @MainActor () -> Bool)
    {
        let key = ObjectIdentifier(menu)
        self.openMenuRebuildsClosingHostedSubviewMenus.insert(key)
        let rebuildToken = self.openMenuRebuildRequests.replaceRequest(for: key)
        self.openMenuRebuildTasks.removeValue(forKey: key)?.cancel()

        ProviderSwitcherTrackingRunLoopScheduler.schedule { [weak self, weak menu] in
            guard let self, let menu else { return }
            self.performScheduledOpenMenuRebuild(
                menu,
                key: key,
                rebuildToken: rebuildToken,
                request: ScheduledOpenMenuRebuild(
                    provider: provider,
                    shouldCloseHostedSubviewMenus: true,
                    resyncReadinessBaselineAfterRebuild: false,
                    beforeRebuild: beforeRebuild))
        }
    }

    func scheduleOpenMenuRebuildIfStillVisible(
        _ menu: NSMenu,
        provider: UsageProvider?,
        closeHostedSubviewMenusBeforeRebuild: Bool = false,
        resyncReadinessBaselineAfterRebuild: Bool = false,
        debounceNanoseconds: UInt64 = 0,
        beforeRebuild: (@MainActor () -> Bool)? = nil)
    {
        let key = ObjectIdentifier(menu)
        if closeHostedSubviewMenusBeforeRebuild {
            self.openMenuRebuildsClosingHostedSubviewMenus.insert(key)
        }
        let shouldCloseHostedSubviewMenus = self.openMenuRebuildsClosingHostedSubviewMenus.contains(key)
        let rebuildToken = self.openMenuRebuildRequests.replaceRequest(for: key)
        self.openMenuRebuildTasks[key]?.cancel()
        self.openMenuRebuildTasks[key] = Task { @MainActor [weak self, weak menu] in
            guard let self, let menu else { return }
            #if DEBUG
            if let override = self._test_openMenuRefreshYieldOverride {
                await override()
            } else {
                await Task.yield()
            }
            #else
            await Task.yield()
            #endif
            if debounceNanoseconds > 0 {
                try? await Task.sleep(nanoseconds: debounceNanoseconds)
            }
            guard !Task.isCancelled else { return }
            self.performScheduledOpenMenuRebuild(
                menu,
                key: key,
                rebuildToken: rebuildToken,
                request: ScheduledOpenMenuRebuild(
                    provider: provider,
                    shouldCloseHostedSubviewMenus: shouldCloseHostedSubviewMenus,
                    resyncReadinessBaselineAfterRebuild: resyncReadinessBaselineAfterRebuild,
                    beforeRebuild: beforeRebuild))
        }
    }

    private func performScheduledOpenMenuRebuild(
        _ menu: NSMenu,
        key: ObjectIdentifier,
        rebuildToken: Int,
        request: ScheduledOpenMenuRebuild)
    {
        guard self.openMenuRebuildRequests.isCurrent(rebuildToken, for: key) else { return }
        defer {
            if self.openMenuRebuildRequests.finish(rebuildToken, for: key) {
                self.openMenuRebuildTasks.removeValue(forKey: key)
                self.openMenuRebuildsClosingHostedSubviewMenus.remove(key)
            }
        }
        guard self.openMenus[key] != nil else { return }
        guard request.beforeRebuild?() ?? true else { return }
        if request.shouldCloseHostedSubviewMenus {
            self.closeHostedSubviewMenusForParentSwitch()
        }
        self.rebuildOpenMenuIfStillVisible(menu, provider: request.provider)
        if request.resyncReadinessBaselineAfterRebuild, !self.menuNeedsRefresh(menu) {
            self.resyncMenuAdjunctReadinessBaseline()
        }
    }

    private func closeHostedSubviewMenusForParentSwitch() {
        let hostedMenus = self.openMenus.values.filter { self.isHostedSubviewMenu($0) }
        for hostedMenu in hostedMenus {
            hostedMenu.cancelTrackingWithoutAnimation()
            self.forgetClosedMenu(hostedMenu)
        }
    }
}
