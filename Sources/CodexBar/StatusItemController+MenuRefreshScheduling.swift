import AppKit
import CodexBarCore
import QuartzCore

extension StatusItemController {
    private static let providerSwitcherMenuRebuildDebounceNanoseconds: UInt64 = 45_000_000

    func didMenuAdjunctReadinessChange() -> Bool {
        let signature = self.menuAdjunctReadinessSignature()
        defer { self.lastMenuAdjunctReadinessSignature = signature }
        return signature != self.lastMenuAdjunctReadinessSignature
    }

    func menuAdjunctReadinessSignature() -> String {
        let dashboard = self.store.openAIDashboard
        let dashboardUsageBreakdown = OpenAIDashboardDailyBreakdown.removingSkillUsageServices(
            from: dashboard?.usageBreakdown ?? [])
        var parts = [
            "costEnabled=\(self.settings.costUsageEnabled ? "1" : "0")",
            "openAIAttached=\(self.store.openAIDashboardAttachmentAuthorized ? "1" : "0")",
            "openAILogin=\(self.store.openAIDashboardRequiresLogin ? "1" : "0")",
            "openAIUpdated=\(Self.millisecondsSinceEpoch(dashboard?.updatedAt))",
            "openAIDaily=\(Self.dashboardBreakdownReadinessSignature(dashboard?.dailyBreakdown ?? []))",
            "openAIUsage=\(Self.dashboardBreakdownReadinessSignature(dashboardUsageBreakdown))",
            "credits=\(self.store.credits == nil ? "0" : "1")",
            "planHistoryRevision=\(self.store.planUtilizationHistoryRevision)",
        ]

        for provider in self.store.enabledProvidersForDisplay() {
            let tokenSignature = self.tokenSnapshotReadinessSignature(for: provider)
            let usageHistoryVisible = self.store.supportsPlanUtilizationHistory(for: provider) &&
                !self.store.shouldHidePlanUtilizationMenuItem(for: provider)
            parts.append(
                [
                    provider.rawValue,
                    "token=\(tokenSignature)",
                    "usageHistory=\(usageHistoryVisible ? "1" : "0")",
                ].joined(separator: ":"))
        }

        return parts.joined(separator: "|")
    }

    private static func dashboardBreakdownReadinessSignature(
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
        return [
            "sessionTokens=\(snapshot.sessionTokens ?? -1)",
            "sessionCost=\(Self.formatOptionalDoubleForSignature(snapshot.sessionCostUSD))",
            "lastTokens=\(snapshot.last30DaysTokens ?? -1)",
            "lastCost=\(Self.formatOptionalDoubleForSignature(snapshot.last30DaysCostUSD))",
            "updated=\(Int(snapshot.updatedAt.timeIntervalSince1970 * 1000))",
            "daily=\(daily)",
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

    private static func formatDoubleForSignature(_ value: Double) -> String {
        String(format: "%.8f", value)
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

    func scheduleOpenMenuRebuildIfStillVisible(
        _ menu: NSMenu,
        provider: UsageProvider?,
        closeHostedSubviewMenusBeforeRebuild: Bool = false,
        debounceNanoseconds: UInt64 = 0,
        beforeRebuild: (@MainActor () -> Bool)? = nil)
    {
        let key = ObjectIdentifier(menu)
        if closeHostedSubviewMenusBeforeRebuild {
            self.openMenuRebuildsClosingHostedSubviewMenus.insert(key)
        }
        let shouldCloseHostedSubviewMenus = self.openMenuRebuildsClosingHostedSubviewMenus.contains(key)
        self.openMenuRebuildTokenCounter &+= 1
        let rebuildToken = self.openMenuRebuildTokenCounter
        self.openMenuRebuildTokens[key] = rebuildToken
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
            guard self.openMenuRebuildTokens[key] == rebuildToken else { return }
            defer {
                if self.openMenuRebuildTokens[key] == rebuildToken {
                    self.openMenuRebuildTasks.removeValue(forKey: key)
                    self.openMenuRebuildTokens.removeValue(forKey: key)
                    self.openMenuRebuildsClosingHostedSubviewMenus.remove(key)
                }
            }
            guard self.openMenus[key] != nil else { return }
            guard beforeRebuild?() ?? true else { return }
            if shouldCloseHostedSubviewMenus {
                self.closeHostedSubviewMenusForParentSwitch()
            }
            self.rebuildOpenMenuIfStillVisible(menu, provider: provider)
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
