import AppKit
import CodexBarCore
import QuartzCore
import SwiftUI

extension StatusItemController {
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
        let compactRequested = self.settings.mergedOverviewUsesCompactLayout
        let rows: [(
            provider: UsageProvider,
            model: UsageMenuCardView.Model,
            layoutModel: UsageMenuCardView.Model,
            projection: CompactOverviewProjection?)] = overviewProviders
            .compactMap { provider in
                guard let model = self.menuCardModel(for: provider) else { return nil }
                guard !model.isOverviewErrorOnly else { return nil }
                let layoutModel = if compactRequested, model.usesLiveSubtitle {
                    self.menuCardRefreshMonitor.model(for: provider, fallback: model)
                } else {
                    model
                }
                return (
                    provider: provider,
                    model: model,
                    layoutModel: layoutModel,
                    projection: compactRequested ? CompactOverviewProjection(model: layoutModel) : nil)
            }
        guard !rows.isEmpty else { return false }

        let compactColumns: CompactOverviewColumnLayout? = if compactRequested {
            CompactOverviewColumnLayout.resolveForMenu(
                menuWidth: menuWidth,
                projections: rows.compactMap(\.projection),
                layoutDirection: codexBarUsesRightToLeftLayout()
                    ? .rightToLeft
                    : .leftToRight,
                textWidthMeasurer: .appKit())
        } else {
            nil
        }
        let rowStyle: OverviewMenuRowStyle = compactRequested ? .compact : .detailed

        let t0 = CACurrentMediaTime()
        defer { self.logChartRenderDurationIfSlow("addOverviewRows(\(rows.count))", startedAt: t0) }

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
                row.layoutModel.heightFingerprint(
                    section: "overviewCompact",
                    additional: [
                        "projection=\(row.projection?.layoutSignature ?? "missing")",
                        "columns=\(compactColumns?.signature ?? "missing")",
                    ])
            }
            let accessibilityLabel = rowStyle == .compact
                ? row.projection?.providerName ?? row.layoutModel.providerName
                : row.model.providerName
            let item = self.makeMenuCardItem(
                OverviewMenuCardRowView(
                    model: row.model,
                    layoutModel: row.layoutModel,
                    storageText: storageText,
                    width: menuWidth,
                    style: rowStyle,
                    compactColumns: compactColumns),
                id: identifier,
                width: menuWidth,
                heightCacheScope: row.provider.rawValue,
                heightCacheFingerprint: heightFingerprint,
                submenu: submenu,
                containsInteractiveControls: OverviewMenuRowInteractionPolicy.containsInteractiveControls(
                    style: rowStyle,
                    model: row.model),
                usesGPUSelection: true,
                layoutDirection: rowStyle == .compact ? compactColumns?.layoutDirection : nil,
                accessibilityLabel: accessibilityLabel,
                accessibilityHelp: rowStyle == .compact ? L("Show details") : nil,
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
            if index < rows.count - 1 {
                menu.addItem(.separator())
            }
        }
        return true
    }
}
