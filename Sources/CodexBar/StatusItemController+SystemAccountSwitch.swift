import AppKit
import CodexBarCore

/// Controller-owned System account switch state, grouped so the controller keeps a single stored property.
struct SystemAccountSwitchState {
    var feedback = SystemAccountSwitchFeedback()
    #if DEBUG
    var noticeObserver: ((UsageProvider, SystemAccountSwitchFeedback.Notice) -> Void)?
    /// Replaces notification delivery; returns whether the notice was delivered.
    var noticeDelivery: ((SystemAccountSwitchFeedback.Notice) -> Bool)?
    /// Replaces the fallback alert.
    var alertObserver: ((String, String) -> Void)?
    #endif
}

extension StatusItemController {
    var systemAccountSwitchFeedback: SystemAccountSwitchFeedback {
        get { self.systemAccountSwitchState.feedback }
        set { self.systemAccountSwitchState.feedback = newValue }
    }

    #if DEBUG
    var _test_systemAccountNoticeObserver: ((UsageProvider, SystemAccountSwitchFeedback.Notice) -> Void)? {
        get { self.systemAccountSwitchState.noticeObserver }
        set { self.systemAccountSwitchState.noticeObserver = newValue }
    }

    var _test_systemAccountNoticeDelivery: ((SystemAccountSwitchFeedback.Notice) -> Bool)? {
        get { self.systemAccountSwitchState.noticeDelivery }
        set { self.systemAccountSwitchState.noticeDelivery = newValue }
    }

    var _test_systemAccountAlertObserver: ((String, String) -> Void)? {
        get { self.systemAccountSwitchState.alertObserver }
        set { self.systemAccountSwitchState.alertObserver = newValue }
    }
    #endif

    @objc func requestSystemAccountSwitchFromMenu(_ sender: NSMenuItem) {
        guard let parts = sender.representedObject as? [String], parts.count == 2,
              let provider = UsageProvider(rawValue: parts[0])
        else { return }
        self.startSystemAccountSwitch(provider: provider, accountID: parts[1])
    }

    func systemAccountSwitchContext() -> SystemAccountSwitchContext {
        SystemAccountSwitchContext(
            store: self.store,
            settings: self.settings,
            codexAccountPromotionCoordinator: self.codexAccountPromotionCoordinator)
    }

    /// Starts one switch per provider. Eligibility is re-read at click time so a stale submenu cannot switch an
    /// account that is no longer offered.
    @discardableResult
    func startSystemAccountSwitch(provider: UsageProvider, accountID: String) -> Task<Void, Never>? {
        guard let implementation = ProviderCatalog.implementation(for: provider),
              !self.systemAccountSwitchFeedback.isSwitching(provider)
        else { return nil }
        let context = self.systemAccountSwitchContext()
        guard let menu = implementation.systemAccountMenuEntries(context: context),
              !menu.isBlocked,
              let entry = menu.entries.first(where: { $0.accountID == accountID }),
              entry.isSwitchable, !entry.isSystem
        else { return nil }

        self.systemAccountSwitchFeedback.begin(
            provider: provider,
            accountID: accountID,
            label: entry.title,
            cliName: menu.cliName)
        self.invalidateMenus(refreshOpenMenus: true)
        return Task { @MainActor [weak self] in
            let outcome = await implementation.switchSystemAccount(accountID: accountID, context: context)
            guard let self else { return }
            self.systemAccountSwitchFeedback.finish(provider: provider, outcome: outcome)
            self.announceSystemAccountSwitchIfMenusClosed(provider: provider)
            self.invalidateMenus(refreshOpenMenus: true)
        }
    }

    private func announceSystemAccountSwitchIfMenusClosed(provider: UsageProvider) {
        guard self.openMenus.isEmpty,
              let notice = self.systemAccountSwitchFeedback.notification(for: provider)
        else { return }
        let isFailure = if case .failed = self.systemAccountSwitchFeedback.phase(for: provider) {
            true
        } else {
            false
        }
        // A failure must stay visible even when notifications are not allowed: fall back to the alert Codex used.
        let handleDelivery: @MainActor (Bool) -> Void = { [weak self] delivered in
            guard !delivered, isFailure else { return }
            self?.presentSystemAccountSwitchAlert(title: notice.title, message: notice.body)
        }
        #if DEBUG
        self._test_systemAccountNoticeObserver?(provider, notice)
        if let delivery = self._test_systemAccountNoticeDelivery {
            handleDelivery(delivery(notice))
            return
        }
        #endif
        AppNotifications.shared.post(
            idPrefix: "system-account-\(provider.rawValue)",
            title: notice.title,
            body: notice.body,
            onDeliveryResult: handleDelivery)
    }

    private func presentSystemAccountSwitchAlert(title: String, message: String) {
        #if DEBUG
        if let observer = self._test_systemAccountAlertObserver {
            observer(title, message)
            return
        }
        #endif
        self.presentLoginAlert(title: title, message: message)
    }
}
