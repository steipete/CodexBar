import CodexBarCore
import Foundation

extension SettingsStore {
    var antigravityUsageSource: AntigravityUsageSource {
        get {
            guard let rawValue = self.configSnapshot.providerConfig(for: .antigravity)?.usageSource else {
                return .auto
            }
            return AntigravityUsageSource(rawValue: rawValue) ?? .auto
        }
        set {
            self.updateProviderConfig(provider: .antigravity) { entry in
                entry.usageSource = newValue.rawValue
            }
            self.logProviderModeChange(provider: .antigravity, field: "usageSource", value: newValue.rawValue)
        }
    }
}

extension SettingsStore {
    func antigravitySettingsSnapshot(
        tokenOverride: TokenAccountOverride?) -> ProviderSettingsSnapshot.AntigravityProviderSettings
    {
        let account = ProviderTokenAccountSelection.selectedAccount(
            provider: .antigravity,
            settings: self,
            override: tokenOverride)
        let tokenAccounts = self.tokenAccountsData(for: .antigravity)
        return ProviderSettingsSnapshot.AntigravityProviderSettings(
            usageSource: self.antigravityUsageSource,
            accountLabel: account?.label,
            tokenAccounts: tokenAccounts)
    }

    func upsertAntigravityTokenAccount(label: String) -> ProviderTokenAccount? {
        guard let normalized = AntigravityOAuthCredentialsStore.normalizedLabel(label) else { return nil }
        let tokenValue = normalized
        let existing = self.tokenAccountsData(for: .antigravity)
        var accounts = existing?.accounts ?? []
        if let index = accounts.firstIndex(where: { $0.label.lowercased() == normalized }) {
            let current = accounts[index]
            let updated = ProviderTokenAccount(
                id: current.id,
                label: normalized,
                token: tokenValue,
                addedAt: current.addedAt,
                lastUsed: current.lastUsed)
            accounts[index] = updated
            let updatedData = ProviderTokenAccountData(
                version: existing?.version ?? 1,
                accounts: accounts,
                activeIndex: index)
            self.updateProviderConfig(provider: .antigravity) { entry in
                entry.tokenAccounts = updatedData
            }
            return updated
        }

        let account = ProviderTokenAccount(
            id: UUID(),
            label: normalized,
            token: tokenValue,
            addedAt: Date().timeIntervalSince1970,
            lastUsed: nil)
        let updatedData = ProviderTokenAccountData(
            version: existing?.version ?? 1,
            accounts: accounts + [account],
            activeIndex: accounts.count)
        self.updateProviderConfig(provider: .antigravity) { entry in
            entry.tokenAccounts = updatedData
        }
        return account
    }

    func removeAntigravityTokenAccount(accountID: UUID) {
        guard let data = self.tokenAccountsData(for: .antigravity) else { return }
        guard let removed = data.accounts.first(where: { $0.id == accountID }) else { return }
        self.removeTokenAccount(provider: .antigravity, accountID: accountID)
        if !KeychainAccessGate.isDisabled {
            AntigravityOAuthCredentialsStore.clear(accountLabel: removed.label)
        }
    }

    func addManualAntigravityTokenAccount(
        label: String,
        accessToken: String,
        refreshToken: String? = nil,
        expiresAt: Date? = nil) -> ProviderTokenAccount?
    {
        guard let normalizedLabel = AntigravityOAuthCredentialsStore.normalizedLabel(label) else { return nil }

        let tokenValue: String
        if !KeychainAccessGate.isDisabled {
            let credentials = AntigravityOAuthCredentials(
                accessToken: accessToken,
                refreshToken: refreshToken,
                expiresAt: expiresAt,
                email: normalizedLabel,
                scopes: [])
            guard AntigravityOAuthCredentialsStore.save(credentials, accountLabel: normalizedLabel) else {
                return nil
            }
            tokenValue = normalizedLabel
        } else {
            tokenValue = AntigravityOAuthCredentialsStore.manualTokenValue(
                accessToken: accessToken,
                refreshToken: refreshToken,
                expiresAt: expiresAt)
        }

        let existing = self.tokenAccountsData(for: .antigravity)
        var accounts = existing?.accounts ?? []

        if let index = accounts.firstIndex(where: { $0.label.lowercased() == normalizedLabel }) {
            let current = accounts[index]
            let updated = ProviderTokenAccount(
                id: current.id,
                label: normalizedLabel,
                token: tokenValue,
                addedAt: current.addedAt,
                lastUsed: current.lastUsed)
            accounts[index] = updated
            let updatedData = ProviderTokenAccountData(
                version: existing?.version ?? 1,
                accounts: accounts,
                activeIndex: index)
            self.updateProviderConfig(provider: .antigravity) { entry in
                entry.tokenAccounts = updatedData
            }
            self.triggerBackgroundRefreshIfNeeded(
                label: label,
                refreshToken: refreshToken,
                expiresAt: expiresAt)
            return updated
        }

        let account = ProviderTokenAccount(
            id: UUID(),
            label: normalizedLabel,
            token: tokenValue,
            addedAt: Date().timeIntervalSince1970,
            lastUsed: nil)
        let updatedData = ProviderTokenAccountData(
            version: existing?.version ?? 1,
            accounts: accounts + [account],
            activeIndex: accounts.count)
        self.updateProviderConfig(provider: .antigravity) { entry in
            entry.tokenAccounts = updatedData
        }
        self.triggerBackgroundRefreshIfNeeded(
            label: label,
            refreshToken: refreshToken,
            expiresAt: expiresAt)
        return account
    }

    private func triggerBackgroundRefreshIfNeeded(
        label: String,
        refreshToken: String?,
        expiresAt: Date?)
    {
        guard let refreshToken, !refreshToken.isEmpty, expiresAt == nil else { return }
        guard let normalizedLabel = AntigravityOAuthCredentialsStore.normalizedLabel(label) else { return }

        Task {
            guard let refreshed = try? await AntigravityTokenRefresher.buildCredentialsFromRefreshToken(
                refreshToken: refreshToken,
                fallbackEmail: normalizedLabel) else { return }
            _ = self.addManualAntigravityTokenAccount(
                label: label,
                accessToken: refreshed.accessToken,
                refreshToken: refreshed.refreshToken,
                expiresAt: refreshed.expiresAt)
        }
    }
}
