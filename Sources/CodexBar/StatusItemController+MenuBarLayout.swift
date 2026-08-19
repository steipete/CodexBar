import AppKit
import CodexBarCore
import Foundation

struct MenuBarLayoutWindows {
    let primary: RateWindow?
    let secondary: RateWindow?
    let tertiary: RateWindow?
    let session: RateWindow?
    let weekly: RateWindow?
    let automatic: RateWindow?
}

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
        let appearanceName = button.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua])?.rawValue ?? "default"
        let options = MenuBarLayoutRenderOptions(
            size: self.settings.menuBarLayoutSize,
            highContrast: self.shouldUseHighContrastStatusItemContent,
            showUsed: self.settings.usageBarsShowUsed,
            conditionals: self.settings.menuBarLayoutConditionals,
            appearanceName: appearanceName,
            isDebugApp: Self.isDebugApp(bundleIdentifier: Bundle.main.bundleIdentifier),
            isStale: self.store.isStale(provider: provider),
            now: now,
            verticalAdjustment: self.settings.menuBarLayoutVerticalAdjustment)
        let rendered = self.menuBarLayoutRenderer.render(
            layout: resolution.layout,
            data: data,
            icon: renderedIcon,
            options: options)
        let expectedImagePosition: NSControl.ImagePosition = if rendered.leadingIcon != nil {
            rendered.attributedTitle.length > 0 ? .imageLeft : .imageOnly
        } else {
            .noImage
        }
        let wasCached = button.image === rendered.leadingIcon
            && button.imagePosition == expectedImagePosition
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
        let scopedNamed = MenuBarLayoutSemanticWindowResolver.scopedWeeklyNamedWindow(snapshot: snapshot)
        let paceWindow = windows.weekly ?? windows.automatic
        let runsOut = paceWindow
            .flatMap {
                self.store.weeklyPace(
                    provider: provider,
                    window: $0,
                    now: now)
            }
            .flatMap { UsagePaceText.weeklyDetail(provider: provider, pace: $0, now: now).rightLabel }
        let costStrings = self.menuBarLayoutCostStrings(provider: provider, now: now)
        let providerName = L(self.store.metadata(for: provider).displayName)
        let accountLabel = self.menuBarLayoutAccountLabel(provider: provider, snapshot: snapshot)
        let automatic = MenuBarLayoutRenderWindow(windows.automatic)

        return MenuBarLayoutRenderData(
            provider: provider,
            iconKey: "\(provider.rawValue):\(warningFlash ? "warning" : "normal")",
            providerName: providerName,
            accountLabel: accountLabel,
            laneLabels: MenuBarLayoutLaneLabels(provider: provider, snapshot: snapshot),
            primary: MenuBarLayoutRenderWindow(windows.primary),
            secondary: MenuBarLayoutRenderWindow(windows.secondary),
            tertiary: MenuBarLayoutRenderWindow(windows.tertiary),
            session: MenuBarLayoutRenderWindow(windows.session),
            weekly: MenuBarLayoutRenderWindow(windows.weekly),
            scopedWeekly: MenuBarLayoutRenderWindow(scopedNamed?.window),
            scopedWeeklyTitle: scopedNamed?.title,
            automatic: automatic,
            // Provider-specific by design: Mistral uses spend text when its automatic lane has no percentage window.
            automaticText: provider == .mistral && automatic == nil
                ? Self.mistralSpendDisplayText(snapshot: snapshot)
                : nil,
            sessionPace: self.store.menuBarLayoutPaceText(
                provider: provider,
                window: windows.session,
                now: now),
            weeklyPace: self.store.menuBarLayoutPaceText(
                provider: provider,
                window: windows.weekly,
                now: now,
                minimumElapsedPercent: 1),
            automaticPace: self.store.menuBarLayoutPaceText(
                provider: provider,
                window: windows.automatic,
                now: now),
            runsOut: runsOut,
            balance: MenuBarLayoutBalanceResolver.balance(provider: provider, snapshot: snapshot),
            costToday: costStrings.today,
            cost30d: costStrings.last30Days)
    }

    func menuBarLayoutAccountLabel(provider: UsageProvider, snapshot: UsageSnapshot?) -> String? {
        let rawAccountLabel = snapshot?.accountEmail(for: provider)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return self.settings.hidePersonalInfo || rawAccountLabel?.isEmpty != false
            ? nil
            : rawAccountLabel
    }

    func menuBarLayoutCostStrings(
        provider: UsageProvider,
        now: Date = .init())
        -> (today: String?, last30Days: String?)
    {
        let snapshot = self.store.tokenSnapshotForCurrentProviderConfig(for: provider)?.snapshot
        let sourceCurrencyCode = snapshot?.currencyCode ?? "USD"
        let preferredCurrencyCode = self.settings.preferredCurrencyCode

        let today = MenuBarLayoutCostResolver.todayCostUSD(snapshot: snapshot, now: now).map {
            UsageFormatter.convertedCostString(
                $0,
                preferredCurrency: preferredCurrencyCode,
                providerCurrency: sourceCurrencyCode)
        }
        let last30Days = snapshot?.last30DaysCostUSD.map {
            UsageFormatter.convertedCostString(
                $0,
                preferredCurrency: preferredCurrencyCode,
                providerCurrency: sourceCurrencyCode)
        }
        return (today, last30Days)
    }

    func menuBarLayoutWindows(
        provider: UsageProvider,
        snapshot: UsageSnapshot?,
        now: Date)
        -> MenuBarLayoutWindows
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
            let automatic = projection.automaticMenuBarWindow()
            return MenuBarLayoutWindows(
                primary: session,
                secondary: weekly,
                tertiary: snapshot?.tertiary,
                session: session,
                weekly: weekly,
                automatic: automatic)
        }

        let semanticWindows = MenuBarLayoutSemanticWindowResolver.windows(
            provider: provider,
            snapshot: snapshot)
        // Provider-specific by design: Mistral's automatic lane can explicitly select its Monthly Plan window.
        let automaticPreference = provider == .mistral
            ? self.settings.menuBarMetricPreference(for: provider, snapshot: snapshot)
            : .automatic
        let automatic = MenuBarMetricWindowResolver.rateWindow(
            preference: automaticPreference,
            provider: provider,
            snapshot: snapshot,
            supportsAverage: self.settings.menuBarMetricSupportsAverage(for: provider),
            antigravityPrioritizeExhaustedQuotas: self.settings.antigravityPrioritizeExhaustedQuotas,
            now: now)
        return MenuBarLayoutWindows(
            primary: snapshot?.primary,
            secondary: snapshot?.secondary,
            tertiary: snapshot?.tertiary,
            session: semanticWindows.session,
            weekly: semanticWindows.weekly,
            automatic: MenuBarLayoutAutomaticWindowDisplayNormalizer.normalized(
                provider: provider,
                snapshot: snapshot,
                window: automatic))
    }

    private func setButtonLayoutContent(
        _ rendered: MenuBarLayoutRenderedTitle,
        for button: NSStatusBarButton,
        statusItem: NSStatusItem)
    {
        // A leading icon token is surfaced as the status item image so AppKit applies the
        // system's inactive-display tinting to it, matching how other menu bar icons behave.
        // Text tokens keep rendering through the attributed title.
        if let icon = rendered.leadingIcon {
            if button.image !== icon {
                button.image = icon
            }
            let position: NSControl.ImagePosition = rendered.attributedTitle.length > 0 ? .imageLeft : .imageOnly
            if button.imagePosition != position {
                button.imagePosition = position
            }
        } else {
            if button.image != nil {
                button.image = nil
            }
            if button.imagePosition != .noImage {
                button.imagePosition = .noImage
            }
        }
        if !button.attributedTitle.isEqual(to: rendered.attributedTitle) {
            button.attributedTitle = rendered.attributedTitle
        }
        if button.accessibilityTitle() != rendered.accessibilityLabel {
            button.setAccessibilityTitle(rendered.accessibilityLabel)
        }

        // AppKit exposes no content-inset API on NSStatusBarButton. Explicit item length is the actual
        // status-item padding mechanism: tight removes most edge space; regular keeps the native breathing room.
        var bounds = rendered.attributedTitle.boundingRect(
            with: NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading])
        if let icon = rendered.leadingIcon {
            bounds.size.width += icon.size.width
        }
        let horizontalPadding: CGFloat = self.settings.menuBarLayoutGap == .tight ? 3 : 10
        statusItem.length = max(18, ceil(bounds.width) + horizontalPadding)
    }
}
