import AppKit
import CodexBarCore

extension StatusItemController {
    func addMiniMaxUsageSummarySectionIfNeeded(to menu: NSMenu, context: MenuCardContext) {
        let provider = context.currentProvider
        let width = context.menuWidth
        let addedSummary = self.addMiniMaxUsageSummaryMenuItemIfNeeded(to: menu, provider: provider, width: width)
        let addedRecovery = self.addMiniMaxWebSessionRecoveryItemsIfNeeded(to: menu, provider: provider)
        let addedSource = self.addMiniMaxWebSessionSourceIfNeeded(to: menu, provider: provider)
        guard addedSummary || addedRecovery || addedSource else { return }
        menu.addItem(.separator())
    }

    @discardableResult
    private func addMiniMaxWebSessionSourceIfNeeded(to menu: NSMenu, provider: UsageProvider) -> Bool {
        guard provider == .minimax,
              self.settings.showOptionalCreditsAndExtraUsage,
              let usage = self.store.snapshot(for: provider)?.minimaxUsage,
              case let .valid(sourceLabel) = usage.webSessionState
        else { return false }
        let item = NSMenuItem(
            title: L("MiniMax web session: %@", sourceLabel),
            action: nil,
            keyEquivalent: "")
        item.isEnabled = false
        menu.addItem(item)
        return true
    }

    @discardableResult
    private func addMiniMaxWebSessionRecoveryItemsIfNeeded(to menu: NSMenu, provider: UsageProvider) -> Bool {
        guard provider == .minimax,
              self.settings.showOptionalCreditsAndExtraUsage,
              let usage = self.store.snapshot(for: provider)?.minimaxUsage,
              usage.usageSummary == nil,
              usage.pointsBalance == nil,
              usage.webSessionState != .notChecked
        else { return false }

        let statusTitle = switch usage.webSessionState {
        case .expired:
            L("MiniMax web session expired")
        case .accountMismatch:
            L("MiniMax web session account does not match")
        case .unavailable(reason: .noBrowserSession):
            L("No MiniMax browser session found")
        case .unavailable(reason: .keychainAccessDisabled):
            L("Keychain access is disabled in Advanced, so browser cookie import is unavailable.")
        case .unavailable(reason: .endpointsUnavailable):
            L("MiniMax web data endpoints are unavailable")
        case .notChecked, .valid:
            L("MiniMax web session unavailable")
        }
        let status = NSMenuItem(title: statusTitle, action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)

        let reimport = NSMenuItem(
            title: L("Re-import MiniMax session from browser"),
            action: #selector(self.reimportMiniMaxWebSession),
            keyEquivalent: "")
        reimport.target = self
        menu.addItem(reimport)

        let login = NSMenuItem(
            title: L("Open MiniMax login page"),
            action: #selector(self.openMiniMaxLoginPage),
            keyEquivalent: "")
        login.target = self
        menu.addItem(login)
        return true
    }
}
