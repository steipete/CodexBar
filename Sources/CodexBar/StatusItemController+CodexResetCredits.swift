import AppKit
import CodexBarCore

extension StatusItemController {
    nonisolated static func splitMenuUsageSectionModels(
        model: UsageMenuCardView.Model,
        layoutModel: UsageMenuCardView.Model,
        hasNativeResetCreditsItem: Bool)
        -> (model: UsageMenuCardView.Model, layoutModel: UsageMenuCardView.Model)
    {
        guard hasNativeResetCreditsItem else {
            return (model, layoutModel)
        }
        var usageModel = model
        var usageLayoutModel = layoutModel
        usageModel.codexResetCredits = nil
        usageLayoutModel.codexResetCredits = nil
        return (usageModel, usageLayoutModel)
    }

    @discardableResult
    func addCodexResetCreditsMenuItemIfNeeded(to menu: NSMenu, provider: UsageProvider) -> Bool {
        guard provider == .codex,
              self.settings.showOptionalCreditsAndExtraUsage,
              let resetCredits = self.store.snapshot(for: .codex)?.codexResetCredits,
              resetCredits.availableCount > 0
        else {
            return false
        }

        let title = Self.codexResetCreditsTitle(resetCredits.availableCount)
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = true
        item.representedObject = "codexResetCredits"
        if let subtitle = Self.codexResetCreditsNextExpiryText(
            resetCredits,
            resetStyle: self.settings.resetTimeDisplayStyle)
        {
            self.applySubtitle(subtitle, to: item, title: title)
        }
        item.submenu = self.makeCodexResetCreditsSubmenu(resetCredits)
        menu.addItem(item)
        return true
    }

    private func makeCodexResetCreditsSubmenu(_ resetCredits: CodexRateLimitResetCreditsSnapshot) -> NSMenu {
        let submenu = NSMenu(title: Self.codexResetCreditsTitle(resetCredits.availableCount))
        submenu.autoenablesItems = false

        for credit in resetCredits.credits {
            let item = NSMenuItem(title: Self.codexResetCreditLine(credit), action: nil, keyEquivalent: "")
            item.isEnabled = false
            item.image = Self.codexResetCreditIcon(for: credit)
            submenu.addItem(item)
        }

        if resetCredits.nextExpiringAvailableCredit != nil {
            submenu.addItem(.separator())
        }

        let useItem = NSMenuItem(
            title: L("Use Reset"),
            action: #selector(self.consumeCodexResetCreditFromMenu(_:)),
            keyEquivalent: "")
        useItem.target = self
        useItem.representedObject = resetCredits.nextExpiringAvailableCredit?.id
        useItem.isEnabled = resetCredits.nextExpiringAvailableCredit != nil
        submenu.addItem(useItem)
        return submenu
    }

    private static func codexResetCreditsTitle(_ availableCount: Int) -> String {
        if availableCount == 1 {
            return L("1 manual reset available")
        }
        return String(format: L("%d manual resets available"), availableCount)
    }

    private static func codexResetCreditsNextExpiryText(
        _ resetCredits: CodexRateLimitResetCreditsSnapshot,
        resetStyle: ResetTimeDisplayStyle)
        -> String?
    {
        guard let expiresAt = resetCredits.nextExpiringAvailableCredit?.expiresAt else {
            return nil
        }

        let timeText: String
        switch resetStyle {
        case .absolute:
            timeText = UsageFormatter.resetDescription(from: expiresAt, now: Date())
        case .countdown:
            let countdown = UsageFormatter.resetCountdownDescription(from: expiresAt, now: Date())
            timeText = countdown == "now" ? L("now") : countdown
        }

        return String(format: L("Next expires %@"), timeText)
    }

    private static func codexResetCreditLine(_ credit: CodexRateLimitResetCredit) -> String {
        let expires = Self.codexResetCreditExpiryText(credit, now: Date())
        return "\(credit.status.rawValue), \(expires)"
    }

    private static func codexResetCreditExpiryText(_ credit: CodexRateLimitResetCredit, now: Date) -> String {
        guard let expiresAt = credit.expiresAt else { return L("No expiry") }
        let absolute = UsageFormatter.resetDescription(from: expiresAt, now: now)
        guard credit.status == .available, expiresAt > now else { return absolute }
        let countdown = UsageFormatter.resetCountdownDescription(from: expiresAt, now: now)
        return "\(countdown) (\(absolute))"
    }

    private static func codexResetCreditIcon(for credit: CodexRateLimitResetCredit) -> NSImage? {
        guard credit.status == .available,
              let image = NSImage(
                  systemSymbolName: "arrow.trianglehead.2.counterclockwise.rotate.90",
                  accessibilityDescription: L("Available reset"))
        else {
            return nil
        }

        image.isTemplate = true
        image.size = NSSize(width: 16, height: 16)
        return image
    }

    @objc func consumeCodexResetCreditFromMenu(_ sender: NSMenuItem) {
        guard let creditID = sender.representedObject as? String,
              let credit = self.store.snapshot(for: .codex)?
                  .codexResetCredits?
                  .credits
                  .first(where: { $0.id == creditID })
        else {
            return
        }
        self.consumeCodexResetCredit(credit)
    }

    func consumeCodexResetCredit(
        _ credit: CodexRateLimitResetCredit,
        codexActiveSourceOverride: CodexActiveSource? = nil)
    {
        let alert = NSAlert()
        alert.messageText = L("Use Codex reset?")
        alert.informativeText = L("This spends one banked Codex reset credit now.")
        alert.addButton(withTitle: L("Use Reset"))
        alert.addButton(withTitle: L("Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let result = try await self.store.consumeCodexResetCredit(
                    credit,
                    codexActiveSourceOverride: codexActiveSourceOverride)
                AppNotifications.shared.post(
                    idPrefix: "codex-reset-credit-used-\(credit.id)",
                    title: L("Codex reset used"),
                    body: String(format: L("%d window reset."), result.windowsReset))
                self.invalidateMenus()
            } catch {
                AppNotifications.shared.post(
                    idPrefix: "codex-reset-credit-failed-\(credit.id)",
                    title: L("Codex reset failed"),
                    body: error.localizedDescription)
            }
        }
    }
}
