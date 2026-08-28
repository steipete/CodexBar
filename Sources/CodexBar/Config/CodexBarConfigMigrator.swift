import CodexBarCore
import Foundation

struct CodexBarConfigMigrator {
    struct LegacyStores {
        let zaiTokenStore: any ZaiTokenStoring
        let syntheticTokenStore: any SyntheticTokenStoring
        let codexCookieStore: any CookieHeaderStoring
        let claudeCookieStore: any CookieHeaderStoring
        let cursorCookieStore: any CookieHeaderStoring
        let opencodeCookieStore: any CookieHeaderStoring
        let factoryCookieStore: any CookieHeaderStoring
        let minimaxCookieStore: any MiniMaxCookieStoring
        let minimaxAPITokenStore: any MiniMaxAPITokenStoring
        let kimiTokenStore: any KimiTokenStoring
        let augmentCookieStore: any CookieHeaderStoring
        let ampCookieStore: any CookieHeaderStoring
        let copilotTokenStore: any CopilotTokenStoring
        let tokenAccountStore: any ProviderTokenAccountStoring
    }

    private static let legacyMigrationCompletedKey = "codexbar.legacySecretsMigrationCompleted"

    private struct MigrationState {
        var didUpdate = false
        var sawLegacySecrets = false
        var sawLegacyAccounts = false
        var legacyLoadFailures: [String] = []
    }

    static func loadOrMigrate(
        configStore: CodexBarConfigStore,
        userDefaults: UserDefaults,
        stores: LegacyStores) -> CodexBarConfig
    {
        let log = CodexBarLog.logger(LogCategories.configMigration)
        let existing = try? configStore.load()
        var config = (existing ?? CodexBarConfig.makeDefault()).normalized()
        var state = MigrationState()

        // applyLegacyCookieSources reads only UserDefaults — cheap, runs unconditionally so
        // newly-added cookie-source keys are picked up on every launch.
        self.applyLegacyCookieSources(userDefaults: userDefaults, config: &config, state: &state)
        self.bindLegacyMoonshotAPIKeyRegion(config: &config, state: &state)

        let migrationCompleted = userDefaults.bool(forKey: Self.legacyMigrationCompletedKey)
        if !migrationCompleted {
            // Run once: migrate Keychain/file secrets then clear them. Using a completion flag rather
            // than `existing == nil` ensures a crash between config-save and clearLegacyStores can
            // finish cleanup on the next launch without re-doing the (already-saved) data migration.
            if existing == nil {
                self.applyLegacyOrderAndToggles(userDefaults: userDefaults, config: &config, state: &state)
            }
            self.migrateLegacySecrets(
                userDefaults: userDefaults,
                stores: stores,
                config: &config,
                state: &state,
                log: log)
            self.migrateLegacyAccounts(stores: stores, config: &config, state: &state, log: log)
        }

        var didPersistUpdates = true
        if state.didUpdate {
            do {
                try configStore.save(config)
            } catch {
                didPersistUpdates = false
                log.error("Failed to persist config: \(error)")
            }
        }

        guard didPersistUpdates else {
            return config.normalized()
        }

        guard state.legacyLoadFailures.isEmpty else {
            log.error(
                "Legacy migration deferred because one or more sources were unreadable",
                metadata: ["stores": state.legacyLoadFailures.joined(separator: ",")])
            return config.normalized()
        }

        if state.sawLegacySecrets || state.sawLegacyAccounts {
            let cleared = self.clearLegacyStores(stores: stores, sawAccounts: state.sawLegacyAccounts, log: log)
            if cleared {
                userDefaults.set(true, forKey: Self.legacyMigrationCompletedKey)
            }
        } else if !migrationCompleted {
            userDefaults.set(true, forKey: Self.legacyMigrationCompletedKey)
        }

        return config.normalized()
    }

    private static func applyLegacyOrderAndToggles(
        userDefaults: UserDefaults,
        config: inout CodexBarConfig,
        state: inout MigrationState)
    {
        if let order = userDefaults.stringArray(forKey: "providerOrder"), !order.isEmpty {
            config = self.applyProviderOrder(order, config: config)
            state.didUpdate = true
        }
        let toggles = userDefaults.dictionary(forKey: "providerToggles") as? [String: Bool] ?? [:]
        if !toggles.isEmpty {
            config = self.applyProviderToggles(toggles, config: config)
            state.didUpdate = true
        }
    }

    private static func migrateLegacySecrets(
        userDefaults: UserDefaults,
        stores: LegacyStores,
        config: inout CodexBarConfig,
        state: inout MigrationState,
        log: CodexBarLogger)
    {
        // Provider-specific by design: this one-shot migration names the retired per-provider secret stores.
        self.migrateTokenProviders(
            [
                (.zai, "zai-token", stores.zaiTokenStore.loadToken),
                (.synthetic, "synthetic-token", stores.syntheticTokenStore.loadToken),
                (.copilot, "copilot-token", stores.copilotTokenStore.loadToken),
            ],
            config: &config,
            state: &state,
            log: log)

        self.migrateCookieProviders(
            [
                (.codex, "codex-cookie", stores.codexCookieStore.loadCookieHeader),
                (.claude, "claude-cookie", stores.claudeCookieStore.loadCookieHeader),
                (.cursor, "cursor-cookie", stores.cursorCookieStore.loadCookieHeader),
                (.factory, "factory-cookie", stores.factoryCookieStore.loadCookieHeader),
                (.augment, "augment-cookie", stores.augmentCookieStore.loadCookieHeader),
                (.amp, "amp-cookie", stores.ampCookieStore.loadCookieHeader),
            ],
            config: &config,
            state: &state,
            log: log)

        self.migrateMiniMax(userDefaults: userDefaults, stores: stores, config: &config, state: &state, log: log)
        self.migrateKimi(userDefaults: userDefaults, stores: stores, config: &config, state: &state, log: log)
        self.migrateOpenCode(userDefaults: userDefaults, stores: stores, config: &config, state: &state, log: log)
    }

    private static func applyLegacyCookieSources(
        userDefaults: UserDefaults,
        config: inout CodexBarConfig,
        state: inout MigrationState)
    {
        // Provider-specific by design: these are the historical UserDefaults keys shipped before unified config.
        let sources: [(UsageProvider, String)] = [
            (.codex, "codexCookieSource"),
            (.claude, "claudeCookieSource"),
            (.cursor, "cursorCookieSource"),
            (.opencode, "opencodeCookieSource"),
            (.factory, "factoryCookieSource"),
            (.minimax, "minimaxCookieSource"),
            (.kimi, "kimiCookieSource"),
            (.augment, "augmentCookieSource"),
            (.amp, "ampCookieSource"),
        ]

        for (provider, key) in sources {
            guard let raw = userDefaults.string(forKey: key),
                  let source = ProviderCookieSource(rawValue: raw)
            else { continue }
            self.updateProvider(provider, config: &config, state: &state) { entry in
                guard entry.cookieSource == nil else { return false }
                entry.cookieSource = source
                return true
            }
        }

        if userDefaults.object(forKey: "openAIWebAccessEnabled") as? Bool == false {
            // Provider-specific by design: the retired OpenAI web toggle controlled Codex dashboard cookies.
            self.updateProvider(.codex, config: &config, state: &state) { entry in
                guard entry.cookieSource == nil else { return false }
                entry.cookieSource = .off
                return true
            }
        }
    }

    private static func bindLegacyMoonshotAPIKeyRegion(
        config: inout CodexBarConfig,
        state: inout MigrationState)
    {
        // Provider-specific by design: old Moonshot API keys stored region separately from the unified config.
        self.updateProvider(.moonshot, config: &config, state: &state) { entry in
            guard entry.sanitizedAPIKey != nil, entry.sanitizedAPIKeyRegion == nil else { return false }
            entry.apiKeyRegion = entry.sanitizedRegion ?? MoonshotRegion.international.rawValue
            return true
        }
    }

    private static func migrateTokenProviders(
        _ providers: [(UsageProvider, String, () throws -> String?)],
        config: inout CodexBarConfig,
        state: inout MigrationState,
        log: CodexBarLogger)
    {
        for (provider, store, loader) in providers {
            let token = self.loadLegacyString(
                provider: provider,
                store: store,
                state: &state,
                log: log,
                loader: loader)
            if token != nil {
                state.sawLegacySecrets = true
            }
            self.updateProvider(provider, config: &config, state: &state) { entry in
                self.setIfEmpty(&entry.apiKey, token)
            }
        }
    }

    private static func migrateCookieProviders(
        _ providers: [(UsageProvider, String, () throws -> String?)],
        config: inout CodexBarConfig,
        state: inout MigrationState,
        log: CodexBarLogger)
    {
        for (provider, store, loader) in providers {
            let header = self.loadLegacyString(
                provider: provider,
                store: store,
                state: &state,
                log: log,
                loader: loader)
            if header != nil {
                state.sawLegacySecrets = true
            }
            self.updateProvider(provider, config: &config, state: &state) { entry in
                self.setIfEmpty(&entry.cookieHeader, header)
            }
        }
    }

    private static func migrateMiniMax(
        userDefaults: UserDefaults,
        stores: LegacyStores,
        config: inout CodexBarConfig,
        state: inout MigrationState,
        log: CodexBarLogger)
    {
        // Provider-specific by design: MiniMax formerly split API token, region, and cookie across legacy stores.
        let token = self.loadLegacyString(
            provider: .minimax,
            store: "minimax-api-token",
            state: &state,
            log: log,
            loader: stores.minimaxAPITokenStore.loadToken)
        let header = self.loadLegacyString(
            provider: .minimax,
            store: "minimax-cookie",
            state: &state,
            log: log,
            loader: stores.minimaxCookieStore.loadCookieHeader)
        if token != nil || header != nil {
            state.sawLegacySecrets = true
        }
        let regionRaw = userDefaults.string(forKey: "minimaxAPIRegion")
        self.updateProvider(.minimax, config: &config, state: &state) { entry in
            var changed = false
            changed = self.setIfEmpty(&entry.apiKey, token) || changed
            if let regionRaw, !regionRaw.isEmpty, entry.region == nil {
                entry.region = regionRaw
                changed = true
            }
            changed = self.setIfEmpty(&entry.cookieHeader, header) || changed
            return changed
        }
    }

    private static func migrateKimi(
        userDefaults: UserDefaults,
        stores: LegacyStores,
        config: inout CodexBarConfig,
        state: inout MigrationState,
        log: CodexBarLogger)
    {
        // Provider-specific by design: Kimi's legacy cookie could live in Keychain or kimiManualCookieHeader.
        var token = self.loadLegacyString(
            provider: .kimi,
            store: "kimi-token",
            state: &state,
            log: log,
            loader: stores.kimiTokenStore.loadToken)
        if token?.isEmpty ?? true {
            token = userDefaults.string(forKey: "kimiManualCookieHeader")
        }
        if token != nil {
            state.sawLegacySecrets = true
        }
        self.updateProvider(.kimi, config: &config, state: &state) { entry in
            self.setIfEmpty(&entry.cookieHeader, token)
        }
    }

    private static func migrateOpenCode(
        userDefaults: UserDefaults,
        stores: LegacyStores,
        config: inout CodexBarConfig,
        state: inout MigrationState,
        log: CodexBarLogger)
    {
        // Provider-specific by design: OpenCode's retired store paired its cookie with opencodeWorkspaceID.
        let header = self.loadLegacyString(
            provider: .opencode,
            store: "opencode-cookie",
            state: &state,
            log: log,
            loader: stores.opencodeCookieStore.loadCookieHeader)
        if header != nil {
            state.sawLegacySecrets = true
        }
        let workspaceID = userDefaults.string(forKey: "opencodeWorkspaceID")
        self.updateProvider(.opencode, config: &config, state: &state) { entry in
            var changed = false
            changed = self.setIfEmpty(&entry.cookieHeader, header) || changed
            if let workspaceID, !workspaceID.isEmpty, entry.workspaceID == nil {
                entry.workspaceID = workspaceID
                changed = true
            }
            return changed
        }
    }

    private static func migrateLegacyAccounts(
        stores: LegacyStores,
        config: inout CodexBarConfig,
        state: inout MigrationState,
        log: CodexBarLogger)
    {
        let accounts: [UsageProvider: ProviderTokenAccountData]
        do {
            accounts = try stores.tokenAccountStore.loadAccounts()
        } catch {
            self.recordLegacyLoadFailure(
                provider: nil,
                store: "token-accounts",
                error: error,
                state: &state,
                log: log)
            return
        }
        guard !accounts.isEmpty else { return }
        state.sawLegacyAccounts = true
        for (provider, data) in accounts where !data.accounts.isEmpty {
            self.updateProvider(provider, config: &config, state: &state) { entry in
                guard entry.tokenAccounts == nil else { return false }
                entry.tokenAccounts = data
                return true
            }
        }
    }

    private static func loadLegacyString(
        provider: UsageProvider,
        store: String,
        state: inout MigrationState,
        log: CodexBarLogger,
        loader: () throws -> String?) -> String?
    {
        do {
            return try loader()
        } catch {
            self.recordLegacyLoadFailure(
                provider: provider,
                store: store,
                error: error,
                state: &state,
                log: log)
            return nil
        }
    }

    private static func recordLegacyLoadFailure(
        provider: UsageProvider?,
        store: String,
        error: Error,
        state: inout MigrationState,
        log: CodexBarLogger)
    {
        state.legacyLoadFailures.append(store)
        log.error(
            "Failed to load legacy migration source",
            metadata: [
                "provider": provider?.rawValue ?? "multiple",
                "store": store,
                "error": error.localizedDescription,
            ])
    }

    private static func updateProvider(
        _ provider: UsageProvider,
        config: inout CodexBarConfig,
        state: inout MigrationState,
        mutate: (inout ProviderConfig) -> Bool)
    {
        guard let index = config.providers.firstIndex(where: { $0.id == provider.instanceID }) else { return }
        var entry = config.providers[index]
        let changed = mutate(&entry)
        if changed {
            config.providers[index] = entry
            state.didUpdate = true
        }
    }

    private static func setIfEmpty(_ value: inout String?, _ replacement: String?) -> Bool {
        let cleaned = replacement?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let cleaned, !cleaned.isEmpty else { return false }
        if value == nil || value?.isEmpty == true {
            value = cleaned
            return true
        }
        return false
    }

    @discardableResult
    private static func clearLegacyStores(
        stores: LegacyStores,
        sawAccounts: Bool,
        log: CodexBarLogger) -> Bool
    {
        var success = true
        do {
            try stores.zaiTokenStore.storeToken(nil)
            try stores.syntheticTokenStore.storeToken(nil)
            try stores.copilotTokenStore.storeToken(nil)
            try stores.minimaxAPITokenStore.storeToken(nil)
            try stores.kimiTokenStore.storeToken(nil)
            try stores.codexCookieStore.storeCookieHeader(nil)
            try stores.claudeCookieStore.storeCookieHeader(nil)
            try stores.cursorCookieStore.storeCookieHeader(nil)
            try stores.opencodeCookieStore.storeCookieHeader(nil)
            try stores.factoryCookieStore.storeCookieHeader(nil)
            try stores.minimaxCookieStore.storeCookieHeader(nil)
            try stores.augmentCookieStore.storeCookieHeader(nil)
            try stores.ampCookieStore.storeCookieHeader(nil)
        } catch {
            log.error("Failed to clear legacy secrets: \(error)")
            success = false
        }

        if sawAccounts {
            let legacyURL = FileTokenAccountStore.defaultURL()
            if FileManager.default.fileExists(atPath: legacyURL.path) {
                try? FileManager.default.removeItem(at: legacyURL)
            }
        }

        return success
    }

    private static func applyProviderOrder(_ raw: [String], config: CodexBarConfig) -> CodexBarConfig {
        let configsByID = Dictionary(uniqueKeysWithValues: config.providers.map { ($0.id, $0) })
        var seen: Set<ProviderInstanceID> = []
        var ordered: [ProviderConfig] = []
        ordered.reserveCapacity(config.providers.count)

        for rawValue in raw {
            guard let instanceID = ProviderInstanceID(rawValue: rawValue),
                  let entry = configsByID[instanceID],
                  !seen.contains(instanceID)
            else { continue }
            seen.insert(instanceID)
            ordered.append(entry)
        }

        for provider in UsageProvider.allCases where !seen.contains(provider.instanceID) {
            ordered.append(configsByID[provider.instanceID] ?? ProviderConfig(id: provider.instanceID))
        }

        var updated = config
        updated.providers = ordered
        return updated
    }

    private static func applyProviderToggles(
        _ toggles: [String: Bool],
        config: CodexBarConfig) -> CodexBarConfig
    {
        var updated = config
        for index in updated.providers.indices {
            guard let provider = updated.providers[index].id.firstPartyProvider else { continue }
            let meta = ProviderDescriptorRegistry.descriptor(for: provider).metadata
            if let value = toggles[meta.cliName] {
                updated.providers[index].enabled = value
            }
        }
        return updated
    }
}
