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

    func selectedTokenAccount(for provider: UsageProvider) -> ProviderTokenAccount? {
        guard let data = self.tokenAccountsData(for: provider), !data.accounts.isEmpty else { return nil }
        let index = data.clampedActiveIndex()
        return data.accounts[index]
    }

    /// Returns the saved account that currently owns provider fetches and account-scoped state.
    /// Cursor keeps saved manual credentials when browser login switches back to Automatic, but those credentials
    /// stay passive until the user explicitly selects one again.
    func effectiveSelectedTokenAccount(for provider: UsageProvider) -> ProviderTokenAccount? {
        if provider == .cursor, self.cursorCookieSource == .auto {
            return nil
        }
        return self.selectedTokenAccount(for: provider)
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
        workspaceID: String? = nil)
    {
        guard TokenAccountSupportCatalog.support(for: provider) != nil else { return }
        let trimmedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedToken.isEmpty else { return }
        let trimmedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedIdentifier = externalIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalisedIdentifier = (trimmedIdentifier?.isEmpty ?? true) ? nil : trimmedIdentifier
        let trimmedUsageScope = usageScope?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalisedUsageScope = (trimmedUsageScope?.isEmpty ?? true) ? nil : trimmedUsageScope
        let trimmedOrganizationID = organizationID?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalisedOrganizationID = (trimmedOrganizationID?.isEmpty ?? true) ? nil : trimmedOrganizationID
        let trimmedWorkspaceID = workspaceID?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalisedWorkspaceID = (trimmedWorkspaceID?.isEmpty ?? true) ? nil : trimmedWorkspaceID
        let existing = self.tokenAccountsData(for: provider)
        let accounts = existing?.accounts ?? []
        let fallbackLabel = trimmedLabel.isEmpty ? "Account \(accounts.count + 1)" : trimmedLabel
        let account = ProviderTokenAccount(
            id: UUID(),
            label: fallbackLabel,
            token: trimmedToken,
            addedAt: Date().timeIntervalSince1970,
            lastUsed: nil,
            externalIdentifier: normalisedIdentifier,
            usageScope: normalisedUsageScope,
            organizationID: normalisedOrganizationID,
            workspaceID: normalisedWorkspaceID)
        let updated = ProviderTokenAccountData(
            version: existing?.version ?? 1,
            accounts: accounts + [account],
            activeIndex: accounts.count)
        self.updateProviderConfig(provider: provider) { entry in
            entry.tokenAccounts = updated
            if provider == .copilot {
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
        workspaceID: String?? = nil)
    {
        guard let data = self.tokenAccountsData(for: provider), !data.accounts.isEmpty else { return }
        guard let index = data.accounts.firstIndex(where: { $0.id == accountID }) else { return }

        let trimmedLabel = label?.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedToken = token?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmedToken, trimmedToken.isEmpty { return }

        let existing = data.accounts[index]
        let resolvedIdentifier: String?
        if let externalIdentifier {
            let trimmed = externalIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines)
            resolvedIdentifier = (trimmed?.isEmpty ?? true) ? nil : trimmed
        } else {
            resolvedIdentifier = existing.externalIdentifier
        }
        let resolvedUsageScope: String?
        if let usageScope {
            let trimmed = usageScope?.trimmingCharacters(in: .whitespacesAndNewlines)
            resolvedUsageScope = (trimmed?.isEmpty ?? true) ? nil : trimmed
        } else {
            resolvedUsageScope = existing.usageScope
        }
        let resolvedOrganizationID: String?
        if let organizationID {
            let trimmed = organizationID?.trimmingCharacters(in: .whitespacesAndNewlines)
            resolvedOrganizationID = (trimmed?.isEmpty ?? true) ? nil : trimmed
        } else {
            resolvedOrganizationID = existing.organizationID
        }
        let resolvedWorkspaceID: String?
        if let workspaceID {
            let trimmed = workspaceID?.trimmingCharacters(in: .whitespacesAndNewlines)
            resolvedWorkspaceID = (trimmed?.isEmpty ?? true) ? nil : trimmed
        } else {
            resolvedWorkspaceID = existing.workspaceID
        }
        let updatedAccount = ProviderTokenAccount(
            id: existing.id,
            label: (trimmedLabel?.isEmpty == false) ? trimmedLabel! : existing.label,
            token: trimmedToken ?? existing.token,
            addedAt: existing.addedAt,
            lastUsed: existing.lastUsed,
            externalIdentifier: resolvedIdentifier,
            usageScope: resolvedUsageScope,
            organizationID: resolvedOrganizationID,
            workspaceID: resolvedWorkspaceID)

        var accounts = data.accounts
        accounts[index] = updatedAccount
        let updated = ProviderTokenAccountData(
            version: data.version,
            accounts: accounts,
            activeIndex: data.clampedActiveIndex())
        self.updateProviderConfig(provider: provider) { entry in
            entry.tokenAccounts = updated
            if provider == .copilot {
                entry.apiKey = nil
            }
        }
        self.applyTokenAccountCookieSourceIfNeeded(provider: provider)
        CodexBarLog.logger(LogCategories.tokenAccounts).info(
            "Token account updated",
            metadata: [
                "provider": provider.rawValue,
                "count": "\(updated.accounts.count)",
            ])
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
            if provider == .copilot {
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

    private func applyTokenAccountRemovalSideEffectsIfNeeded(
        provider: UsageProvider,
        removedAccount: ProviderTokenAccount,
        remainingAccounts: [ProviderTokenAccount])
    {
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
        if let sharedRefreshToken = self.normalizedAntigravityCredentialToken(shared.refreshToken),
           let removedRefreshToken = self.normalizedAntigravityCredentialToken(removed.refreshToken)
        {
            return sharedRefreshToken == removedRefreshToken
        }
        if let sharedAccessToken = self.normalizedAntigravityCredentialToken(shared.accessToken),
           let removedAccessToken = self.normalizedAntigravityCredentialToken(removed.accessToken)
        {
            return sharedAccessToken == removedAccessToken
        }
        guard self.normalizedAntigravityCredentialToken(shared.refreshToken) == nil,
              self.normalizedAntigravityCredentialToken(removed.refreshToken) == nil,
              self.normalizedAntigravityCredentialToken(shared.accessToken) == nil,
              self.normalizedAntigravityCredentialToken(removed.accessToken) == nil
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
        if let lhsRefreshToken = self.normalizedAntigravityCredentialToken(lhs.refreshToken),
           let rhsRefreshToken = self.normalizedAntigravityCredentialToken(rhs.refreshToken)
        {
            return lhsRefreshToken == rhsRefreshToken
        }
        if let lhsAccessToken = self.normalizedAntigravityCredentialToken(lhs.accessToken),
           let rhsAccessToken = self.normalizedAntigravityCredentialToken(rhs.accessToken)
        {
            return lhsAccessToken == rhsAccessToken
        }
        return false
    }

    private nonisolated static func normalizedAntigravityAccountEmail(_ email: String?) -> String? {
        guard let value = email?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !value.isEmpty
        else {
            return nil
        }
        return value
    }

    private nonisolated static func normalizedAntigravityCredentialToken(_ token: String?) -> String? {
        guard let value = token?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty
        else {
            return nil
        }
        return value
    }
}
