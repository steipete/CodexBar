import AppKit
import CodexBarCore
import QuartzCore
import SwiftUI

extension StatusItemController {
    static let overviewBarsOnlySpacerIdentifierPrefix = "overviewBarsOnlySpacer-"

    @discardableResult
    func addOverviewRows(
        to menu: NSMenu,
        enabledProviders: [UsageProvider],
        menuWidth: CGFloat,
        captureMenu: NSMenu? = nil) -> Bool
    {
        // Rows may be built into a detached scratch menu for in-place reconciliation;
        // interaction closures must always reference the live menu they end up serving.
        let interactionMenu = captureMenu ?? menu
        let overviewProviders = self.settings.reconcileMergedOverviewSelectedProviders(
            activeProviders: enabledProviders)
        let overviewLayout = self.settings.mergedOverviewLayout
        let usesReducedContent = overviewLayout.usesReducedContent
        let rows: [(
            provider: UsageProvider,
            model: UsageMenuCardView.Model,
            layoutModel: UsageMenuCardView.Model,
            projection: CompactOverviewProjection?)] = overviewProviders
            .compactMap { provider in
                guard let model = self.menuCardModel(for: provider) else { return nil }
                guard !model.isOverviewErrorOnly else { return nil }
                let layoutModel = if usesReducedContent, model.usesLiveSubtitle {
                    self.menuCardRefreshMonitor.model(for: provider, fallback: model)
                } else {
                    model
                }
                return (
                    provider: provider,
                    model: model,
                    layoutModel: layoutModel,
                    projection: usesReducedContent ? CompactOverviewProjection(model: layoutModel) : nil)
            }
        guard !rows.isEmpty else { return false }

        let compactLayout: CompactOverviewLayout? = if usesReducedContent {
            CompactOverviewLayout.resolveForMenu(
                menuWidth: menuWidth,
                layoutDirection: codexBarUsesRightToLeftLayout()
                    ? .rightToLeft
                    : .leftToRight)
        } else {
            nil
        }
        let rowStyle = OverviewMenuRowStyle(layout: overviewLayout)

        let t0 = CACurrentMediaTime()
        defer { self.logChartRenderDurationIfSlow("addOverviewRows(\(rows.count))", startedAt: t0) }

        if rowStyle == .barsOnly {
            menu.addItem(self.makeBarsOnlySectionSpacer(width: menuWidth, edge: "leading"))
        }
        for (index, row) in rows.enumerated() {
            let identifier = "\(Self.overviewRowIdentifierPrefix)\(row.provider.rawValue)"
            let storageText = rowStyle == .detailed
                ? self.store.storageFootprintText(for: row.provider)
                : nil
            let submenu = self.makeOverviewRowSubmenu(
                provider: row.provider,
                model: row.model,
                width: menuWidth)
            let heightFingerprint: String = switch rowStyle {
            case .detailed:
                row.model.heightFingerprint(
                    section: "overviewDetailed",
                    additional: [UsageMenuCardView.Model.heightFingerprintField("storage", storageText)])
            case .compact:
                row.projection?.heightFingerprint(
                    section: "overviewCompact",
                    layoutSignature: compactLayout?.signature ?? "missing") ?? "overviewCompact:missing"
            case .providerBars:
                row.projection?.heightFingerprint(
                    section: "overviewProviderBars",
                    layoutSignature: compactLayout?.signature ?? "missing") ?? "overviewProviderBars:missing"
            case .barsOnly:
                row.projection?.heightFingerprint(
                    section: "overviewBarsOnly",
                    layoutSignature: compactLayout?.signature ?? "missing")
                    ?? "overviewBarsOnly:missing"
            }
            let accessibilityLabel = rowStyle.usesReducedContent
                ? row.projection?.accessibilityLabel ?? row.layoutModel.providerName
                : row.model.providerName
            let item = self.makeMenuCardItem(
                OverviewMenuCardRowView(
                    model: row.model,
                    layoutModel: row.layoutModel,
                    storageText: storageText,
                    width: menuWidth,
                    style: rowStyle,
                    compactLayout: compactLayout),
                id: identifier,
                width: menuWidth,
                heightCacheScope: row.provider.rawValue,
                heightCacheFingerprint: heightFingerprint,
                submenu: submenu,
                showsSubmenuIndicator: rowStyle != .barsOnly,
                submenuIndicatorAlignment: rowStyle == .barsOnly ? .trailing : .topTrailing,
                submenuIndicatorTopPadding: rowStyle == .barsOnly ? 0 : 8,
                containsInteractiveControls: OverviewMenuRowInteractionPolicy.containsInteractiveControls(
                    style: rowStyle,
                    model: row.model),
                // Reduced Overview rows publish their live accessibility label through the row host's store.
                usesGPUSelection: true,
                layoutDirection: rowStyle.usesReducedContent ? compactLayout?.layoutDirection : nil,
                accessibilityLabel: accessibilityLabel,
                accessibilityUserInputLabels: rowStyle.usesReducedContent
                    ? [row.layoutModel.providerName]
                    : nil,
                accessibilityHelp: rowStyle.usesReducedContent ? L("Show details") : nil,
                onClick: { [weak self, weak interactionMenu] in
                    guard let self, let interactionMenu else { return }
                    self.selectOverviewProvider(row.provider, menu: interactionMenu)
                })
            if submenu == nil {
                // Keep plain rows wired for keyboard activation and accessibility action paths.
                item.target = self
                item.action = #selector(self.selectOverviewProvider(_:))
            }
            menu.addItem(item)
            if rowStyle != .barsOnly, index < rows.count - 1 {
                menu.addItem(.separator())
            }
        }
        if rowStyle == .barsOnly {
            menu.addItem(self.makeBarsOnlySectionSpacer(width: menuWidth, edge: "trailing"))
        }
        return true
    }

    private func makeBarsOnlySectionSpacer(width: CGFloat, edge: String) -> NSMenuItem {
        let view = NSView(frame: NSRect(
            x: 0,
            y: 0,
            width: width,
            height: CompactOverviewLayout.barsOnlySectionSpacerHeight))
        view.autoresizingMask = [.width]
        view.setAccessibilityElement(false)

        let item = NSMenuItem()
        item.view = view
        item.isEnabled = false
        item.representedObject = "\(Self.overviewBarsOnlySpacerIdentifierPrefix)\(edge)"
        return item
    }
}
