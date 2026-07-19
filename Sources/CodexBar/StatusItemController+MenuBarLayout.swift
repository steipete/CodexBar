import AppKit
import CodexBarCore
import Foundation

extension StatusItemController {
    func applyStoredMenuBarLayoutIfNeeded(
        provider: UsageProvider,
        snapshot: UsageSnapshot?,
        icon: NSImage?,
        warningFlash: Bool,
        statusItem: NSStatusItem,
        now: Date = .init())
        -> Bool?
    {
        let resolution = self.settings.menuBarLayoutResolution(for: provider)
        guard !resolution.usesLegacyRendering,
              self.settings.menuBarIconStyle == .iconAndPercent,
              let button = statusItem.button
        else {
            statusItem.length = NSStatusItem.variableLength
            return nil
        }

        let renderedIcon = icon.map { warningFlash ? Self.quotaWarningFlashImage(base: $0) : $0 }
        let data = self.menuBarLayoutRenderData(
            provider: provider,
            snapshot: snapshot,
            warningFlash: warningFlash,
            now: now)
        let minute = Date(timeIntervalSince1970: floor(now.timeIntervalSince1970 / 60) * 60)
        let appearanceName = button.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua])?.rawValue ?? "default"
        let options = MenuBarLayoutRenderOptions(
            size: self.settings.menuBarLayoutSize,
            highContrast: self.shouldUseHighContrastStatusItemContent,
            showUsed: self.settings.usageBarsShowUsed,
            appearanceName: appearanceName,
            isDebugApp: Self.isDebugApp(bundleIdentifier: Bundle.main.bundleIdentifier),
            now: minute)
        let rendered = self.menuBarLayoutRenderer.render(
            layout: resolution.layout,
            data: data,
            icon: renderedIcon,
            options: options)
        let wasCached = button.image == nil
            && button.imagePosition == .noImage
            && button.attributedTitle.isEqual(to: rendered.attributedTitle)
        self.setButtonLayoutContent(rendered, for: button, statusItem: statusItem)
        return wasCached
    }

    func menuBarLayoutRenderData(
        provider: UsageProvider,
        snapshot: UsageSnapshot?,
        warningFlash: Bool,
        now: Date = .init())
        -> MenuBarLayoutRenderData
    {
        let windows = self.menuBarLayoutWindows(provider: provider, snapshot: snapshot, now: now)
        let paceWindow = windows.weekly ?? windows.automatic
        let runsOut = paceWindow
            .flatMap { self.store.weeklyPace(provider: provider, window: $0, now: now) }
            .flatMap { UsagePaceText.weeklyDetail(provider: provider, pace: $0, now: now).rightLabel }
        let costStrings = self.menuBarLayoutCostStrings(provider: provider, now: now)
        let providerName = L(self.store.metadata(for: provider).displayName)
        let rawAccountLabel = snapshot?.accountEmail(for: provider)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let accountLabel = self.settings.hidePersonalInfo || rawAccountLabel?.isEmpty != false
            ? nil
            : rawAccountLabel

        return MenuBarLayoutRenderData(
            iconKey: "\(provider.rawValue):\(warningFlash ? "warning" : "normal")",
            providerName: providerName,
            accountLabel: accountLabel,
            session: MenuBarLayoutRenderWindow(windows.session),
            weekly: MenuBarLayoutRenderWindow(windows.weekly),
            automatic: MenuBarLayoutRenderWindow(windows.automatic),
            runsOut: runsOut,
            costToday: costStrings.today,
            cost30d: costStrings.last30Days)
    }

    func menuBarLayoutCostStrings(
        provider: UsageProvider,
        now: Date = .init())
        -> (today: String?, last30Days: String?)
    {
        let snapshot = self.store.tokenSnapshotForCurrentProviderConfig(for: provider)?.snapshot
        let currencyCode = snapshot?.currencyCode ?? "USD"
        let today = MenuBarLayoutCostResolver.todayCostUSD(snapshot: snapshot, now: now).map {
            UsageFormatter.currencyString($0, currencyCode: currencyCode)
        }
        let last30Days = snapshot?.last30DaysCostUSD.map {
            UsageFormatter.currencyString($0, currencyCode: currencyCode)
        }
        return (today, last30Days)
    }

    func menuBarLayoutWindows(
        provider: UsageProvider,
        snapshot: UsageSnapshot?,
        now: Date)
        -> (session: RateWindow?, weekly: RateWindow?, automatic: RateWindow?)
    {
        if provider == .codex,
           let projection = self.store.codexConsumerProjectionIfNeeded(
               for: provider,
               surface: .menuBar,
               snapshotOverride: snapshot,
               now: now)
        {
            let session = projection.menuBarSelectableRateWindow(for: .session)
            let weekly = projection.menuBarSelectableRateWindow(for: .weekly)
            let automatic = projection.visibleRateLanes
                .lazy
                .compactMap { projection.menuBarSelectableRateWindow(for: $0) }
                .first
            return (session, weekly, automatic)
        }

        let semanticWindows = MenuBarLayoutSemanticWindowResolver.windows(
            provider: provider,
            snapshot: snapshot)
        let automatic = MenuBarMetricWindowResolver.rateWindow(
            preference: .automatic,
            provider: provider,
            snapshot: snapshot,
            supportsAverage: self.settings.menuBarMetricSupportsAverage(for: provider),
            antigravityPrioritizeExhaustedQuotas: self.settings.antigravityPrioritizeExhaustedQuotas,
            now: now)
        return (semanticWindows.session, semanticWindows.weekly, automatic)
    }

    private func setButtonLayoutContent(
        _ rendered: MenuBarLayoutRenderedTitle,
        for button: NSStatusBarButton,
        statusItem: NSStatusItem)
    {
        button.image = nil
        button.imagePosition = .noImage
        if !button.attributedTitle.isEqual(to: rendered.attributedTitle) {
            button.attributedTitle = rendered.attributedTitle
        }
        if button.accessibilityTitle() != rendered.accessibilityLabel {
            button.setAccessibilityTitle(rendered.accessibilityLabel)
        }

        // AppKit exposes no content-inset API on NSStatusBarButton. Explicit item length is the actual
        // status-item padding mechanism: tight removes most edge space; regular keeps the native breathing room.
        let bounds = rendered.attributedTitle.boundingRect(
            with: NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading])
        let horizontalPadding: CGFloat = self.settings.menuBarLayoutGap == .tight ? 3 : 10
        statusItem.length = max(18, ceil(bounds.width) + horizontalPadding)
    }
}
