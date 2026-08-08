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
}

enum TokenAccountCLIResolutionScope {
    case configuredAccounts
    case ambientAccount
}

enum TokenAccountCLIError: LocalizedError {
    case noAccounts(UsageProvider)
    case accountNotFound(UsageProvider, String)
    case indexOutOfRange(UsageProvider, Int, Int)

    var errorDescription: String? {
        switch self {
        case let .noAccounts(provider):
            "No token accounts configured for \(provider.rawValue)."
        case let .accountNotFound(provider, label):
            "No token account labeled '\(label)' for \(provider.rawValue)."
        case let .indexOutOfRange(provider, index, count):
            "Token account index \(index) out of range for \(provider.rawValue) (1-\(count))."
        }
    }
}

struct TokenAccountCLIContext {
    let selection: TokenAccountCLISelection
    let config: CodexBarConfig
    let accountsByProvider: [UsageProvider: ProviderTokenAccountData]
    private let baseEnvironment: [String: String]
    private let managedCodexAccountStoreURL: URL?

    init(
        selection: TokenAccountCLISelection,
        config: CodexBarConfig,
        verbose _: Bool,
        resolutionScope: TokenAccountCLIResolutionScope = .configuredAccounts,
        baseEnvironment: [String: String] = ProcessInfo.processInfo.environment,
        managedCodexAccountStoreURL: URL? = nil) throws
    {
        self.selection = selection
        self.config = config
        self.baseEnvironment = baseEnvironment
        self.managedCodexAccountStoreURL = managedCodexAccountStoreURL
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

    func resolvedAccounts(for provider: UsageProvider) throws -> [ProviderTokenAccount] {
        guard TokenAccountSupportCatalog.support(for: provider) != nil else { return [] }
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
        return { provider, accountID, token in
            guard accountID == account.id else { return }
            try? Self.updateStoredTokenAccount(provider: provider, accountID: accountID, token: token)
        }
    }

    func manualTokenUpdater() -> ProviderFetchContext.ProviderManualTokenUpdater {
        { provider, token in
            try? ProviderDescriptorRegistry.descriptor(for: provider).credentials?.persistManualToken(token)
        }
    }

    private static func updateStoredTokenAccount(
        provider: UsageProvider,
        accountID: UUID,
        token: String) throws
    {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let store = CodexBarConfigStore()
        guard var config = try store.load() else { return }
        guard var providerConfig = config.providerConfig(for: provider.instanceID),
              let data = providerConfig.tokenAccounts,
              let index = data.accounts.firstIndex(where: { $0.id == accountID })
        else {
            return
        }

        let existing = data.accounts[index]
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
            seatCreditEntitlement: existing.seatCreditEntitlement,
            orgCreditEntitlement: existing.orgCreditEntitlement)
        providerConfig.tokenAccounts = ProviderTokenAccountData(
            version: data.version,
            accounts: accounts,
            activeIndex: data.clampedActiveIndex())
        config.setProviderConfig(providerConfig)
        try store.save(config)
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

    func applyAccountLabel(
        _ snapshot: UsageSnapshot,
        provider: UsageProvider,
        account: ProviderTokenAccount) -> UsageSnapshot
    {
        let label = account.label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty else { return snapshot }
        let existing = snapshot.identity(for: provider.instanceID)
        let email = existing?.accountEmail?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedEmail = (email?.isEmpty ?? true) ? label : email
        let identity = ProviderIdentitySnapshot(
            providerID: provider.instanceID,
            accountEmail: resolvedEmail,
            accountOrganization: existing?.accountOrganization,
            loginMethod: existing?.loginMethod)
        return snapshot.withIdentity(identity)
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
