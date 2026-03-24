import AppKit
import CodexBarCore
import Foundation

extension SettingsStore {
    /// Whether fetches should use the primary credential path without a token-account override.
    /// For Codex, if the user had primary selected (`activeIndex < 0`) but `~/.codex` has no usable credentials,
    /// this returns `false` so usage/credits/costs follow the visible add-on tab.
    func isDefaultTokenAccountActive(for provider: UsageProvider) -> Bool {
        if provider == .codex, self.codexExplicitAccountsOnly {
            return false
        }
        guard let data = self.tokenAccountsData(for: provider), !data.accounts.isEmpty else {
            return true
        }
        guard data.activeIndex < 0 else { return false }
        if provider != .codex { return true }
        return ProviderCatalog.implementation(for: .codex)?.tokenAccountDefaultLabel(settings: self) != nil
    }

    /// Menu/settings switcher highlight: maps stored primary selection to add-on index `0` when primary is unavailable.
    func displayTokenAccountActiveIndex(for provider: UsageProvider) -> Int {
        let accounts = self.tokenAccounts(for: provider)
        guard !accounts.isEmpty else { return -1 }
        let raw = self.tokenAccountsData(for: provider)?.activeIndex ?? -1
        if raw < 0 {
            return self.isDefaultTokenAccountActive(for: provider) ? -1 : 0
        }
        return min(raw, accounts.count - 1)
    }

    func tokenAccountsData(for provider: UsageProvider) -> ProviderTokenAccountData? {
        guard TokenAccountSupportCatalog.support(for: provider) != nil else { return nil }
        return self.configSnapshot.providerConfig(for: provider)?.tokenAccounts
    }

    func tokenAccounts(for provider: UsageProvider) -> [ProviderTokenAccount] {
        self.tokenAccountsData(for: provider)?.accounts ?? []
    }

    func selectedTokenAccount(for provider: UsageProvider) -> ProviderTokenAccount? {
        guard let data = self.tokenAccountsData(for: provider), !data.accounts.isEmpty else { return nil }
        guard !self.isDefaultTokenAccountActive(for: provider) else { return nil }
        let index = data.clampedActiveIndex()
        return data.accounts[index]
    }

    func activeCodexAPIKey(
        baseEnvironment: [String: String] = ProcessInfo.processInfo.environment) -> String?
    {
        let env = ProviderRegistry.makeEnvironment(
            base: baseEnvironment,
            provider: .codex,
            settings: self,
            tokenOverride: nil)
        guard let credentials = try? CodexOAuthCredentialsStore.load(env: env) else { return nil }
        let accessToken = credentials.accessToken.trimmingCharacters(in: .whitespacesAndNewlines)
        let refreshToken = credentials.refreshToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !accessToken.isEmpty, refreshToken.isEmpty else { return nil }
        return accessToken
    }

    func isActiveCodexAPIAccount(
        baseEnvironment: [String: String] = ProcessInfo.processInfo.environment) -> Bool
    {
        self.activeCodexAPIKey(baseEnvironment: baseEnvironment) != nil
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
        if provider == .codex {
            self.repairCodexShellIntegrationIfNeeded()
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
        if provider == .codex {
            self.repairCodexShellIntegrationIfNeeded()
        }
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

    func moveTokenAccount(provider: UsageProvider, fromOffsets: IndexSet, toOffset: Int) {
        guard let data = self.tokenAccountsData(for: provider), !data.accounts.isEmpty else { return }
        var accounts = data.accounts
        let previousActiveAccount: ProviderTokenAccount? = data.activeIndex >= 0 && data.activeIndex < accounts.count
            ? accounts[data.activeIndex]
            : nil
        accounts.move(fromOffsets: fromOffsets, toOffset: toOffset)
        let newActiveIndex: Int
        if let activeAccount = previousActiveAccount,
           let newIndex = accounts.firstIndex(where: { $0.id == activeAccount.id })
        {
            newActiveIndex = newIndex
        } else {
            newActiveIndex = data.activeIndex
        }
        let updated = ProviderTokenAccountData(
            version: data.version,
            accounts: accounts,
            activeIndex: newActiveIndex)
        self.updateProviderConfig(provider: provider) { entry in
            entry.tokenAccounts = updated
        }
        CodexBarLog.logger(LogCategories.tokenAccounts).info(
            "Token account reordered",
            metadata: [
                "provider": provider.rawValue,
                "count": "\(accounts.count)",
            ])
    }

    func removeTokenAccount(provider: UsageProvider, accountID: UUID) {
        guard let data = self.tokenAccountsData(for: provider), !data.accounts.isEmpty else { return }
        let filtered = data.accounts.filter { $0.id != accountID }
        // Compute the new active index outside the closure so it's available for shell integration.
        let computedActiveIndex: Int
        if filtered.isEmpty {
            computedActiveIndex = -1
        } else if data.activeIndex < 0 {
            computedActiveIndex = -1
        } else {
            let activeID = data.activeIndex < data.accounts.count
                ? data.accounts[data.activeIndex].id
                : nil
            if let activeID, let newIndex = filtered.firstIndex(where: { $0.id == activeID }) {
                computedActiveIndex = newIndex
            } else {
                computedActiveIndex = min(max(data.activeIndex, 0), filtered.count - 1)
            }
        }
        self.updateProviderConfig(provider: provider) { entry in
            if filtered.isEmpty {
                entry.tokenAccounts = nil
            } else {
                entry.tokenAccounts = ProviderTokenAccountData(
                    version: data.version,
                    accounts: filtered,
                    activeIndex: computedActiveIndex)
            }
        }
        if provider == .codex {
            self.repairCodexShellIntegrationIfNeeded()
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

    func repairCodexShellIntegrationIfNeeded() {
        guard !Self.isRunningTests else { return }

        let pathAccounts = self.tokenAccounts(for: .codex)
            .map(\.token)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { token in
                !token.isEmpty && !token.lowercased().hasPrefix("apikey:")
            }

        guard !pathAccounts.isEmpty else {
            CodexBarShellIntegration.setActiveCodexHome(nil)
            return
        }

        CodexBarShellIntegration.installZshHookIfNeeded()
        for path in pathAccounts {
            CodexBarShellIntegration.ensureDedicatedSessionsDirectoryIfNeeded(into: path)
        }

        let activeToken = self.selectedTokenAccount(for: .codex)?
            .token
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let activePath: String?
        if let activeToken,
           !activeToken.isEmpty,
           !activeToken.lowercased().hasPrefix("apikey:")
        {
            activePath = activeToken
        } else {
            activePath = nil
        }
        CodexBarShellIntegration.setActiveCodexHome(activePath)
    }
}
