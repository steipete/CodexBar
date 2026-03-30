#if DEBUG
import CodexBarCore

extension StatusItemController {
    struct TestCodexAccountSwitcherState {
        let accountEmails: [String]
        let activeVisibleAccountID: String?
    }

    func _test_codexAccountSwitcherState(for provider: UsageProvider = .codex) -> TestCodexAccountSwitcherState? {
        guard let display = self.codexAccountMenuDisplay(for: provider) else { return nil }
        return TestCodexAccountSwitcherState(
            accountEmails: display.accounts.map(\.email),
            activeVisibleAccountID: display.activeVisibleAccountID)
    }

    @discardableResult
    func _test_selectCodexVisibleAccountFromMenu(id: String) -> Bool {
        self.handleCodexVisibleAccountSelection(id, menu: nil)
    }
}
#endif
