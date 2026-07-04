import AppKit
import CodexBarCore

extension StatusItemController {
    nonisolated static func splitMenuUsageSectionModels(
        model: UsageMenuCardView.Model,
        layoutModel: UsageMenuCardView.Model)
        -> (
            model: UsageMenuCardView.Model,
            layoutModel: UsageMenuCardView.Model,
            resetCredits: CodexResetCreditsPresentation?)
    {
        guard let resetCredits = layoutModel.codexResetCredits else { return (model, layoutModel, nil) }
        var usageModel = model
        var usageLayoutModel = layoutModel
        usageModel.codexResetCredits = nil
        usageLayoutModel.codexResetCredits = nil
        return (usageModel, usageLayoutModel, resetCredits)
    }

    func addCodexResetCreditsSectionIfNeeded(
        to menu: NSMenu,
        presentation: CodexResetCreditsPresentation?,
        hasFollowingSection: Bool)
    {
        guard let presentation else {
            if hasFollowingSection { Self.addSectionSeparator(to: menu) }
            return
        }
        Self.addSectionSeparator(to: menu)
        self.addCodexResetCreditsMenuItemIfNeeded(
            to: menu,
            presentation: presentation)
        if hasFollowingSection { Self.addSectionSeparator(to: menu) }
    }

    private func addCodexResetCreditsMenuItemIfNeeded(
        to menu: NSMenu,
        presentation: CodexResetCreditsPresentation)
    {
        let title = L("Limit Reset Credits")
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = true
        item.representedObject = "codexResetCredits"
        item.submenu = Self.makeCodexResetCreditsSubmenu(presentation)
        let subtitle = [presentation.text, presentation.detailText]
            .compactMap(\.self)
            .joined(separator: " · ")
        self.applySubmenuSubtitle(subtitle, to: item, title: title)
        menu.addItem(item)
    }

    nonisolated static func codexResetCreditMenuRows(
        _ presentation: CodexResetCreditsPresentation) -> [String]
    {
        presentation.items.enumerated().map { index, item in
            "\(index + 1). \(item.expiryText)"
        }
    }

    private static func makeCodexResetCreditsSubmenu(_ presentation: CodexResetCreditsPresentation) -> NSMenu {
        let submenu = NSMenu(title: L("Limit Reset Credits"))
        submenu.autoenablesItems = false
        for title in self.codexResetCreditMenuRows(presentation) {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.isEnabled = false
            item.image = self.codexResetCreditIcon()
            item.toolTip = title
            submenu.addItem(item)
        }
        return submenu
    }

    private static func addSectionSeparator(to menu: NSMenu) {
        guard menu.items.last?.isSeparatorItem != true else { return }
        menu.addItem(.separator())
    }

    private static func codexResetCreditIcon() -> NSImage? {
        guard let image = NSImage(
            systemSymbolName: "arrow.trianglehead.2.counterclockwise.rotate.90",
            accessibilityDescription: L("Limit Reset Credits"))
        else {
            return nil
        }
        image.isTemplate = true
        image.size = NSSize(width: 16, height: 16)
        return image
    }
}
