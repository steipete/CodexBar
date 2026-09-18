import CodexBarCore
import Foundation

extension SettingsStore {
    var grokUsageDataSource: ProviderSourceMode {
        get { self.configSnapshot.providerConfig(for: .grok)?.source ?? .auto }
        set {
            self.updateProviderConfig(provider: .grok) { entry in
                entry.source = newValue == .auto ? nil : newValue
            }
            self.logProviderModeChange(provider: .grok, field: "source", value: newValue.rawValue)
        }
    }

    var grokCookieHeader: String {
        get { self[providerConfig: .grok, field: .cookieHeader] }
        set { self[providerConfig: .grok, field: .cookieHeader] = newValue }
    }

    var grokCookieSource: ProviderCookieSource {
        get { self.resolvedCookieSource(provider: .grok, fallback: .auto) }
        set { self.setCookieSource(newValue, provider: .grok) }
    }
}

extension SettingsStore {
    func grokSettingsSnapshot(tokenOverride: TokenAccountOverride?)
        -> ProviderSettingsSnapshot
        .GrokProviderSettings
    {
        let account = ProviderTokenAccountSelection.selectedAccount(
            provider: .grok,
            settings: self,
            override: tokenOverride)
        let resolved = GrokCredentialRouting.cookieSettings(
            configuredSource: self.grokCookieSource,
            configuredHeader: self.grokCookieHeader,
            selectedAccountToken: account?.token)
        return GrokProviderSettings(
            cookieSource: resolved.cookieSource,
            manualCookieHeader: resolved.manualCookieHeader)
    }
}

extension SettingsStore {
    var grokPersistedActiveSource: GrokActiveSource {
        self.providerConfig(for: .grok)?.grokActiveSource ?? .liveSystem
    }

    var grokActiveSource: GrokActiveSource {
        get { self.grokPersistedActiveSource }
        set {
            self.updateProviderConfig(provider: .grok) { entry in
                entry.grokActiveSource = newValue
            }
        }
    }

    var grokResolvedActiveSource: GrokActiveSource {
        GrokActiveSourceResolver.resolve(
            persistedSource: self.grokPersistedActiveSource,
            liveAccount: self.grokVisibleAccountProjection.account(id: GrokVisibleAccount.liveAccountID),
            managedAccounts: self.grokManagedAccounts)
    }

    var grokManagedAccounts: [ManagedGrokAccount] {
        (try? FileManagedGrokAccountStore().loadAccounts())?.accounts ?? []
    }

    var grokManagedAccountStoreIsUnreadable: Bool {
        do {
            _ = try FileManagedGrokAccountStore().loadAccounts()
            return false
        } catch {
            return true
        }
    }

    var grokVisibleAccountProjection: GrokVisibleAccountProjection {
        let liveHome = GrokHomeScope.ambientHomeURL(env: self.grokLiveEnvironment)
        let liveEmail = (try? GrokCredentialsStore.load(env: self.grokLiveEnvironment))?.email
        return GrokVisibleAccountProjectionFactory.make(
            liveEmail: liveEmail,
            liveHomePath: liveHome.path,
            managedAccounts: self.grokManagedAccounts,
            persistedSource: self.grokPersistedActiveSource,
            hasUnreadableAddedAccountStore: self.grokManagedAccountStoreIsUnreadable)
    }

    var grokLiveEnvironment: [String: String] {
        var env = ProcessInfo.processInfo.environment
        env.removeValue(forKey: "GROK_HOME")
        env.removeValue(forKey: GrokSettingsReader.oauthTokenEnvironmentKey)
        return env
    }

    func grokHomePath(forActiveSource source: GrokActiveSource) -> String? {
        switch source {
        case .liveSystem:
            GrokHomeScope.ambientHomeURL(env: self.grokLiveEnvironment).path
        case let .managedAccount(id):
            self.grokManagedAccounts.first { $0.id == id }.flatMap {
                GrokHomeScope.normalizedHomePath($0.managedHomePath)
            }
        }
    }

    @discardableResult
    func persistResolvedGrokActiveSourceCorrectionIfNeeded() -> Bool {
        let resolved = self.grokResolvedActiveSource
        guard resolved != self.grokPersistedActiveSource else { return false }
        self.grokActiveSource = resolved
        return true
    }

    @discardableResult
    func refreshGrokAccountsAfterManagedAccountsDidChange() -> Bool {
        self.persistResolvedGrokActiveSourceCorrectionIfNeeded()
    }

    @discardableResult
    func selectGrokVisibleAccount(id: String) -> Bool {
        guard let account = self.grokVisibleAccountProjection.account(id: id) else { return false }
        self.grokActiveSource = account.selectionSource
        return true
    }

    func selectAuthenticatedManagedGrokAccount(_ account: ManagedGrokAccount) {
        self.grokActiveSource = .managedAccount(id: account.id)
    }
}
