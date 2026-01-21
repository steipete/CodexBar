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
        let kimiK2TokenStore: any KimiK2TokenStoring
        let augmentCookieStore: any CookieHeaderStoring
        let ampCookieStore: any CookieHeaderStoring
        let copilotTokenStore: any CopilotTokenStoring
        let tokenAccountStore: any ProviderTokenAccountStoring
    }

    private struct MigrationState {
        var didUpdate = false
        var sawLegacySecrets = false
        var sawLegacyAccounts = false
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

        if existing == nil {
            self.applyLegacyOrderAndToggles(userDefaults: userDefaults, config: &config, state: &state)
        }

        self.applyLegacyCookieSources(userDefaults: userDefaults, config: &config, state: &state)
        self.migrateLegacySecrets(userDefaults: userDefaults, stores: stores, config: &config, state: &state)
        self.migrateLegacyAccounts(stores: stores, config: &config, state: &state)

        if state.didUpdate {
            do {
                try configStore.save(config)
            } catch {
                log.error("Failed to persist config: \(error)")
            }
        }

        if state.sawLegacySecrets || state.sawLegacyAccounts {
            self.clearLegacyStores(stores: stores, sawAccounts: state.sawLegacyAccounts, log: log)
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
        state: inout MigrationState)
    {
        self.migrateTokenProviders(
            [
                (.zai, stores.zaiTokenStore.loadToken),
                (.synthetic, stores.syntheticTokenStore.loadToken),
                (.copilot, stores.copilotTokenStore.loadToken),
                (.kimik2, stores.kimiK2TokenStore.loadToken),
            ],
            config: &config,
            state: &state)

        self.migrateCookieProviders(
            [
                (.codex, stores.codexCookieStore.loadCookieHeader),
                (.claude, stores.claudeCookieStore.loadCookieHeader),
                (.cursor, stores.cursorCookieStore.loadCookieHeader),
                (.factory, stores.factoryCookieStore.loadCookieHeader),
                (.augment, stores.augmentCookieStore.loadCookieHeader),
                (.amp, stores.ampCookieStore.loadCookieHeader),
            ],
            config: &config,
            state: &state)

        self.migrateMiniMax(userDefaults: userDefaults, stores: stores, config: &config, state: &state)
        self.migrateKimi(userDefaults: userDefaults, stores: stores, config: &config, state: &state)
        self.migrateOpenCode(userDefaults: userDefaults, stores: stores, config: &config, state: &state)
    }

    private static func applyLegacyCookieSources(
        userDefaults: UserDefaults,
        config: inout CodexBarConfig,
        state: inout MigrationState)
    {
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
            self.updateProvider(.codex, config: &config, state: &state) { entry in
                guard entry.cookieSource == nil else { return false }
                entry.cookieSource = .off
                return true
            }
        }
    }

    private static func migrateTokenProviders(
        _ providers: [(UsageProvider, () throws -> String?)],
        config: inout CodexBarConfig,
        state: inout MigrationState)
    {
        for (provider, loader) in providers {
            let token = try? loader()
            if token != nil { state.sawLegacySecrets = true }
            self.updateProvider(provider, config: &config, state: &state) { entry in
                self.setIfEmpty(&entry.apiKey, token)
            }
        }
    }

    private static func migrateCookieProviders(
        _ providers: [(UsageProvider, () throws -> String?)],
        config: inout CodexBarConfig,
        state: inout MigrationState)
    {
        for (provider, loader) in providers {
            let header = try? loader()
            if header != nil { state.sawLegacySecrets = true }
            self.updateProvider(provider, config: &config, state: &state) { entry in
                self.setIfEmpty(&entry.cookieHeader, header)
            }
        }
    }

    private static func migrateMiniMax(
        userDefaults: UserDefaults,
        stores: LegacyStores,
        config: inout CodexBarConfig,
        state: inout MigrationState)
    {
        let token = try? stores.minimaxAPITokenStore.loadToken()
        let header = try? stores.minimaxCookieStore.loadCookieHeader()
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
        state: inout MigrationState)
    {
        var token = try? stores.kimiTokenStore.loadToken()
        if token?.isEmpty ?? true {
            token = userDefaults.string(forKey: "kimiManualCookieHeader")
        }
        if token != nil { state.sawLegacySecrets = true }
        self.updateProvider(.kimi, config: &config, state: &state) { entry in
            self.setIfEmpty(&entry.cookieHeader, token)
        }
    }

    private static func migrateOpenCode(
        userDefaults: UserDefaults,
        stores: LegacyStores,
        config: inout CodexBarConfig,
        state: inout MigrationState)
    {
        let header = try? stores.opencodeCookieStore.loadCookieHeader()
        if header != nil { state.sawLegacySecrets = true }
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
        state: inout MigrationState)
    {
        guard let accounts = try? stores.tokenAccountStore.loadAccounts(), !accounts.isEmpty else { return }
        state.sawLegacyAccounts = true
        for (provider, data) in accounts where !data.accounts.isEmpty {
            self.updateProvider(provider, config: &config, state: &state) { entry in
                guard entry.tokenAccounts == nil else { return false }
                entry.tokenAccounts = data
                return true
            }
        }
    }

    private static func updateProvider(
        _ provider: UsageProvider,
        config: inout CodexBarConfig,
        state: inout MigrationState,
        mutate: (inout ProviderConfig) -> Bool)
    {
        guard let index = config.providers.firstIndex(where: { $0.id == provider }) else { return }
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

    private static func clearLegacyStores(
        stores: LegacyStores,
        sawAccounts: Bool,
        log: CodexBarLogger)
    {
        do {
            try stores.zaiTokenStore.storeToken(nil)
            try stores.syntheticTokenStore.storeToken(nil)
            try stores.copilotTokenStore.storeToken(nil)
            try stores.minimaxAPITokenStore.storeToken(nil)
            try stores.kimiTokenStore.storeToken(nil)
            try stores.kimiK2TokenStore.storeToken(nil)
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
        }

        if sawAccounts {
            let legacyURL = FileTokenAccountStore.defaultURL()
            if FileManager.default.fileExists(atPath: legacyURL.path) {
                try? FileManager.default.removeItem(at: legacyURL)
            }
        }
    }

    private static func applyProviderOrder(_ raw: [String], config: CodexBarConfig) -> CodexBarConfig {
        let configsByID = Dictionary(uniqueKeysWithValues: config.providers.map { ($0.id, $0) })
        var seen: Set<UsageProvider> = []
        var ordered: [ProviderConfig] = []
        ordered.reserveCapacity(config.providers.count)

        for rawValue in raw {
            guard let provider = UsageProvider(rawValue: rawValue),
                  let entry = configsByID[provider],
                  !seen.contains(provider)
            else { continue }
            seen.insert(provider)
            ordered.append(entry)
        }

        for provider in UsageProvider.allCases where !seen.contains(provider) {
            ordered.append(configsByID[provider] ?? ProviderConfig(id: provider))
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
            let provider = updated.providers[index].id
            let meta = ProviderDescriptorRegistry.descriptor(for: provider).metadata
            if let value = toggles[meta.cliName] {
                updated.providers[index].enabled = value
            }
        }
        return updated
    }
}
