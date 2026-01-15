import CodexBarCore

@MainActor
extension StatusItemController {
    func runAntigravityLoginFlow() async {
        self.loginPhase = .idle
        let result = await AntigravityLoginRunner.run()
        guard !Task.isCancelled else { return }
        self.loginPhase = .idle

        switch result {
        case .success(let email, let refreshToken, let projectId):
            self.addAntigravityAccount(email: email, refreshToken: refreshToken, projectId: projectId)
            self.postLoginNotification(for: .antigravity)
        case .cancelled:
            break
        case .failed(let message):
            self.presentLoginAlert(title: "Antigravity login failed", message: message)
        }
    }

    func removeCurrentAntigravityAccount() async {
        self.settings.ensureAntigravityAccountsLoaded()
        guard var accounts = self.settings.antigravityAccounts else { return }

        let index = self.settings.antigravityCurrentAccountIndex
        guard index < accounts.accounts.count else { return }

        let account = accounts.accounts[index]
        accounts.accounts.remove(at: index)

        if accounts.accounts.isEmpty {
            self.settings.antigravityAccounts = nil
            self.settings.antigravityCurrentAccountIndex = 0
        } else {
            self.settings.antigravityAccounts = accounts
            self.settings.antigravityCurrentAccountIndex = min(index, accounts.accounts.count - 1)
        }

        await self.store.refresh()

        self.presentLoginAlert(
            title: "Account removed",
            message: "\(account.email) has been removed from CodexBar.")
    }

    private func addAntigravityAccount(email: String, refreshToken: String, projectId: String?) {
        self.settings.ensureAntigravityAccountsLoaded()

        var existingAccounts = self.settings.antigravityAccounts?.accounts ?? []
        if existingAccounts.contains(where: { $0.email == email }) {
            self.presentLoginAlert(
                title: "Account already exists",
                message: "\(email) is already added to CodexBar.")
            return
        }

        let now = Date().timeIntervalSince1970
        let newAccount = AntigravityAccountStore.AntigravityAccount(
            email: email,
            refreshToken: refreshToken,
            projectId: projectId,
            addedAt: now,
            lastUsed: now,
            rateLimitResetTimes: [:],
            coolingDownUntil: nil,
            cooldownReason: nil)

        existingAccounts.append(newAccount)

        self.settings.antigravityAccounts = AntigravityAccountStore(
            version: 3,
            accounts: existingAccounts,
            activeIndex: 0,
            activeIndexByFamily: [:])

        let newIndex = existingAccounts.count - 1
        self.settings.antigravityCurrentAccountIndex = newIndex

        Task {
            await self.store.refresh()
        }

        self.presentLoginAlert(
            title: "Account added",
            message: "\(email) has been added to CodexBar.")
    }
}
