import AppKit
import CodexBarCore

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
                    heightCacheScope: account.id,
                    heightCacheFingerprint: model.heightFingerprint(section: "card")))
                cardIndex += 1
                if account.id != section.accounts.last?.id {
                    menu.addItem(.separator())
                }
            }

            if sectionIndex < sections.count - 1 {
                menu.addItem(.separator())
            }
        }

        var didAddCards = cardIndex > 0
        if cardIndex == 0, let model = self.menuCardModel(for: context.selectedProvider) {
            menu.addItem(self.makeMenuCardItem(
                UsageMenuCardView(model: model, width: context.menuWidth),
                id: "menuCard",
                width: context.menuWidth,
                heightCacheScope: context.currentProvider.rawValue,
                heightCacheFingerprint: model.heightFingerprint(section: "card")))
            didAddCards = true
        }
        if didAddCards {
            menu.addItem(.separator())
        }
        if self.addImportedCodexMenuCards(to: menu, context: context) {
            menu.addItem(.separator())
        }
        if self.addStorageMenuCardSection(to: menu, provider: context.currentProvider, width: context.menuWidth) {
            menu.addItem(.separator())
        }
    }

    func addImportedCodexMenuCards(to menu: NSMenu, context: MenuCardContext) -> Bool {
        guard context.currentProvider == .codex else { return false }
        let snapshots = self.store.importedCodexAccountSnapshots
        guard !snapshots.isEmpty else { return false }

        let model = ImportedCodexAccountsMenuView.Model.make(
            snapshots: snapshots,
            showUsed: self.settings.usageBarsShowUsed)
        menu.addItem(self.makeMenuCardItem(
            ImportedCodexAccountsMenuView(model: model, width: context.menuWidth),
            id: "importedCodexAccountsMenuCard",
            width: context.menuWidth,
            heightCacheScope: "imported-codex-accounts",
            heightCacheFingerprint: self.importedCodexAccountsHeightFingerprint(model: model)))
        return true
    }

    private func importedCodexAccountsHeightFingerprint(model: ImportedCodexAccountsMenuView.Model) -> String {
        let rowFingerprints = model.rows.map { row in
            let metricFingerprint = row.metrics.map { metric in
                [
                    metric.id,
                    UsageMenuCardView.Model.heightFingerprintField("title", metric.title),
                    "percent=\(Int(metric.percent.rounded()))",
                    UsageMenuCardView.Model.heightFingerprintField("percentText", metric.percentText),
                ].joined(separator: "|")
            }.joined(separator: ";")
            return [
                row.id,
                UsageMenuCardView.Model.heightFingerprintField("email", row.email),
                UsageMenuCardView.Model.heightFingerprintField("source", row.sourceLabel),
                UsageMenuCardView.Model.heightFingerprintField("status", row.statusText),
                "metrics=\(metricFingerprint)",
            ].joined(separator: "|")
        }.joined(separator: "||")
        return [
            "section=imported-codex-accounts",
            "localization=\(codexBarLocalizationSignature())",
            "rows=\(model.rows.count)",
            "avg=\(model.averageUsedPercent.map { Int($0.rounded()) } ?? -1)",
            rowFingerprints,
        ].joined(separator: "|")
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
