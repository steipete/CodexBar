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
        keychainAccessDisabled: Bool,
        stores: LegacyStores) throws -> CodexBarConfig
    {
        let log = CodexBarLog.logger(LogCategories.configMigration)
        let existing = try configStore.load()
        var config = (existing ?? CodexBarConfig.makeDefault()).normalized()
        var state = MigrationState()

        // applyLegacyCookieSources reads only UserDefaults — cheap, runs unconditionally so
        // newly-added cookie-source keys are picked up on every launch.
        self.applyLegacyCookieSources(userDefaults: userDefaults, config: &config, state: &state)
        self.bindLegacyMoonshotAPIKeyRegion(config: &config, state: &state)
        self.applyLegacyUsageVisibility(userDefaults: userDefaults, config: &config, state: &state)
        self.preserveClaudeResetCreditVisibility(userDefaults: userDefaults, config: &config, state: &state)

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

        if state.didUpdate {
            do {
                try configStore.save(config)
            } catch {
                log.error("Failed to persist config: \(error)")
                return config.normalized()
            }
        }

        // A disabled Keychain read looks empty to legacy stores, not successfully migrated.
        // Keep permitted file/default imports, but preserve cleanup and completion for a later retry.
        guard !keychainAccessDisabled else {
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

    private static func preserveClaudeResetCreditVisibility(
        userDefaults: UserDefaults,
        config: inout CodexBarConfig,
        state: inout MigrationState)
    {
        // Provider-specific by design: Claude resets used the global optional gate before independent controls.
        guard let index = config.providers.firstIndex(where: { $0.id == .claude }),
              config.providers[index].claudeResetCreditsVisibilityMigrated != true
        else { return }
        if userDefaults.object(forKey: "showOptionalCreditsAndExtraUsage") as? Bool == false {
            let existing = config.providers[index].hiddenUsageItemIDs ?? []
            config.providers[index].hiddenUsageItemIDs = Set(existing + ["section:claude-reset-credits"]).sorted()
        }
        config.providers[index].claudeResetCreditsVisibilityMigrated = true
        state.didUpdate = true
    }

    private static func applyLegacyUsageVisibility(
        userDefaults: UserDefaults,
        config: inout CodexBarConfig,
        state: inout MigrationState)
    {
        // Provider-specific by design: upgrade the two retired visibility toggles before sync reads config.
        let legacySelections: [(UsageProvider, String, [String])] = [
            (.codex, "codexSparkUsageVisible", ["metric:codex-spark", "metric:codex-spark-weekly"]),
            (.claude, "claudeDailyRoutinesUsageVisible", ["metric:claude-routines"]),
        ]
        for (provider, key, hiddenIDs) in legacySelections {
            guard userDefaults.object(forKey: key) as? Bool == false,
                  let index = config.providers.firstIndex(where: { $0.id == provider.instanceID }),
                  config.providers[index].hiddenUsageItemIDs == nil
            else { continue }
            config.providers[index].hiddenUsageItemIDs = hiddenIDs
            state.didUpdate = true
        }
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
        let sources: [(UsageProvider, String, () throws -> String?, WritableKeyPath<ProviderConfig, String?>)] = [
            (.zai, "zai-token", stores.zaiTokenStore.loadToken, \.apiKey),
            (.synthetic, "synthetic-token", stores.syntheticTokenStore.loadToken, \.apiKey),
            (.copilot, "copilot-token", stores.copilotTokenStore.loadToken, \.apiKey),
            (.codex, "codex-cookie", stores.codexCookieStore.loadCookieHeader, \.cookieHeader),
            (.claude, "claude-cookie", stores.claudeCookieStore.loadCookieHeader, \.cookieHeader),
            (.cursor, "cursor-cookie", stores.cursorCookieStore.loadCookieHeader, \.cookieHeader),
            (.factory, "factory-cookie", stores.factoryCookieStore.loadCookieHeader, \.cookieHeader),
            (.augment, "augment-cookie", stores.augmentCookieStore.loadCookieHeader, \.cookieHeader),
            (.amp, "amp-cookie", stores.ampCookieStore.loadCookieHeader, \.cookieHeader),
            (.minimax, "minimax-api-token", stores.minimaxAPITokenStore.loadToken, \.apiKey),
            (.minimax, "minimax-cookie", stores.minimaxCookieStore.loadCookieHeader, \.cookieHeader),
            (.kimi, "kimi-token", stores.kimiTokenStore.loadToken, \.cookieHeader),
            (.opencode, "opencode-cookie", stores.opencodeCookieStore.loadCookieHeader, \.cookieHeader),
        ]
        for (provider, store, loader, field) in sources {
            var value = self.loadLegacyString(provider: provider, store: store, state: &state, log: log, loader: loader)
            // Provider-specific by design: Kimi also accepted a cookie in UserDefaults.
            if provider == .kimi, value?.isEmpty ?? true {
                value = userDefaults.string(forKey: "kimiManualCookieHeader")
            }
            if value != nil {
                state.sawLegacySecrets = true
            }
            self.updateProvider(provider, config: &config, state: &state) { entry in
                self.setIfEmpty(&entry[keyPath: field], value)
            }
        }

        // Provider-specific by design: these metadata fields accompanied the retired secret stores.
        let fields: [(UsageProvider, String, WritableKeyPath<ProviderConfig, String?>)] = [
            (.minimax, "minimaxAPIRegion", \.region),
            (.opencode, "opencodeWorkspaceID", \.workspaceID),
        ]
        for (provider, key, field) in fields {
            guard let value = userDefaults.string(forKey: key), !value.isEmpty else { continue }
            self.updateProvider(provider, config: &config, state: &state) { entry in
                guard entry[keyPath: field] == nil else { return false }
                entry[keyPath: field] = value
                return true
            }
        }
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
