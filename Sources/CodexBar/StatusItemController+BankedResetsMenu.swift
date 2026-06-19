import AppKit
import CodexBarCore

extension StatusItemController {
    func makeBankedResetsMenuItem(for provider: UsageProvider) -> NSMenuItem? {
        guard provider == .codex else { return nil }
        guard let bankedResets = self.store.codexConsumerProjectionIfNeeded(
            for: .codex,
            surface: .liveCard)?.bankedResets
        else { return nil }
        let count = bankedResets.availableCount
        guard count > 0 else { return nil }

        let titleKey = count == 1 ? "Banked reset: %d available" : "Banked resets: %d available"
        let title = String(format: L(titleKey), count)
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = true
        if let image = NSImage(systemSymbolName: "clock.arrow.circlepath", accessibilityDescription: nil) {
            image.isTemplate = true
            image.size = NSSize(width: 16, height: 16)
            item.image = image
        }

        let expiryDates = bankedResets.expiryDates
        if !expiryDates.isEmpty {
            let formatter = DateFormatter()
            formatter.locale = .current
            formatter.timeZone = .current
            formatter.setLocalizedDateFormatFromTemplate("MMM d")
            let expiryText = expiryDates.map { formatter.string(from: $0) }.joined(separator: " · ")
            self.applySubtitle(String(format: L("Expires: %@"), expiryText), to: item, title: title)
        }
        return item
    }
}
