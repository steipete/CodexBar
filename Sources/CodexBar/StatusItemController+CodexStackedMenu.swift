import AppKit

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
                let accountSnapshot = snapshotsByAccountID[account.id]
                let health = CodexAccountHealth.status(for: account, error: accountSnapshot?.error)
                let model = self.menuCardModel(
                    for: .codex,
                    snapshotOverride: accountSnapshot?.snapshot,
                    errorOverride: health.label,
                    forceOverrideCard: accountSnapshot == nil,
                    accountOverride: self.accountInfo(for: account))
                guard let model else { continue }
                menu.addItem(self.makeMenuCardItem(
                    UsageMenuCardView(model: model, width: context.menuWidth),
                    id: "menuCard-\(cardIndex)",
                    width: context.menuWidth,
                    heightCacheScope: account.id))
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
                heightCacheScope: context.currentProvider.rawValue))
        }
        menu.addItem(.separator())
        if self.addStorageMenuCardSection(to: menu, provider: context.currentProvider, width: context.menuWidth) {
            menu.addItem(.separator())
        }
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
