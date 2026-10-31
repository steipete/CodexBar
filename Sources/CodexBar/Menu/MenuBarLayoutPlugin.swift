import AppKit
import CodexBarCore

extension MenuBarLayoutRenderData {
    static func plugin(
        instanceID: ProviderInstanceID,
        name: String,
        snapshot: UsageSnapshot?,
        iconKey: String,
        hidePersonalInfo: Bool) -> Self
    {
        let primary = MenuBarLayoutRenderWindow(snapshot?.primary)
        let secondary = MenuBarLayoutRenderWindow(snapshot?.secondary)
        return Self(
            provider: instanceID,
            quotaIsEstimated: snapshot?.dataConfidence == .estimated,
            iconKey: iconKey,
            providerName: name,
            accountLabel: hidePersonalInfo || snapshot?.identity?.providerID != instanceID
                ? nil : snapshot?.identity?.accountEmail,
            laneLabels: MenuBarLayoutLaneLabels(pluginSnapshot: snapshot),
            primary: primary,
            secondary: secondary,
            tertiary: MenuBarLayoutRenderWindow(snapshot?.tertiary),
            extraRateWindows: (snapshot?.extraRateWindows ?? []).map(MenuBarLayoutRenderExtra.init),
            session: primary,
            weekly: secondary,
            scopedWeekly: nil,
            scopedWeeklyTitle: nil,
            automatic: MenuBarLayoutRenderWindow(StatusItemController.pluginMetricWindow(snapshot: snapshot)),
            automaticText: nil,
            sessionPace: nil,
            weeklyPace: nil,
            automaticPace: nil,
            runsOut: nil,
            balance: nil,
            tokensPerMinute: snapshot?.throughput?.latestTokensPerMinute,
            tokensSparkline: snapshot?.throughput.map { MenuBarTokensSparkline(minutes: $0.minutes) },
            costToday: nil,
            cost30d: nil,
            metrics: .unavailable)
    }
}

extension StatusItemController {
    func renderedMenuBarLayoutResolution(forInstanceID instanceID: ProviderInstanceID) -> MenuBarLayoutResolution {
        if let provider = instanceID.firstPartyProvider {
            return self.renderedMenuBarLayoutResolution(for: provider)
        }
        return .stored(self.settings.menuBarLayout(forPlugin: instanceID))
    }

    func menuBarLayoutRenderData(for instanceID: ProviderInstanceID, now: Date) -> MenuBarLayoutRenderData {
        if let provider = instanceID.firstPartyProvider {
            return self.menuBarLayoutRenderData(
                provider: provider,
                snapshot: self.menuBarUsageSource(for: provider).snapshot,
                warningFlash: self.quotaWarningFlashActive(provider: provider),
                now: now)
        }
        let plugin = UserProviderPluginRegistry.plugin(for: instanceID)
        let snapshot = self.store.menuBarSnapshot(for: instanceID)
        return .plugin(
            instanceID: instanceID,
            name: plugin?.manifest.name ?? instanceID.rawValue,
            snapshot: snapshot,
            iconKey: "\(plugin?.sourceHash ?? instanceID.rawValue):\(snapshot?.iconProvider?.rawValue ?? "")",
            hidePersonalInfo: self.settings.hidePersonalInfo)
    }

    func applyPluginMenuBarLayout(instanceID: ProviderInstanceID, icon: NSImage, now: Date = .init()) -> Bool? {
        guard self.settings.menuBarIconStyle == .iconAndPercent, let button = self.statusItem.button else { return nil }
        let data = self.menuBarLayoutRenderData(for: instanceID, now: now)
        let rendered = self.menuBarLayoutRenderer.render(
            layout: self.renderedMenuBarLayoutResolution(forInstanceID: instanceID).layout,
            data: data,
            icon: icon,
            options: self.menuBarLayoutRenderOptions(forInstanceID: instanceID, button: button, now: now))
        self.lastAppliedMergedIconRenderSignature = nil
        self.statusItem.length = Self.applyMenuBarLayoutContent(
            rendered,
            for: button,
            gap: self.settings.menuBarLayoutGap)
        return false
    }
}

extension MenuBarLayoutLaneLabels {
    init(pluginSnapshot: UsageSnapshot?) {
        self.primary = pluginSnapshot?.primary?.title ?? L("Primary")
        self.secondary = pluginSnapshot?.secondary?.title ?? L("Secondary")
        self.tertiary = pluginSnapshot?.tertiary?.title ?? L("Tertiary")
    }
}
