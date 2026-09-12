import CodexBarCore

extension StatusItemController {
    func menuLocalizationSignature() -> String {
        let pluginSignature = self.topLevelUserProviderPlugins().map { plugin in
            [
                plugin.manifest.id.rawValue,
                plugin.manifest.name,
                plugin.manifest.icon.monogram,
                plugin.manifest.icon.tint,
            ].map { "\($0.utf8.count):\($0)" }.joined()
        }.joined()
        return [
            codexBarLocalizationSignature(),
            self.settings.hidePersonalInfo ? "hide-personal-info" : "show-personal-info",
            L("Overview"),
            L("Cost"),
            pluginSignature,
        ].joined(separator: "|")
    }

    func rememberMergedSwitcherState(_ providers: [UsageProvider], _ selection: ProviderSwitcherSelection?) {
        self.rememberMergedSwitcherState(
            providers,
            selection,
            self.includesOverviewTab(enabledProviders: providers))
    }

    func rememberMergedSwitcherState(
        _ providers: [UsageProvider],
        _ selection: ProviderSwitcherSelection?,
        _ includesOverview: Bool)
    {
        self.lastSwitcherProviders = self.switcherProviderIDs(enabledFirstPartyProviders: providers)
        self.lastSwitcherUsageBarsShowUsed = self.settings.usageBarsShowUsed
        self.lastMergedSwitcherSelection = selection
        self.lastMergedMenuContentSelection = selection
        self.lastSwitcherIncludesOverview = includesOverview
        self.lastMenuLocalizationSignature = self.menuLocalizationSignature()
    }
}
