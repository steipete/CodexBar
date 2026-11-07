import AppKit
import CodexBarCore
import SwiftUI

extension StatusItemController {
    /// Compact Overview: one fixed-height line per provider, most urgent first.
    func addOverviewLinesIfCompact(
        _ rows: [MergedOverviewRow],
        _ menu: NSMenu,
        _ scopes: (visible: [ProviderInstanceID], spend: [UsageProvider]),
        _ menuWidth: CGFloat,
        _ interactionMenu: NSMenu) -> Bool
    {
        guard self.settings.mergedOverviewLayout == .compact else { return false }
        var pluginRows: [MergedOverviewRow] = []
        var entries: [String: MergedOverviewRow] = [:]
        var lines: [OverviewProviderLine] = []
        for row in rows {
            guard let model = row.model else {
                pluginRows.append(row)
                continue
            }
            let id = "\(Self.overviewRowIdentifierPrefix)\(row.id)"
            entries[id] = row
            lines.append(OverviewProviderLine(
                id: id,
                model: model,
                account: row.accountID == nil ? nil : model.email))
        }
        let sorted = OverviewProviderLine.sortedByUrgency(lines)
        // The heads describe bars and percentages, so they need at least one row that has them.
        if sorted.contains(where: { $0.percent != nil }),
           let style = rows.lazy.compactMap({ $0.model?.metrics.first?.percentStyle }).first
        {
            menu.addItem(self.makeMenuCardItem(
                OverviewLinesHeaderView(percentStyle: style, width: menuWidth),
                id: "overviewLinesHeader",
                width: menuWidth))
        }
        let attention = self.makeOverviewAttentionItem(
            providers: scopes.visible,
            menuWidth: menuWidth,
            interactionMenu: interactionMenu)
        var attentionAdded = attention == nil
        for line in sorted {
            guard let row = entries[line.id] else { continue }
            // A signed-out provider is stopped now, so it follows only the limits about to stop.
            if !attentionAdded, line.status != .critical, let attention {
                menu.addItem(attention)
                attentionAdded = true
            }
            menu.addItem(self.makeOverviewLineItem(
                line,
                row: row,
                menuWidth: menuWidth,
                interactionMenu: interactionMenu))
        }
        if !attentionAdded, let attention { menu.addItem(attention) }
        for row in pluginRows {
            guard let plugin = UserProviderPluginRegistry.plugin(for: row.provider) else { continue }
            let instanceID = row.provider
            let item = self.makeUserPluginMenuCardItem(
                plugin,
                width: menuWidth,
                id: "\(Self.overviewRowIdentifierPrefix)\(row.id)",
                onClick: plugin.manifest.topLevel ? { [weak self, weak interactionMenu] in
                    guard let self, let interactionMenu else { return }
                    self.selectOverviewProvider(instanceID, menu: interactionMenu)
                } : nil)
            if plugin.manifest.topLevel {
                item.target = self
                item.action = #selector(self.selectOverviewProvider(_:))
            }
            menu.addItem(item)
        }
        return true
    }

    private func makeOverviewLineItem(
        _ line: OverviewProviderLine,
        row: MergedOverviewRow,
        menuWidth: CGFloat,
        interactionMenu: NSMenu) -> NSMenuItem
    {
        let instanceID = row.provider
        let submenu = row.accountID == nil
            ? row.model.flatMap { self.makeOverviewRowSubmenu(provider: line.provider, model: $0, width: menuWidth) }
            : nil
        let item = self.makeMenuCardItem(
            OverviewProviderLineView(line: line, width: menuWidth),
            id: line.id,
            width: menuWidth,
            heightCacheScope: "overviewLine",
            heightCacheFingerprint: "line",
            submenu: submenu,
            showsSubmenuIndicator: false,
            usesGPUSelection: true,
            onClick: { [weak self, weak interactionMenu] in
                guard let self, let interactionMenu else { return }
                self.selectOverviewProvider(instanceID, menu: interactionMenu)
            })
        if submenu == nil {
            // Keep plain rows wired for keyboard activation and accessibility action paths.
            item.target = self
            item.action = #selector(self.selectOverviewProvider(_:))
        }
        return item
    }

    /// `NSMenu` drops Return for a highlighted item that hosts a view, so its native action never fires by itself.
    func activateHighlightedOverviewRow(_ event: NSEvent, menu: NSMenu) -> Bool {
        guard event.keyCode == 36 || event.keyCode == 76, // Return, keypad Enter
              !event.isARepeat,
              event.modifierFlags.isDisjoint(with: [.command, .option, .control, .shift]),
              let item = self.highlightedMenuItems[ObjectIdentifier(menu)],
              item.menu === menu,
              item.view != nil,
              item.submenu == nil,
              item.action == #selector(self.selectOverviewProvider(_:))
        else {
            return false
        }
        self.selectOverviewProvider(item)
        return true
    }

    /// Compact can still say something when every selected provider has failed; Detailed keeps its empty state.
    func overviewHasCompactAttention(providers: [ProviderInstanceID]) -> Bool {
        self.settings.mergedOverviewLayout == .compact && !self.overviewErrorOnlyProviders(providers).isEmpty
    }

    private func overviewErrorOnlyProviders(
        _ providers: [ProviderInstanceID]) -> [(ProviderInstanceID, UsageMenuCardView.Model)]
    {
        providers.compactMap { instanceID in
            guard let provider = instanceID.firstPartyProvider else { return nil }
            let model = self.store.menuCardModel(for: provider)
            return model.isOverviewErrorOnly ? (instanceID, model) : nil
        }
    }

    /// Error-only providers are not limit rows, but a signed-out provider must not vanish without a word.
    private func makeOverviewAttentionItem(
        providers: [ProviderInstanceID],
        menuWidth: CGFloat,
        interactionMenu: NSMenu) -> NSMenuItem?
    {
        let failing = self.overviewErrorOnlyProviders(providers)
        guard let first = failing.first else { return nil }
        let isSingle = failing.count == 1
        let instanceID = first.0
        let submenu = isSingle ? nil : NSMenu()
        submenu?.autoenablesItems = false
        for (id, model) in failing {
            let child = NSMenuItem(
                title: "\(model.providerName): \(model.subtitleText)",
                action: #selector(self.selectOverviewProvider(_:)),
                keyEquivalent: "")
            child.target = self
            child.representedObject = "\(Self.overviewRowIdentifierPrefix)\(id.rawValue)"
            submenu?.addItem(child)
        }
        let item = self.makeMenuCardItem(
            OverviewAttentionRowView(
                provider: isSingle ? first.1.provider : nil,
                name: isSingle ? first.1.providerName : nil,
                message: isSingle ? first.1.subtitleText : failing.map(\.1.providerName).joined(separator: ", "),
                width: menuWidth),
            id: isSingle ? "\(Self.overviewRowIdentifierPrefix)\(instanceID.rawValue)" : "overviewAttention",
            width: menuWidth,
            heightCacheScope: "overviewLine",
            heightCacheFingerprint: "attention",
            submenu: submenu,
            usesGPUSelection: true,
            onClick: { [weak self, weak interactionMenu] in
                guard let self, let interactionMenu else { return }
                self.selectOverviewProvider(instanceID, menu: interactionMenu)
            })
        if isSingle {
            // Keep the single row wired for keyboard activation and accessibility action paths.
            item.target = self
            item.action = #selector(self.selectOverviewProvider(_:))
        }
        return item
    }
}
