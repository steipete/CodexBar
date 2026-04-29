import AppKit

extension StatusItemController {
    func selector(for action: MenuDescriptor.MenuAction) -> (Selector, Any?) {
        switch action {
        case .installUpdate: (#selector(self.installUpdate), nil)
        case .refresh: (#selector(self.refreshNow), nil)
        case .refreshAugmentSession: (#selector(self.refreshAugmentSession), nil)
        case .dashboard: (#selector(self.openDashboard), nil)
        case .statusPage: (#selector(self.openStatusPage), nil)
        case .addCodexAccount: (#selector(self.addManagedCodexAccountFromMenu(_:)), nil)
        case let .addProviderAccount(provider): (#selector(self.runSwitchAccount(_:)), provider.rawValue)
        case let .requestCodexSystemPromotion(managedAccountID):
            (#selector(self.requestCodexSystemPromotionFromMenu(_:)), managedAccountID.uuidString)
        case let .switchAccount(provider): (#selector(self.runSwitchAccount(_:)), provider.rawValue)
        case let .openTerminal(command): (#selector(self.openTerminalCommand(_:)), command)
        case let .loginToProvider(url): (#selector(self.openLoginToProvider(_:)), url)
        case .settings: (#selector(self.showSettingsGeneral), nil)
        case .about: (#selector(self.showSettingsAbout), nil)
        case .quit: (#selector(self.quit), nil)
        case let .copyError(message): (#selector(self.copyError(_:)), message)
        }
    }

    func codexAddAccountSubtitle() -> String? {
        if self.settings.hasUnreadableManagedCodexAccountStore {
            return "Managed account storage unavailable"
        }
        guard self.managedCodexAccountCoordinator.isAuthenticatingManagedAccount else { return nil }
        return "Managed Codex login in progress…"
    }
}
