import CodexBarCore

extension StatusItemController {
    func menuLocalizationSignature() -> String {
        [
            codexBarLocalizationSignature(),
            L("Overview"),
            L("Cost"),
        ].joined(separator: "|")
    }

    func rememberMergedSwitcherState(_ providers: [UsageProvider], _ selection: ProviderSwitcherSelection?) {
        self.rememberMergedSwitcherState(
            providers,
            selection,
            self.includesOverviewTab(for: providers))
    }

    func rememberMergedSwitcherState(
        _ providers: [UsageProvider],
        _ selection: ProviderSwitcherSelection?,
        _ includesOverview: Bool)
    {
        self.lastSwitcherProviders = providers
        self.lastSwitcherUsageBarsShowUsed = self.settings.usageBarsShowUsed
        self.lastMergedSwitcherSelection = selection
        self.lastSwitcherIncludesOverview = includesOverview
        self.lastMenuLocalizationSignature = self.menuLocalizationSignature()
    }

    private func includesOverviewTab(for providers: [UsageProvider]) -> Bool {
        !self.settings.resolvedMergedOverviewProviders(
            activeProviders: providers,
            maxVisibleProviders: SettingsStore.mergedOverviewProviderLimit).isEmpty
    }
}
