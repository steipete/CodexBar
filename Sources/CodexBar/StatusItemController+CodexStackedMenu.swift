import AppKit
import SwiftUI

extension StatusItemController {
    func addStackedCodexMenuCards(
        _ display: CodexAccountMenuDisplay,
        to menu: NSMenu,
        context: MenuCardContext)
    {
        let snapshotsByAccountID = Dictionary(uniqueKeysWithValues: display.snapshots.map {
            ($0.account.id, $0)
        })
        var cardIndex = 0
        let sections = display.showsWorkspaceGroups ? display.workspaceSections : [
            CodexAccountWorkspaceSection(title: "", accounts: display.accounts),
        ]

        for (sectionIndex, section) in sections.enumerated() {
            if display.showsWorkspaceGroups {
                self.addCodexWorkspaceHeader(section.title, index: sectionIndex, to: menu)
            }

            for account in section.accounts {
                let model = self.codexAccountMenuCardModel(
                    for: account,
                    accountSnapshot: snapshotsByAccountID[account.id])
                guard let model else { continue }
                menu.addItem(self.makeMenuCardItem(
                    UsageMenuCardView(model: model, width: context.menuWidth),
                    id: "menuCard-\(cardIndex)",
                    width: context.menuWidth,
                    heightCacheScope: account.id,
                    heightCacheFingerprint: model.heightFingerprint(section: "card"),
                    containsInteractiveControls: true))
                cardIndex += 1
                if account.id != section.accounts.last?.id {
                    menu.addItem(.separator())
                }
            }

            if sectionIndex < sections.count - 1 {
                menu.addItem(.separator())
            }
        }

        if cardIndex == 0, let model = self.menuCardModel(for: context.selectedProvider) {
            menu.addItem(self.makeMenuCardItem(
                UsageMenuCardView(model: model, width: context.menuWidth),
                id: "menuCard",
                width: context.menuWidth,
                heightCacheScope: context.currentProvider.rawValue,
                heightCacheFingerprint: model.heightFingerprint(section: "card"),
                containsInteractiveControls: true))
        }
        menu.addItem(.separator())
        if self.addStorageMenuCardSection(to: menu, provider: context.currentProvider, width: context.menuWidth) {
            menu.addItem(.separator())
        }
    }

    func addCodexAccountMenuCards(
        _ display: CodexAccountMenuDisplay,
        to menu: NSMenu,
        captureMenu: NSMenu,
        context: MenuCardContext)
    {
        if !self.addCompactCodexAccountMenuIfPlanned(
            display: display, to: menu, captureMenu: captureMenu, context: context)
        {
            self.addStackedCodexMenuCards(display, to: menu, context: context)
        }
        self.addAccountAgnosticCostMenuSection(to: menu, context: context)
    }

    func addAccountAgnosticCostMenuSection(to menu: NSMenu, context: MenuCardContext) {
        let provider = context.currentProvider
        guard self.store.tokenCostIsAccountAgnostic(for: provider),
              let model = self.menuCardModel(for: provider),
              model.inlineUsageDashboard != nil || model.tokenUsage != nil
        else { return }
        if menu.items.last?.isSeparatorItem != true {
            menu.addItem(.separator())
        }
        let scope = NSMenuItem(title: L("This Mac"), action: nil, keyEquivalent: "")
        scope.isEnabled = false
        scope.representedObject = "sharedCodexCostScope"
        menu.addItem(scope)
        if let dashboard = model.inlineUsageDashboard {
            menu.addItem(self.makeMenuCardItem(
                InlineUsageDashboardContent(model: dashboard)
                    .padding(.horizontal, UsageMenuCardLayout.horizontalPadding)
                    .padding(.vertical, 6)
                    .frame(width: context.menuWidth),
                id: "sharedCodexInlineCost",
                width: context.menuWidth,
                heightCacheScope: provider.rawValue,
                heightCacheFingerprint: model.heightFingerprint(section: "usage")))
        }
        if model.tokenUsage != nil {
            menu.addItem(self.makeCostMenuCardItem(
                model: model,
                submenu: self.makeCostHistorySubmenu(provider: provider, width: context.menuWidth),
                width: context.menuWidth))
        }
        menu.addItem(.separator())
    }

    private func addCodexWorkspaceHeader(_ title: String, index: Int, to menu: NSMenu) {
        let header = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        header.isEnabled = false
        header.representedObject = "codexWorkspace-\(index)"
        let font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
        header.attributedTitle = NSAttributedString(
            string: title,
            attributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor])
        menu.addItem(header)
    }
}
