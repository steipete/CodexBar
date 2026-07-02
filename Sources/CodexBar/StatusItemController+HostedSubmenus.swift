import AppKit
import CodexBarCore
import QuartzCore
import SwiftUI

extension StatusItemController {
    private struct HostedSubviewIdentity {
        let chartID: String
        let provider: UsageProvider?
        let providerRawValue: String?
    }

    func isHostedSubviewMenu(_ menu: NSMenu) -> Bool {
        let ids: Set = [
            Self.usageBreakdownChartID,
            Self.creditsHistoryChartID,
            Self.costHistoryChartID,
            Self.usageHistoryChartID,
            Self.storageBreakdownID,
            Self.statusComponentsID,
            Self.zaiHourlyUsageChartID,
        ]
        return menu.items.contains { item in
            guard let id = item.representedObject as? String else { return false }
            return ids.contains(id)
        }
    }

    func makeHostedSubviewPlaceholderMenu(
        chartID: String,
        provider: UsageProvider? = nil,
        width: CGFloat? = nil) -> NSMenu
    {
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        if let width {
            submenu.minimumWidth = width
        }
        submenu.delegate = self
        let chartItem = NSMenuItem()
        chartItem.isEnabled = true
        chartItem.representedObject = chartID
        chartItem.toolTip = provider?.rawValue
        submenu.addItem(chartItem)
        return submenu
    }

    @discardableResult
    func hydrateHostedSubviewMenuIfNeeded(_ menu: NSMenu, width requestedWidth: CGFloat? = nil) -> Bool {
        guard let placeholder = menu.items.first,
              menu.items.count == 1,
              placeholder.view == nil,
              let chartID = placeholder.representedObject as? String
        else {
            return false
        }

        let width = requestedWidth ?? self.renderedMenuWidth(for: menu.supermenu ?? menu)
        let identity = HostedSubviewIdentity(
            chartID: chartID,
            provider: placeholder.toolTip.flatMap(UsageProvider.init(rawValue:)),
            providerRawValue: placeholder.toolTip)
        menu.removeAllItems()

        let t0 = CACurrentMediaTime()
        MainThreadActivityBreadcrumb.push("hydrateChart:\(chartID)")
        defer { MainThreadActivityBreadcrumb.pop() }
        let didHydrate: Bool = switch chartID {
        case Self.usageBreakdownChartID:
            self.appendUsageBreakdownChartItem(to: menu, width: width)
        case Self.creditsHistoryChartID:
            self.appendCreditsHistoryChartItem(to: menu, width: width)
        case Self.costHistoryChartID:
            if let providerRawValue = placeholder.toolTip,
               let provider = UsageProvider(rawValue: providerRawValue)
            {
                self.appendCostHistoryChartItem(to: menu, provider: provider, width: width)
            } else {
                false
            }
        case Self.usageHistoryChartID:
            if let providerRawValue = placeholder.toolTip,
               let provider = UsageProvider(rawValue: providerRawValue)
            {
                self.appendUsageHistoryChartItem(to: menu, provider: provider, width: width)
            } else {
                false
            }
        case Self.storageBreakdownID:
            if let providerRawValue = placeholder.toolTip,
               let provider = UsageProvider(rawValue: providerRawValue)
            {
                self.appendStorageBreakdownItem(to: menu, provider: provider, width: width)
            } else {
                false
            }
        case Self.statusComponentsID:
            if let providerRawValue = self.hostedSubviewProviderRawValue(for: placeholder),
               let provider = UsageProvider(rawValue: providerRawValue)
            {
                self.appendStatusComponentsItem(to: menu, provider: provider, width: width)
            } else {
                false
            }
        case Self.zaiHourlyUsageChartID:
            if let providerRawValue = placeholder.toolTip,
               let provider = UsageProvider(rawValue: providerRawValue)
            {
                self.appendZaiHourlyUsageChartItem(to: menu, provider: provider, width: width)
            } else {
                false
            }
        default:
            false
        }
        self.logChartRenderDurationIfSlow("hydrateHostedSubview:\(chartID)", startedAt: t0)

        if !didHydrate {
            self.appendHostedSubviewUnavailableItem(
                to: menu,
                chartID: chartID,
                providerRawValue: placeholder.toolTip)
        }
        self.recordHostedSubviewRenderSignature(for: menu, identity: identity, width: width)
        return true
    }

    func refreshHostedSubviewMenu(_ menu: NSMenu) {
        let width = self.renderedMenuWidth(for: menu)
        guard let identity = self.hostedSubviewIdentity(for: menu) else {
            self.refreshHostedSubviewHeights(in: menu)
            return
        }
        let signature = self.hostedSubviewRenderSignature(identity: identity, width: width)
        if self.hostedSubviewRenderSignatures.object(forKey: menu) as String? == signature {
            if identity.chartID == Self.zaiHourlyUsageChartID {
                self.refreshHostedSubviewHeights(in: menu)
            }
            return
        }

        menu.removeAllItems()
        let t0 = CACurrentMediaTime()
        MainThreadActivityBreadcrumb.push("refreshChart:\(identity.chartID)")
        defer { MainThreadActivityBreadcrumb.pop() }
        let didHydrate: Bool = switch identity.chartID {
        case Self.usageBreakdownChartID:
            self.appendUsageBreakdownChartItem(to: menu, width: width)
        case Self.creditsHistoryChartID:
            self.appendCreditsHistoryChartItem(to: menu, width: width)
        case Self.costHistoryChartID:
            if let provider = identity.provider {
                self.appendCostHistoryChartItem(to: menu, provider: provider, width: width)
            } else {
                false
            }
        case Self.usageHistoryChartID:
            if let provider = identity.provider {
                self.appendUsageHistoryChartItem(to: menu, provider: provider, width: width)
            } else {
                false
            }
        case Self.storageBreakdownID:
            if let provider = identity.provider {
                self.appendStorageBreakdownItem(to: menu, provider: provider, width: width)
            } else {
                false
            }
        case Self.statusComponentsID:
            if let provider = identity.provider {
                self.appendStatusComponentsItem(to: menu, provider: provider, width: width)
            } else {
                false
            }
        case Self.zaiHourlyUsageChartID:
            if let provider = identity.provider {
                self.appendZaiHourlyUsageChartItem(to: menu, provider: provider, width: width)
            } else {
                false
            }
        default:
            false
        }
        self.logChartRenderDurationIfSlow("refreshHostedSubview:\(identity.chartID)", startedAt: t0)

        if !didHydrate {
            self.appendHostedSubviewUnavailableItem(
                to: menu,
                chartID: identity.chartID,
                providerRawValue: identity.provider?.rawValue ?? identity.providerRawValue)
        }
        self.hostedSubviewRenderSignatures.setObject(signature as NSString, forKey: menu)
    }

    private func hostedSubviewIdentity(for menu: NSMenu)
    -> HostedSubviewIdentity? {
        for item in menu.items {
            guard let chartID = item.representedObject as? String else { continue }
            let providerRawValue = self.hostedSubviewProviderRawValue(for: item)
            return HostedSubviewIdentity(
                chartID: chartID,
                provider: providerRawValue.flatMap(UsageProvider.init(rawValue:)),
                providerRawValue: providerRawValue)
        }
        return nil
    }

    private func hostedSubviewProviderRawValue(for item: NSMenuItem) -> String? {
        if let providerRawValue = item.toolTip {
            return providerRawValue
        }
        guard item.representedObject as? String == Self.statusComponentsID else { return nil }
        return item.identifier?.rawValue
    }

    private func recordHostedSubviewRenderSignature(
        for menu: NSMenu,
        identity: HostedSubviewIdentity,
        width: CGFloat)
    {
        let signature = self.hostedSubviewRenderSignature(identity: identity, width: width)
        self.hostedSubviewRenderSignatures.setObject(signature as NSString, forKey: menu)
    }

    private func hostedSubviewRenderSignature(
        identity: HostedSubviewIdentity,
        width: CGFloat) -> String
    {
        let contentSignature: String = switch identity.chartID {
        case Self.usageBreakdownChartID:
            Self.dashboardBreakdownReadinessSignature(
                OpenAIDashboardDailyBreakdown.removingSkillUsageServices(
                    from: self.store.openAIDashboard?.usageBreakdown ?? []))
        case Self.creditsHistoryChartID:
            Self.dashboardBreakdownReadinessSignature(self.store.openAIDashboard?.dailyBreakdown ?? [])
        case Self.costHistoryChartID:
            identity.provider.map(self.costHistoryRenderSignature(for:)) ?? "missing-provider"
        case Self.usageHistoryChartID:
            identity.provider.map(self.usageHistoryRenderSignature(for:)) ?? "missing-provider"
        case Self.storageBreakdownID:
            identity.provider.map(self.storageBreakdownRenderSignature(for:)) ?? "missing-provider"
        case Self.statusComponentsID:
            identity.provider.map(self.statusComponentsRenderSignature(for:)) ?? "missing-provider"
        case Self.zaiHourlyUsageChartID:
            identity.provider.map(self.zaiHourlyUsageRenderSignature(for:)) ?? "missing-provider"
        default:
            "unknown"
        }
        return [
            identity.chartID,
            identity.providerRawValue ?? "",
            String(Double(width).bitPattern, radix: 16),
            contentSignature,
        ].joined(separator: "|")
    }

    private func costHistoryRenderSignature(for provider: UsageProvider) -> String {
        guard let snapshot = self.tokenSnapshotForCostHistorySubmenu(provider: provider) else { return "none" }
        return [
            snapshot.currencyCode,
            "\(snapshot.historyDays)",
            snapshot.historyLabel ?? "",
            snapshot.last30DaysCostUSD.map { String($0.bitPattern, radix: 16) } ?? "nil",
            String(reflecting: snapshot.daily),
        ].joined(separator: "|")
    }

    private func usageHistoryRenderSignature(for provider: UsageProvider) -> String {
        let snapshot = self.store.snapshot(for: provider)
        let selection = self.store.planUtilizationHistorySelection(for: provider)
        return [
            "\(self.store.planUtilizationHistoryRevision)",
            "\(Int(Date().timeIntervalSince1970 / 60))",
            selection.accountKey ?? "unscoped",
            snapshot?.primary == nil ? "0" : "1",
            snapshot?.secondary == nil ? "0" : "1",
            snapshot?.tertiary == nil ? "0" : "1",
        ].joined(separator: "|")
    }

    func statusComponentsRenderSignature(for provider: UsageProvider) -> String {
        let components = self.store.statusComponents(for: provider)
        guard !components.isEmpty else { return "none" }
        func signature(_ component: ProviderStatusComponent) -> String {
            let childSig = component.children.map(signature).joined(separator: ",")
            return "\(component.id)=\(component.indicator.rawValue)[\(childSig)]"
        }
        return components.map(signature).joined(separator: ";")
    }

    private func storageBreakdownRenderSignature(for provider: UsageProvider) -> String {
        guard let footprint = self.store.storageFootprint(for: provider) else { return "none" }
        let components = footprint.components
            .map { "\($0.path)=\($0.totalBytes)" }
            .joined(separator: ";")
        return [
            "\(footprint.totalBytes)",
            footprint.paths.joined(separator: ";"),
            footprint.missingPaths.joined(separator: ";"),
            footprint.unreadablePaths.joined(separator: ";"),
            components,
            String(Double(self.storageBreakdownMenuMaxHeight()).bitPattern, radix: 16),
        ].joined(separator: "|")
    }

    private func zaiHourlyUsageRenderSignature(for provider: UsageProvider) -> String {
        guard let modelUsage = self.store.snapshot(for: provider)?.zaiUsage?.modelUsage else { return "none" }
        return Self.zaiHourlyUsageRenderSignature(modelUsage: modelUsage, now: Date())
    }

    static func zaiHourlyUsageRenderSignature(modelUsage: ZaiModelUsageData, now: Date) -> String {
        let models = modelUsage.modelDataList
            .map { model in
                let usage = model.tokensUsage
                    .map { $0.map(String.init) ?? "nil" }
                    .joined(separator: ",")
                return "\(model.modelName ?? "")=\(usage)"
            }
            .joined(separator: ";")
        let ranges: [ZaiHourlyRange] = [.today(referenceDate: now), .last24h]
        let visibleBars = ranges
            .map { range in
                ZaiHourlyBars.from(modelData: modelUsage, range: range, now: now)
                    .map { bar in
                        let segments = bar.segments
                            .map { "\($0.model)=\($0.tokens)" }
                            .joined(separator: ",")
                        return "\(bar.label):\(segments)"
                    }
                    .joined(separator: ";")
            }
        return [
            modelUsage.xTime.joined(separator: ","),
            models,
            visibleBars.joined(separator: "|"),
        ].joined(separator: "|")
    }

    private func appendHostedSubviewUnavailableItem(
        to menu: NSMenu,
        chartID: String,
        providerRawValue: String?)
    {
        let unavailableItem = NSMenuItem(title: L("No data available"), action: nil, keyEquivalent: "")
        unavailableItem.isEnabled = false
        unavailableItem.representedObject = chartID
        unavailableItem.toolTip = providerRawValue
        menu.addItem(unavailableItem)
    }

    @discardableResult
    func appendUsageBreakdownChartItem(to submenu: NSMenu, width: CGFloat) -> Bool {
        let breakdown = OpenAIDashboardDailyBreakdown.removingSkillUsageServices(
            from: self.store.openAIDashboard?.usageBreakdown ?? [])
        guard !breakdown.isEmpty else { return false }

        if !self.menuCardRenderingEnabledForController {
            let chartItem = NSMenuItem()
            chartItem.isEnabled = true
            chartItem.representedObject = Self.usageBreakdownChartID
            submenu.addItem(chartItem)
            return true
        }

        let chartView = UsageBreakdownChartMenuView(breakdown: breakdown, width: width)
        let hosting = MenuHostingView(rootView: chartView)
        hosting.frame = NSRect(
            origin: .zero,
            size: NSSize(width: width, height: self.hostedSubviewFittingHeight(for: hosting, width: width)))

        let chartItem = NSMenuItem()
        chartItem.view = hosting
        chartItem.isEnabled = true
        chartItem.representedObject = Self.usageBreakdownChartID
        submenu.addItem(chartItem)
        return true
    }

    @discardableResult
    func appendCreditsHistoryChartItem(to submenu: NSMenu, width: CGFloat) -> Bool {
        let breakdown = self.store.openAIDashboard?.dailyBreakdown ?? []
        guard !breakdown.isEmpty else { return false }

        if !self.menuCardRenderingEnabledForController {
            let chartItem = NSMenuItem()
            chartItem.isEnabled = true
            chartItem.representedObject = Self.creditsHistoryChartID
            submenu.addItem(chartItem)
            return true
        }

        let chartView = CreditsHistoryChartMenuView(breakdown: breakdown, width: width)
        let hosting = MenuHostingView(rootView: chartView)
        hosting.frame = NSRect(
            origin: .zero,
            size: NSSize(width: width, height: self.hostedSubviewFittingHeight(for: hosting, width: width)))

        let chartItem = NSMenuItem()
        chartItem.view = hosting
        chartItem.isEnabled = true
        chartItem.representedObject = Self.creditsHistoryChartID
        submenu.addItem(chartItem)
        return true
    }

    @discardableResult
    func appendCostHistoryChartItem(
        to submenu: NSMenu,
        provider: UsageProvider,
        width: CGFloat) -> Bool
    {
        guard let tokenSnapshot = self.tokenSnapshotForCostHistorySubmenu(provider: provider) else { return false }
        guard !tokenSnapshot.daily.isEmpty else { return false }

        if !self.menuCardRenderingEnabledForController {
            let chartItem = NSMenuItem()
            chartItem.isEnabled = true
            chartItem.representedObject = Self.costHistoryChartID
            chartItem.toolTip = provider.rawValue
            submenu.addItem(chartItem)
            return true
        }

        // The SwiftUI view needs the callback at init, but the hosting view doesn't exist yet.
        // A relay breaks the cycle: the closure captures relay strongly, relay holds the view weakly.
        final class HostingRelay {
            weak var hosting: MenuHostingView<CostHistoryChartMenuView>?
        }
        let relay = HostingRelay()
        let chartView = CostHistoryChartMenuView(
            provider: provider,
            daily: tokenSnapshot.daily,
            totalCostUSD: tokenSnapshot.last30DaysCostUSD,
            currencyCode: tokenSnapshot.currencyCode,
            historyDays: tokenSnapshot.historyDays,
            windowLabel: tokenSnapshot.historyLabel,
            onHeightChange: { height in
                relay.hosting?.applyMeasuredHeight(width: width, height: height)
            },
            width: width)
        let resolvedHosting = MenuHostingView(rootView: chartView)
        relay.hosting = resolvedHosting
        resolvedHosting.applyMeasuredHeight(
            width: width,
            height: self.hostedSubviewFittingHeight(for: resolvedHosting, width: width))

        let chartItem = NSMenuItem()
        chartItem.view = resolvedHosting
        chartItem.isEnabled = true
        chartItem.representedObject = Self.costHistoryChartID
        chartItem.toolTip = provider.rawValue
        submenu.addItem(chartItem)
        return true
    }

    @discardableResult
    func appendStorageBreakdownItem(
        to submenu: NSMenu,
        provider: UsageProvider,
        width: CGFloat)
        -> Bool
    {
        guard let footprint = self.store.storageFootprint(for: provider),
              !footprint.components.isEmpty
        else { return false }

        if !self.menuCardRenderingEnabledForController {
            let item = NSMenuItem()
            item.isEnabled = true
            item.representedObject = Self.storageBreakdownID
            item.toolTip = provider.rawValue
            submenu.addItem(item)
            return true
        }

        let maxHeight = self.storageBreakdownMenuMaxHeight()
        final class HostingRelay {
            weak var hosting: MenuHostingView<StorageBreakdownMenuView>?
            var collapsedHeight: CGFloat = 1
        }
        let relay = HostingRelay()
        let view = StorageBreakdownMenuView(
            footprint: footprint,
            width: width,
            maxHeight: maxHeight,
            onExpansionHeightChange: { additionalHeight in
                relay.hosting?.applyMeasuredHeight(
                    width: width,
                    height: min(maxHeight, relay.collapsedHeight + additionalHeight))
            })
        let hosting = MenuHostingView(rootView: view)
        relay.hosting = hosting
        relay.collapsedHeight = self.hostedSubviewFittingHeight(for: hosting, width: width)
        hosting.applyMeasuredHeight(width: width, height: relay.collapsedHeight)

        let item = NSMenuItem()
        item.view = hosting
        item.isEnabled = true
        item.representedObject = Self.storageBreakdownID
        item.toolTip = provider.rawValue
        submenu.addItem(item)
        return true
    }

    @discardableResult
    func appendStatusComponentsItem(
        to submenu: NSMenu,
        provider: UsageProvider,
        width: CGFloat) -> Bool
    {
        // The list of component rows is shown only once the provider's status has been fetched.
        // Before the first fetch lands the submenu still renders (just the website link below), so
        // every provider with a status feed gets the native submenu rather than a bare link; it
        // re-hydrates with the live component list once data arrives (see makeStatusComponentsSubmenu).
        let components = self.store.statusComponents(for: provider)
        if !components.isEmpty {
            if self.menuCardRenderingEnabledForController {
                final class HostingRelay {
                    weak var hosting: MenuHostingView<StatusComponentsMenuView>?
                }
                let relay = HostingRelay()
                let listView = StatusComponentsMenuView(
                    components: components,
                    width: width,
                    onToggle: {
                        // Re-measure the live content after SwiftUI applies the expand/collapse so the
                        // row grows/shrinks to fit exactly (no leftover blank space).
                        DispatchQueue.main.async {
                            guard let hosting = relay.hosting else { return }
                            hosting.applyMeasuredHeight(
                                width: width,
                                height: hosting.measuredFittingHeight(width: width))
                        }
                    })
                let hosting = MenuHostingView(rootView: listView)
                relay.hosting = hosting
                hosting.applyMeasuredHeight(width: width, height: hosting.measuredFittingHeight(width: width))

                let listItem = NSMenuItem()
                listItem.view = hosting
                listItem.isEnabled = false
                listItem.representedObject = Self.statusComponentsID
                listItem.toolTip = provider.rawValue
                submenu.addItem(listItem)
            } else {
                let placeholder = NSMenuItem()
                placeholder.isEnabled = false
                placeholder.representedObject = Self.statusComponentsID
                placeholder.toolTip = provider.rawValue
                submenu.addItem(placeholder)
            }

            submenu.addItem(.separator())
        }

        let linkItem = NSMenuItem(
            title: L("Open Status Page"),
            action: #selector(self.openStatusPageFromMenuItem(_:)),
            keyEquivalent: "")
        linkItem.target = self
        // Tag the link with the chart identity so the menu is still recognized as a status
        // submenu (and re-hydrates) when the component list hasn't loaded yet and the link is the
        // only row. The identifier also scopes the action to this submenu's provider so a later
        // menu selection change cannot open another provider's status page.
        linkItem.representedObject = Self.statusComponentsID
        linkItem.identifier = NSUserInterfaceItemIdentifier(provider.rawValue)
        if let image = NSImage(systemSymbolName: "arrow.up.right.square", accessibilityDescription: nil) {
            image.isTemplate = true
            image.size = NSSize(width: 16, height: 16)
            linkItem.image = image
        }
        submenu.addItem(linkItem)
        return true
    }

    private func storageBreakdownMenuMaxHeight() -> CGFloat {
        let visibleHeight = NSScreen.main?.visibleFrame.height ?? 900
        return min(620, max(360, floor(visibleHeight * 0.72)))
    }

    @discardableResult
    func appendZaiHourlyUsageChartItem(
        to submenu: NSMenu,
        provider: UsageProvider,
        width: CGFloat) -> Bool
    {
        guard provider == .zai,
              let snapshot = self.store.snapshot(for: provider),
              let modelUsage = snapshot.zaiUsage?.modelUsage
        else { return false }

        if !self.menuCardRenderingEnabledForController {
            let chartItem = NSMenuItem()
            chartItem.isEnabled = false
            chartItem.representedObject = Self.zaiHourlyUsageChartID
            chartItem.toolTip = provider.rawValue
            submenu.addItem(chartItem)
            return true
        }

        let chartView = ZaiHourlyUsageChartMenuView(modelUsage: modelUsage, width: width)
        let hosting = MenuHostingView(rootView: chartView)
        hosting.frame = NSRect(
            origin: .zero,
            size: NSSize(width: width, height: self.hostedSubviewFittingHeight(for: hosting, width: width)))

        let chartItem = NSMenuItem()
        chartItem.view = hosting
        chartItem.isEnabled = false
        chartItem.representedObject = Self.zaiHourlyUsageChartID
        chartItem.toolTip = provider.rawValue
        submenu.addItem(chartItem)
        return true
    }
}
