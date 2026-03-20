import AppKit
import CodexBarCore
import Foundation

extension SettingsStore {
    func tokenAccountsData(for provider: UsageProvider) -> ProviderTokenAccountData? {
        guard TokenAccountSupportCatalog.support(for: provider) != nil else { return nil }
        return self.configSnapshot.providerConfig(for: provider)?.tokenAccounts
    }

    func tokenAccounts(for provider: UsageProvider) -> [ProviderTokenAccount] {
        self.tokenAccountsData(for: provider)?.accounts ?? []
    }

    /// When a non-primary Codex account is selected, menu credits should not show OAuth/cookie errors for add-on accounts.
    func codexMenuCreditsPrimaryAccountOnlyMessage() -> String? {
        guard let data = self.tokenAccountsData(for: .codex), !data.accounts.isEmpty else { return nil }
        guard !data.isDefaultActive else { return nil }
        return "Credit information is available only for the primary account."
    }

    func selectedTokenAccount(for provider: UsageProvider) -> ProviderTokenAccount? {
        guard let data = self.tokenAccountsData(for: provider), !data.accounts.isEmpty else { return nil }
        guard !data.isDefaultActive else { return nil }
        let index = data.clampedActiveIndex()
        return data.accounts[index]
    }

    func setActiveTokenAccountIndex(_ index: Int, for provider: UsageProvider) {
        guard let data = self.tokenAccountsData(for: provider), !data.accounts.isEmpty else { return }
        // index == -1 means "use default account" (no CODEX_HOME override)
        let clamped = index < 0 ? -1 : min(max(index, 0), data.accounts.count - 1)
        let updated = ProviderTokenAccountData(
            version: data.version,
            accounts: data.accounts,
            activeIndex: clamped)
        self.updateProviderConfig(provider: provider) { entry in
            entry.tokenAccounts = updated
        }
        CodexBarLog.logger(LogCategories.tokenAccounts).info(
            "Active token account updated",
            metadata: [
                "provider": provider.rawValue,
                "index": "\(clamped)",
            ])
    }

    func addTokenAccount(provider: UsageProvider, label: String, token: String) {
        guard TokenAccountSupportCatalog.support(for: provider) != nil else { return }
        let trimmedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedToken.isEmpty else { return }
        let trimmedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let existing = self.tokenAccountsData(for: provider)
        let accounts = existing?.accounts ?? []
        let fallbackLabel = trimmedLabel.isEmpty ? "Account \(accounts.count + 1)" : trimmedLabel
        let account = ProviderTokenAccount(
            id: UUID(),
            label: fallbackLabel,
            token: trimmedToken,
            addedAt: Date().timeIntervalSince1970,
            lastUsed: nil)
        let updated = ProviderTokenAccountData(
            version: existing?.version ?? 1,
            accounts: accounts + [account],
            activeIndex: accounts.count)
        self.updateProviderConfig(provider: provider) { entry in
            entry.tokenAccounts = updated
        }
        self.applyTokenAccountCookieSourceIfNeeded(provider: provider)
        CodexBarLog.logger(LogCategories.tokenAccounts).info(
            "Token account added",
            metadata: [
                "provider": provider.rawValue,
                "count": "\(updated.accounts.count)",
            ])
    }

    func renameTokenAccount(provider: UsageProvider, accountID: UUID, newLabel: String) {
        guard let data = self.tokenAccountsData(for: provider) else { return }
        let trimmed = newLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let updated = ProviderTokenAccountData(
            version: data.version,
            accounts: data.accounts.map { account in
                var a = account
                if a.id == accountID { a.label = trimmed }
                return a
            },
            activeIndex: data.activeIndex)
        self.updateProviderConfig(provider: provider) { entry in
            entry.tokenAccounts = updated
        }
    }

    func setDefaultAccountLabel(provider: UsageProvider, label: String) {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        self.updateProviderConfig(provider: provider) { entry in
            entry.defaultAccountLabel = trimmed.isEmpty ? nil : trimmed
        }
    }

    func removeTokenAccount(provider: UsageProvider, accountID: UUID) {
        guard let data = self.tokenAccountsData(for: provider), !data.accounts.isEmpty else { return }
        let filtered = data.accounts.filter { $0.id != accountID }
        self.updateProviderConfig(provider: provider) { entry in
            if filtered.isEmpty {
                entry.tokenAccounts = nil
            } else {
                let clamped = min(max(data.activeIndex, 0), filtered.count - 1)
                entry.tokenAccounts = ProviderTokenAccountData(
                    version: data.version,
                    accounts: filtered,
                    activeIndex: clamped)
            }
        }
        CodexBarLog.logger(LogCategories.tokenAccounts).info(
            "Token account removed",
            metadata: [
                "provider": provider.rawValue,
                "count": "\(filtered.count)",
            ])
    }

    func ensureTokenAccountsLoaded() {
        if self.tokenAccountsLoaded { return }
        self.tokenAccountsLoaded = true
    }

    func reloadTokenAccounts() {
        let log = CodexBarLog.logger(LogCategories.tokenAccounts)
        let accounts: [UsageProvider: ProviderTokenAccountData]
        do {
            guard let loaded = try self.configStore.load() else { return }
            accounts = Dictionary(uniqueKeysWithValues: loaded.providers.compactMap { entry in
                guard let data = entry.tokenAccounts else { return nil }
                return (entry.id, data)
            })
        } catch {
            log.error("Failed to reload token accounts: \(error)")
            return
        }
        self.tokenAccountsLoaded = true
        self.updateProviderTokenAccounts(accounts)
    }

    func openTokenAccountsFile() {
        do {
            try self.configStore.save(self.config)
        } catch {
            CodexBarLog.logger(LogCategories.tokenAccounts).error("Failed to persist config: \(error)")
            return
        }
        NSWorkspace.shared.open(self.configStore.fileURL)
    }

    private func applyTokenAccountCookieSourceIfNeeded(provider: UsageProvider) {
        guard let support = TokenAccountSupportCatalog.support(for: provider),
              support.requiresManualCookieSource
        else { return }
        ProviderCatalog.implementation(for: provider)?.applyTokenAccountCookieSource(settings: self)
    }
}
