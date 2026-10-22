import AppKit
import CodexBarCore
import Foundation

extension SettingsStore {
    func tokenAccountsData(for provider: UsageProvider) -> ProviderTokenAccountData? {
        guard TokenAccountSupportCatalog.support(for: provider) != nil else { return nil }
        return self.configSnapshot.providerConfig(for: provider.instanceID)?.tokenAccounts
    }

    func tokenAccounts(for provider: UsageProvider) -> [ProviderTokenAccount] {
        self.tokenAccountsData(for: provider)?.accounts ?? []
    }

    func selectedTokenAccount(for provider: UsageProvider) -> ProviderTokenAccount? {
        guard let data = self.tokenAccountsData(for: provider), !data.accounts.isEmpty else { return nil }
        let index = data.clampedActiveIndex()
        return data.accounts[index]
    }

    /// Returns the saved account that currently owns provider fetches and account-scoped state.
    /// Cursor keeps saved manual credentials when browser login switches back to Automatic, but those credentials
    /// stay passive until the user explicitly selects one again.
    func effectiveSelectedTokenAccount(for provider: UsageProvider) -> ProviderTokenAccount? {
        let support = TokenAccountSupportCatalog.support(for: provider)
        if support?.passiveSourceModes.contains(self.providerConfig(for: provider)?.source ?? .auto) == true {
            return nil
        }
        if support?.selectedAccountRequiresManualCookieSource == true,
           (self.providerConfig(for: provider)?.cookieSource ?? .auto) == .auto
        {
            return nil
        }
        return self.selectedTokenAccount(for: provider)
    }

    func modelRateLimitScope(for provider: UsageProvider) -> ProviderModelRateLimitScope {
        if let account = self.effectiveSelectedTokenAccount(for: provider) {
            return .tokenAccount(account.id)
        }
        return .provider
    }

    func setActiveTokenAccountIndex(_ index: Int, for provider: UsageProvider) {
        guard let data = self.tokenAccountsData(for: provider), !data.accounts.isEmpty else { return }
        let clamped = min(max(index, 0), data.accounts.count - 1)
        let updated = ProviderTokenAccountData(
            version: data.version,
            accounts: data.accounts,
            activeIndex: clamped)
        self.updateProviderConfig(provider: provider) { entry in
            entry.tokenAccounts = updated
        }
        self.applyTokenAccountCookieSourceIfNeeded(provider: provider)
        CodexBarLog.logger(LogCategories.tokenAccounts).info(
            "Active token account updated",
            metadata: [
                "provider": provider.rawValue,
                "index": "\(clamped)",
            ])
    }

    func addTokenAccount(
        provider: UsageProvider,
        label: String,
        token: String,
        externalIdentifier: String? = nil,
        usageScope: String? = nil,
        organizationID: String? = nil,
        workspaceID: String? = nil,
        claudeConfigDirectory: String? = nil)
    {
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
            lastUsed: nil,
            externalIdentifier: Self.normalizedConfigField(externalIdentifier),
            usageScope: Self.normalizedConfigField(usageScope),
            organizationID: Self.normalizedConfigField(organizationID),
            workspaceID: Self.normalizedConfigField(workspaceID),
            claudeConfigDirectory: Self.normalizedConfigField(claudeConfigDirectory))
        let updated = ProviderTokenAccountData(
            version: existing?.version ?? 1,
            accounts: accounts + [account],
            activeIndex: accounts.count)
        self.updateProviderConfig(provider: provider) { entry in
            entry.tokenAccounts = updated
            if TokenAccountSupportCatalog.support(for: provider)?.clearsAPIKeyOnMutation == true {
                entry.apiKey = nil
            }
        }
        self.applyTokenAccountCookieSourceIfNeeded(provider: provider)
        CodexBarLog.logger(LogCategories.tokenAccounts).info(
            "Token account added",
            metadata: [
                "provider": provider.rawValue,
                "count": "\(updated.accounts.count)",
            ])
    }

    func updateTokenAccount(
        provider: UsageProvider,
        accountID: UUID,
        label: String? = nil,
        token: String? = nil,
        externalIdentifier: String?? = nil,
        usageScope: String?? = nil,
        organizationID: String?? = nil,
        workspaceID: String?? = nil,
        claudeConfigDirectory: String?? = nil,
        seatCreditEntitlement: String?? = nil)
    {
        guard let data = self.tokenAccountsData(for: provider), !data.accounts.isEmpty else { return }
        guard let index = data.accounts.firstIndex(where: { $0.id == accountID }) else { return }

        let trimmedLabel = label?.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedToken = token?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmedToken, trimmedToken.isEmpty {
            return
        }

        let existing = data.accounts[index]
        let updatesEffectiveAccount = self.effectiveSelectedTokenAccount(for: provider)?.id == accountID
        let updatedAccount = ProviderTokenAccount(
            id: existing.id,
            label: (trimmedLabel?.isEmpty == false) ? trimmedLabel! : existing.label,
            token: trimmedToken ?? existing.token,
            addedAt: existing.addedAt,
            lastUsed: existing.lastUsed,
            externalIdentifier: externalIdentifier.map(Self.normalizedConfigField) ?? existing.externalIdentifier,
            usageScope: usageScope.map(Self.normalizedConfigField) ?? existing.usageScope,
            organizationID: organizationID.map(Self.normalizedConfigField) ?? existing.organizationID,
            workspaceID: workspaceID.map(Self.normalizedConfigField) ?? existing.workspaceID,
            claudeConfigDirectory: claudeConfigDirectory.map(Self.normalizedConfigField)
                ?? existing.claudeConfigDirectory,
            seatCreditEntitlement: seatCreditEntitlement.map(Self.normalizedConfigField)
                ?? existing.seatCreditEntitlement,
            modelRateLimits: existing.modelRateLimits)

        var accounts = data.accounts
        accounts[index] = updatedAccount
        let updated = ProviderTokenAccountData(
            version: data.version,
            accounts: accounts,
            activeIndex: data.clampedActiveIndex())
        self.updateProviderConfig(provider: provider) { entry in
            entry.tokenAccounts = updated
            if TokenAccountSupportCatalog.support(for: provider)?.clearsAPIKeyOnMutation == true {
                entry.apiKey = nil
            }
        }
        // Editing a dormant saved account must not switch the provider away from its live source.
        if updatesEffectiveAccount {
            self.applyTokenAccountCookieSourceIfNeeded(provider: provider)
        }
        CodexBarLog.logger(LogCategories.tokenAccounts).info(
            "Token account updated",
            metadata: [
                "provider": provider.rawValue,
                "count": "\(updated.accounts.count)",
            ])
    }

    func moveTokenAccount(provider: UsageProvider, accountID: UUID, to destination: Int) {
        guard let data = self.tokenAccountsData(for: provider),
              data.accounts.indices.contains(destination),
              let source = data.accounts.firstIndex(where: { $0.id == accountID }),
              source != destination else { return }
        let activeID = data.accounts[data.clampedActiveIndex()].id
        var accounts = data.accounts
        accounts.insert(accounts.remove(at: source), at: destination)
        guard let activeIndex = accounts.firstIndex(where: { $0.id == activeID }) else { return }
        self.updateProviderConfig(provider: provider) { entry in
            entry.tokenAccounts = ProviderTokenAccountData(
                version: data.version, accounts: accounts, activeIndex: activeIndex)
        }
    }

    func removeTokenAccount(provider: UsageProvider, accountID: UUID) {
        guard let data = self.tokenAccountsData(for: provider), !data.accounts.isEmpty else { return }
        let activeAccountID = data.accounts[data.clampedActiveIndex()].id
        guard let removedIndex = data.accounts.firstIndex(where: { $0.id == accountID }) else { return }
        let removedAccount = data.accounts[removedIndex]
        let filtered = data.accounts.filter { $0.id != accountID }
        self.updateProviderConfig(provider: provider) { entry in
            if filtered.isEmpty {
                entry.tokenAccounts = nil
            } else {
                let nextActiveIndex = if activeAccountID != accountID,
                                         let preservedIndex = filtered.firstIndex(where: { $0.id == activeAccountID })
                {
                    preservedIndex
                } else {
                    min(removedIndex, filtered.count - 1)
                }
                entry.tokenAccounts = ProviderTokenAccountData(
                    version: data.version,
                    accounts: filtered,
                    activeIndex: nextActiveIndex)
            }
            if TokenAccountSupportCatalog.support(for: provider)?.clearsAPIKeyOnMutation == true {
                entry.apiKey = nil
            }
        }
        self.applyTokenAccountRemovalSideEffectsIfNeeded(
            provider: provider,
            removedAccount: removedAccount,
            remainingAccounts: filtered)
        CodexBarLog.logger(LogCategories.tokenAccounts).info(
            "Token account removed",
            metadata: [
                "provider": provider.rawValue,
                "count": "\(filtered.count)",
            ])
    }

    func reloadTokenAccounts() {
        self.reloadConfig(reason: "token-accounts", origin: .localFile)
    }

    func openTokenAccountsFile() {
        do {
            if !self.configNeedsReload {
                try Self.writeConfig(
                    self.config,
                    to: self.configStore,
                    watcher: self.configFileWatcher,
                    permit: self.configPersistenceCoordinator.makeWritePermit())
            }
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

    private func applyTokenAccountRemovalSideEffectsIfNeeded(
        provider: UsageProvider,
        removedAccount: ProviderTokenAccount,
        remainingAccounts: [ProviderTokenAccount])
    {
        // Provider-specific by design: removing the final Antigravity account must delete its shared OAuth cache.
        guard provider == .antigravity else { return }
        guard let removedCredentials = AntigravityOAuthCredentialsStore.credentials(
            fromTokenAccountValue: removedAccount.token)
        else {
            return
        }
        let hasMatchingRemainingAccount = remainingAccounts.contains { account in
            guard let credentials = AntigravityOAuthCredentialsStore.credentials(fromTokenAccountValue: account.token)
            else {
                return false
            }
            return Self.antigravityCredentialsMatchAccount(credentials, removedCredentials)
        }
        guard !hasMatchingRemainingAccount else { return }

        Self.clearMatchingAntigravitySharedCredentials(
            store: self.antigravityOAuthCredentialsStore,
            removedCredentials: removedCredentials)
    }

    private nonisolated static func clearMatchingAntigravitySharedCredentials(
        store: AntigravityOAuthCredentialsStore,
        removedCredentials: AntigravityOAuthCredentials)
    {
        do {
            try store.deleteIfPresent { sharedCredentials in
                self.antigravitySharedCredentialsMatchRemovedAccount(
                    sharedCredentials,
                    removedCredentials)
            }
        } catch {
            CodexBarLog.logger(LogCategories.tokenAccounts).warning(
                "Failed to clear Antigravity OAuth cache after account removal",
                metadata: ["error": error.localizedDescription])
        }
    }

    private nonisolated static func antigravitySharedCredentialsMatchRemovedAccount(
        _ shared: AntigravityOAuthCredentials,
        _ removed: AntigravityOAuthCredentials) -> Bool
    {
        if let sharedRefreshToken = self.normalizedConfigField(shared.refreshToken),
           let removedRefreshToken = self.normalizedConfigField(removed.refreshToken)
        {
            return sharedRefreshToken == removedRefreshToken
        }
        if let sharedAccessToken = self.normalizedConfigField(shared.accessToken),
           let removedAccessToken = self.normalizedConfigField(removed.accessToken)
        {
            return sharedAccessToken == removedAccessToken
        }
        guard self.normalizedConfigField(shared.refreshToken) == nil,
              self.normalizedConfigField(removed.refreshToken) == nil,
              self.normalizedConfigField(shared.accessToken) == nil,
              self.normalizedConfigField(removed.accessToken) == nil
        else {
            return false
        }
        return self.normalizedAntigravityAccountEmail(shared.resolvedAccountEmail)
            == self.normalizedAntigravityAccountEmail(removed.resolvedAccountEmail)
    }

    private nonisolated static func antigravityCredentialsMatchAccount(
        _ lhs: AntigravityOAuthCredentials,
        _ rhs: AntigravityOAuthCredentials) -> Bool
    {
        if let lhsEmail = self.normalizedAntigravityAccountEmail(lhs.resolvedAccountEmail),
           let rhsEmail = self.normalizedAntigravityAccountEmail(rhs.resolvedAccountEmail)
        {
            return lhsEmail == rhsEmail
        }
        if let lhsRefreshToken = self.normalizedConfigField(lhs.refreshToken),
           let rhsRefreshToken = self.normalizedConfigField(rhs.refreshToken)
        {
            return lhsRefreshToken == rhsRefreshToken
        }
        if let lhsAccessToken = self.normalizedConfigField(lhs.accessToken),
           let rhsAccessToken = self.normalizedConfigField(rhs.accessToken)
        {
            return lhsAccessToken == rhsAccessToken
        }
        return false
    }

    private nonisolated static func normalizedAntigravityAccountEmail(_ email: String?) -> String? {
        self.normalizedConfigField(email)?.lowercased()
    }
}
