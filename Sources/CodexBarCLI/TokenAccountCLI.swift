import CodexBarCore
import Commander
import Foundation

struct TokenAccountCLISelection {
    let label: String?
    let index: Int?
    let allAccounts: Bool

    var usesOverride: Bool {
        self.label != nil || self.index != nil || self.allAccounts
    }

    func providerSelectionError(_ providers: [UsageProvider]) -> String? {
        guard self.usesOverride else { return nil }
        guard providers.count == 1 else { return "account selection requires a single provider." }
        let provider = providers[0]
        // Provider-specific by design: Codex exposes reconciled live/managed accounts beyond token accounts.
        let includesReconciledAccounts = provider == .codex && self.allAccounts && self.label == nil && self
            .index == nil
        guard includesReconciledAccounts || TokenAccountSupportCatalog.support(for: provider) != nil else {
            return "\(provider.rawValue) does not support token accounts."
        }
        return nil
    }
}

enum TokenAccountCLIResolutionScope {
    case configuredAccounts
    case ambientAccount
}

enum TokenAccountCLIError: LocalizedError {
    case noAccounts(UsageProvider)
    case accountNotFound(UsageProvider, String)
    case indexOutOfRange(UsageProvider, Int, Int)
    case antigravityCLIAccountSelectionUnsupported

    var errorDescription: String? {
        switch self {
        case let .noAccounts(provider):
            "No token accounts configured for \(provider.rawValue)."
        case let .accountNotFound(provider, label):
            "No token account labeled '\(label)' for \(provider.rawValue)."
        case let .indexOutOfRange(provider, index, count):
            "Token account index \(index) out of range for \(provider.rawValue) (1-\(count))."
        case .antigravityCLIAccountSelectionUnsupported:
            "Antigravity CLI uses its local login and cannot select saved Google accounts. " +
                "Use --source auto or --source oauth with account selection."
        }
    }
}

struct TokenAccountCLIContext {
    let selection: TokenAccountCLISelection
    let config: CodexBarConfig
    let accountsByProvider: [UsageProvider: ProviderTokenAccountData]
    @ProcessEnvironment private var baseEnvironment: [String: String]
    private let managedCodexAccountStoreURL: URL?
    private let configStore: CodexBarConfigStore

    init(
        selection: TokenAccountCLISelection,
        config: CodexBarConfig,
        verbose _: Bool,
        resolutionScope: TokenAccountCLIResolutionScope = .configuredAccounts,
        baseEnvironment: [String: String] = ProcessInfo.processInfo.environment,
        managedCodexAccountStoreURL: URL? = nil,
        configStore: CodexBarConfigStore = CodexBarConfigStore()) throws
    {
        self.selection = selection
        self.config = config
        self.baseEnvironment = baseEnvironment
        self.managedCodexAccountStoreURL = managedCodexAccountStoreURL
        self.configStore = configStore
        self.accountsByProvider = switch resolutionScope {
        case .configuredAccounts:
            Dictionary(uniqueKeysWithValues: config.providers.compactMap { provider in
                guard let firstPartyProvider = provider.id.firstPartyProvider,
                      let accounts = provider.tokenAccounts
                else { return nil }
                return (firstPartyProvider, accounts)
            })
        case .ambientAccount:
            [:]
        }
    }

    func resolvedAccounts(
        for provider: UsageProvider, sourceMode: ProviderSourceMode? = nil) throws -> [ProviderTokenAccount]
    {
        guard let support = TokenAccountSupportCatalog.support(for: provider) else { return [] }
        let effectiveSourceMode = sourceMode ?? self.preferredSourceMode(for: provider)
        // Provider-specific by design: agy owns its login; saved Google accounts cannot select its local identity.
        if provider == .antigravity, effectiveSourceMode == .cli, self.selection.usesOverride {
            throw TokenAccountCLIError.antigravityCLIAccountSelectionUnsupported
        }
        if !self.selection.usesOverride,
           support.passiveSourceModes.contains(effectiveSourceMode)
        {
            return []
        }
        guard let data = self.accountsByProvider[provider], !data.accounts.isEmpty else {
            if self.selection.usesOverride {
                throw TokenAccountCLIError.noAccounts(provider)
            }
            return []
        }

        if self.selection.allAccounts {
            return data.accounts
        }

        if let label = self.selection.label?.trimmingCharacters(in: .whitespacesAndNewlines), !label.isEmpty {
            let normalized = label.lowercased()
            if let match = data.accounts.first(where: { $0.label.lowercased() == normalized }) {
                return [match]
            }
            throw TokenAccountCLIError.accountNotFound(provider, label)
        }

        if let index = self.selection.index {
            guard index >= 0, index < data.accounts.count else {
                throw TokenAccountCLIError.indexOutOfRange(provider, index + 1, data.accounts.count)
            }
            return [data.accounts[index]]
        }

        let clamped = data.clampedActiveIndex()
        return [data.accounts[clamped]]
    }

    func settingsSnapshot(
        for provider: UsageProvider,
        account: ProviderTokenAccount?,
        codexActiveSourceOverride: CodexActiveSource? = nil) -> ProviderSettingsSnapshot?
    {
        let config = self.providerConfig(for: provider)
        // Provider-specific by design: managed Codex profiles require live reconciliation state that is not config.
        if provider == .codex {
            return ProviderSettingsSnapshot.make(codex: self.makeCodexSettingsSnapshot(
                account: account,
                codexActiveSourceOverride: codexActiveSourceOverride))
        }
        guard let contribution = ProviderDescriptorRegistry.descriptor(for: provider)
            .settingsSection
            .credentialContribution(context: ProviderCredentialSettingsContext(config: config, account: account))
        else { return nil }
        return ProviderSettingsSnapshot(contributions: [contribution])
    }

    private func makeCodexSettingsSnapshot(
        account: ProviderTokenAccount?,
        codexActiveSourceOverride: CodexActiveSource? = nil) ->
        ProviderSettingsSnapshot.CodexProviderSettings
    {
        // Provider-specific by design: Codex settings include reconciliation state and profile-home selection.
        let config = self.providerConfig(for: .codex)
        let reconciliationSnapshot = self.codexAccountReconciler(
            activeSource: codexActiveSourceOverride).loadSnapshot()
        let resolvedActiveSource = CodexActiveSourceResolver.resolve(from: reconciliationSnapshot)
        let cookieSettings = ProviderCredentialSettingsContext(config: config, account: account)
            .cookieSettings(for: .codex)
        return CodexProviderSettingsBuilder.make(input: CodexProviderSettingsBuilderInput(
            usageDataSource: .auto,
            cookieSource: cookieSettings.cookieSource,
            manualCookieHeader: cookieSettings.manualCookieHeader,
            reconciliationSnapshot: reconciliationSnapshot,
            resolvedActiveSource: resolvedActiveSource))
    }

    func environment(
        base: [String: String],
        provider: UsageProvider,
        account: ProviderTokenAccount?,
        codexActiveSourceOverride: CodexActiveSource? = nil) -> [String: String]
    {
        let providerConfig = self.providerConfig(for: provider)
        var env = ProviderEnvironmentResolver.resolve(
            base: base,
            provider: provider,
            config: providerConfig,
            selectedAccount: account)
        // Provider-specific by design: managed Codex accounts select a distinct filesystem home, not a credential.
        if provider == .codex,
           let codexHomePath = self.codexHomePath(for: codexActiveSourceOverride)
        {
            env = CodexHomeScope.scopedEnvironment(base: env, codexHome: codexHomePath)
        }
        return env
    }

    func tokenUpdater(for account: ProviderTokenAccount?) -> ProviderFetchContext.TokenAccountTokenUpdater? {
        guard let account else { return nil }
        let writeback = TokenAccountCLIWriteback(account: account, store: self.configStore)
        return { provider, accountID, token in
            await writeback.update(provider: provider, accountID: accountID, token: token)
        }
    }

    func manualTokenUpdater() -> ProviderFetchContext.ProviderManualTokenUpdater {
        { provider, token in
            try? ProviderDescriptorRegistry.descriptor(for: provider).credentials?.persistManualToken(token)
        }
    }

    @discardableResult
    static func updateStoredTokenAccount(
        store: CodexBarConfigStore,
        provider: UsageProvider,
        accountID: UUID,
        expectedToken: String,
        token: String) throws -> Bool
    {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        var didUpdate = false
        try store.updateIfAvailable { config in
            guard var providerConfig = config.providerConfig(for: provider.instanceID),
                  let data = providerConfig.tokenAccounts,
                  let index = data.accounts.firstIndex(where: { $0.id == accountID })
            else {
                return false
            }

            let existing = data.accounts[index]
            guard existing.token == expectedToken else {
                CodexBarLog.logger(LogCategories.tokenAccounts).warning(
                    "Skipped token account writeback: the stored credential changed during the fetch",
                    metadata: ["provider": provider.rawValue])
                return false
            }
            var accounts = data.accounts
            accounts[index] = ProviderTokenAccount(
                id: existing.id,
                label: existing.label,
                token: trimmed,
                addedAt: existing.addedAt,
                lastUsed: existing.lastUsed,
                externalIdentifier: existing.externalIdentifier,
                usageScope: existing.usageScope,
                organizationID: existing.organizationID,
                workspaceID: existing.workspaceID,
                seatCreditEntitlement: existing.seatCreditEntitlement)
            providerConfig.tokenAccounts = ProviderTokenAccountData(
                version: data.version,
                accounts: accounts,
                activeIndex: data.clampedActiveIndex())
            config.setProviderConfig(providerConfig)
            didUpdate = true
            return true
        }
        return didUpdate
    }

    func fetcher(base: UsageFetcher, provider: UsageProvider, env: [String: String]) -> UsageFetcher {
        // Provider-specific by design: UsageFetcher owns Codex filesystem scopes and must be rebuilt with CODEX_HOME.
        guard provider == .codex else { return base }
        return UsageFetcher(environment: env)
    }

    func visibleCodexAccounts() -> CodexVisibleAccountProjection {
        // Provider-specific by design: only Codex exposes reconciled live, managed, and profile-home accounts.
        self.codexAccountReconciler().loadVisibleAccounts()
    }

    func applyCodexVisibleAccountLabel(_ snapshot: UsageSnapshot, account: CodexVisibleAccount) -> UsageSnapshot {
        // Provider-specific by design: reconciled Codex accounts carry workspace labels outside token-account config.
        let existing = snapshot.identity(for: .codex)
        let identity = ProviderIdentitySnapshot(
            providerID: .codex,
            accountEmail: account.email,
            accountOrganization: account.workspaceLabel ?? existing?.accountOrganization,
            loginMethod: existing?.loginMethod)
        return snapshot.withIdentity(identity)
    }

    func effectiveSourceMode(
        base: ProviderSourceMode,
        provider: UsageProvider,
        account: ProviderTokenAccount?) -> ProviderSourceMode
    {
        let config = self.providerConfig(for: provider)
        return ProviderDescriptorRegistry.descriptor(for: provider).credentials?
            .selectedAccountSourceMode(base: base, account: account, config: config) ?? base
    }

    func preferredSourceMode(for provider: UsageProvider) -> ProviderSourceMode {
        let config = self.providerConfig(for: provider)
        return config?.source ?? .auto
    }

    private func providerConfig(for provider: UsageProvider) -> ProviderConfig? {
        self.config.providerConfig(for: provider.instanceID)
    }

    private func codexAccountReconciler(activeSource: CodexActiveSource? = nil) -> DefaultCodexAccountReconciler {
        // Provider-specific by design: this reconciles Codex profile homes with its managed-account store.
        let storeLoader: @Sendable () throws -> ManagedCodexAccountSet = if let managedCodexAccountStoreURL {
            {
                try FileManagedCodexAccountStore(fileURL: managedCodexAccountStoreURL).loadAccounts()
            }
        } else {
            {
                try FileManagedCodexAccountStore().loadAccounts()
            }
        }
        return DefaultCodexAccountReconciler(
            storeLoader: storeLoader,
            activeSource: activeSource ?? self.providerConfig(for: .codex)?.codexActiveSource ?? .liveSystem,
            baseEnvironment: self.baseEnvironment,
            profileHomePaths: self.providerConfig(for: .codex)?.codexProfileHomePaths ?? [],
            managedEnvironmentBuilder: { environment, account in
                CodexHomeScope.scopedEnvironment(base: environment, codexHome: account.managedHomePath)
            })
    }

    private func codexHomePath(for activeSourceOverride: CodexActiveSource?) -> String? {
        // Provider-specific by design: Codex profile selection changes the local data root for the whole fetcher.
        let activeSource: CodexActiveSource = if let activeSourceOverride {
            activeSourceOverride
        } else {
            CodexActiveSourceResolver.resolve(from: self.codexAccountReconciler().loadSnapshot())
                .resolvedSource
        }

        switch activeSource {
        case .liveSystem:
            return nil
        case let .managedAccount(id):
            let accounts: ManagedCodexAccountSet? = if let managedCodexAccountStoreURL {
                try? FileManagedCodexAccountStore(fileURL: managedCodexAccountStoreURL).loadAccounts()
            } else {
                try? FileManagedCodexAccountStore().loadAccounts()
            }
            return accounts?.account(id: id)?.managedHomePath
        case let .profileHome(path):
            guard let normalizedPath = CodexHomeScope.normalizedHomePath(path) else { return nil }
            let configuredPaths = self.providerConfig(for: .codex)?.codexProfileHomePaths ?? []
            return configuredPaths.contains {
                CodexHomeScope.normalizedHomePath($0) == normalizedPath
            } ? normalizedPath : nil
        }
    }
}

/// A fetch may persist a refreshed token and then discovered account metadata.
private actor TokenAccountCLIWriteback {
    private let accountID: UUID
    private let store: CodexBarConfigStore
    private var expectedToken: String

    init(account: ProviderTokenAccount, store: CodexBarConfigStore) {
        self.accountID = account.id
        self.store = store
        self.expectedToken = account.token
    }

    func update(provider: UsageProvider, accountID: UUID, token: String) {
        guard accountID == self.accountID else { return }
        if (try? TokenAccountCLIContext.updateStoredTokenAccount(
            store: self.store,
            provider: provider,
            accountID: accountID,
            expectedToken: self.expectedToken,
            token: token)) == true
        {
            self.expectedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
}
