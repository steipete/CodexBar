import CodexBarCore
import Foundation

enum ConfigChangeOrigin: Equatable {
    case localUser
    case localFile
    case externalSync
}

extension SettingsStore {
    func startConfigFileWatcher() {
        let watcher = ConfigFileWatcher(fileURL: self.configStore.fileURL) { [weak self] in
            Task { @MainActor [weak self] in
                self?.reloadConfig(reason: "file-watch", origin: .localFile)
            }
        }
        self.configFileWatcher = watcher
        watcher.start()
    }

    func updateConfig(
        reason: String,
        affectsBackgroundWork: Bool,
        mutate: (inout CodexBarConfig) -> Void)
    {
        guard !self.configLoading else { return }
        var config = self.config
        mutate(&config)
        self.config = config.normalized()
        self.updateProviderState(config: self.config)
        self.schedulePersistConfig()
        self.bumpConfigRevision(reason: reason, affectsBackgroundWork: affectsBackgroundWork)
    }

    /// Pass `affectsBackgroundWork: false` for a purely cosmetic change, so open menus and status items
    /// rebuild without triggering a provider refresh.
    func updateProviderConfig(
        provider: UsageProvider,
        affectsBackgroundWork: Bool = true,
        mutate: (inout ProviderConfig) -> Void)
    {
        self.updateConfig(
            reason: "provider-\(provider.rawValue)",
            affectsBackgroundWork: affectsBackgroundWork)
        { config in
            var entry = config.providerConfig(for: provider.instanceID) ?? ProviderConfig(id: provider.instanceID)
            mutate(&entry)
            config.setProviderConfig(entry)
        }
    }

    func updateHooks(_ mutate: (inout HooksConfig) -> Void) {
        // Hooks never affect provider fetching, so mark the change as not affecting
        // background work: the config persists and the pane re-renders (via
        // configRevision), but no provider refresh is triggered.
        self.updateConfig(reason: "hooks", affectsBackgroundWork: false) { config in
            var hooks = config.hooks ?? HooksConfig()
            mutate(&hooks)
            config.hooks = (hooks.enabled || !hooks.events.isEmpty) ? hooks : nil
        }
    }

    /// Persists provider settings that only affect an already-visible provider detail.
    /// This avoids rebuilding status items and open menus for a local selection change.
    func updateProviderDetailConfig(
        provider: UsageProvider,
        mutate: (inout ProviderConfig) -> Void)
    {
        guard !self.configLoading else { return }
        var config = self.config
        var entry = config.providerConfig(for: provider.instanceID) ?? ProviderConfig(id: provider.instanceID)
        mutate(&entry)
        config.setProviderConfig(entry)
        self.config = config.normalized()
        self.updateProviderState(config: self.config)
        self.schedulePersistConfig()
        self.providerDetailSettingsRevision &+= 1
    }

    func updateProviderTokenAccounts(_ accounts: [UsageProvider: ProviderTokenAccountData]) {
        let summary = accounts
            .sorted { $0.key.rawValue < $1.key.rawValue }
            .map { "\($0.key.rawValue)=\($0.value.accounts.count)" }
            .joined(separator: ",")
        CodexBarLog.logger(LogCategories.tokenAccounts).info(
            "Token accounts updated",
            metadata: [
                "providers": "\(accounts.count)",
                "summary": summary,
            ])
        self.updateConfig(reason: "token-accounts", affectsBackgroundWork: true) { config in
            var seen: Set<ProviderInstanceID> = []
            for index in config.providers.indices {
                let instanceID = config.providers[index].id
                let provider = instanceID.firstPartyProvider
                config.providers[index].tokenAccounts = provider.flatMap { accounts[$0] }
                seen.insert(instanceID)
            }
            for (provider, data) in accounts where !seen.contains(provider.instanceID) {
                config.providers.append(ProviderConfig(id: provider.instanceID, tokenAccounts: data))
            }
        }
    }

    func setProviderOrder(_ order: [ProviderInstanceID]) {
        self.updateConfig(reason: "order", affectsBackgroundWork: false) { config in
            let configsByID = Dictionary(uniqueKeysWithValues: config.providers.map { ($0.id, $0) })
            var seen: Set<ProviderInstanceID> = []
            var ordered: [ProviderConfig] = []
            ordered.reserveCapacity(max(order.count, config.providers.count))

            for provider in order {
                guard !seen.contains(provider) else { continue }
                seen.insert(provider)
                ordered.append(configsByID[provider] ?? ProviderConfig(id: provider))
            }

            for provider in UsageProvider.allCases where !seen.contains(provider.instanceID) {
                seen.insert(provider.instanceID)
                ordered.append(configsByID[provider.instanceID] ?? ProviderConfig(id: provider.instanceID))
            }

            // A loaded plugin can become unavailable without losing its retained configuration.
            ordered.append(contentsOf: config.providers.filter { !seen.contains($0.id) })

            config.providers = ordered
        }
    }

    func reloadConfig(
        reason: String,
        affectsBackgroundWork: Bool? = nil,
        origin: ConfigChangeOrigin = .externalSync)
    {
        guard !self.configLoading else { return }
        do {
            guard let loaded = try self.configPersistenceCoordinator.load(self.configStore, reload: true)
            else { return }
            self.configNeedsReload = false
            self.applyExternalConfig(
                loaded,
                reason: "reload-\(reason)",
                affectsBackgroundWork: affectsBackgroundWork,
                origin: origin)
        } catch {
            self.configNeedsReload = true
            CodexBarLog.logger(LogCategories.configStore).error("Failed to reload config: \(error)")
        }
    }

    func applyExternalConfig(
        _ config: CodexBarConfig,
        reason: String,
        affectsBackgroundWork: Bool? = nil,
        origin: ConfigChangeOrigin = .externalSync)
    {
        guard !self.configLoading else { return }
        let normalized = config.normalized()
        let previousData = Self.orderIndependentConfigData(self.config)
        let currentData = Self.orderIndependentConfigData(normalized)
        let inferredBackgroundWorkChange = previousData == nil || currentData == nil || previousData != currentData
        let resolvedBackgroundWorkChange = (affectsBackgroundWork ?? false) || inferredBackgroundWorkChange
        self.configLoading = true
        self.config = normalized
        self.updateProviderState(config: normalized)
        self.configLoading = false
        self.bumpConfigRevision(
            origin: origin,
            reason: "sync-\(reason)",
            affectsBackgroundWork: resolvedBackgroundWorkChange)
    }

    private static func orderIndependentConfigData(_ config: CodexBarConfig) -> Data? {
        var canonical = config.normalized()
        canonical.providers = canonical.providers.map(\.fetchIdentityConfig)
        canonical.providers.sort { $0.id.rawValue < $1.id.rawValue }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try? encoder.encode(canonical)
    }

    private func bumpConfigRevision(
        origin: ConfigChangeOrigin = .localUser,
        reason: String,
        affectsBackgroundWork: Bool)
    {
        // Account routing derives from config paths and source selection. Never let an old
        // reconciliation snapshot survive a config reload, even when another provider changed.
        self.invalidateCodexAccountReconciliationSnapshotCache()
        self.cachedCodexAccountMenuProjection = nil
        self.configRevision &+= 1
        if affectsBackgroundWork {
            self.noteBackgroundWorkSettingsChanged()
        }
        CodexBarLog.logger(LogCategories.settings)
            .debug(
                "Config revision bumped (\(reason)) -> \(self.configRevision)",
                metadata: ["backgroundWork": affectsBackgroundWork ? "1" : "0"])
        if origin == .localFile {
            NotificationCenter.default.post(
                name: .codexbarLocalConfigFileDidChange,
                object: self,
                userInfo: ["reason": reason])
        }
        guard origin == .localUser else { return }
        NotificationCenter.default.post(
            name: .codexbarProviderConfigDidChange,
            object: self,
            userInfo: [
                "config": self.config,
                "reason": reason,
                "revision": self.configRevision,
                "affectsBackgroundWork": affectsBackgroundWork,
            ])
    }

    func normalizedConfigValue(_ raw: String) -> String? {
        Self.normalizedConfigField(raw)
    }

    nonisolated static func normalizedConfigField(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    func savePluginSettings(
        provider: UsageProvider,
        values: [String: String],
        isCurrent: () -> Bool) async -> ProviderSettingsSaveOutcome
    {
        // Drain any detached save before committing the discovery, then recheck its ownership.
        while !Task.isCancelled, let pending = self.configPersistTask {
            await pending.value
            if self.configPersistTask == pending { break }
        }
        guard !Task.isCancelled, !self.configLoading, !self.configNeedsReload, isCurrent() else { return .stale }
        var config: CodexBarConfig
        do {
            config = try self.configPersistenceCoordinator.load(self.configStore) ?? self.config
        } catch {
            self.configNeedsReload = true
            return .failed
        }
        do {
            let original = self.config
                .providerConfig(for: provider.instanceID) ?? ProviderConfig(id: provider.instanceID)
            guard ProviderPluginResultPolicy.matches(
                config.providerConfig(for: provider.instanceID) ?? ProviderConfig(id: provider.instanceID), original)
            else { return .stale }
            let updated = try ProviderDescriptorRegistry.descriptor(for: provider).pluginResultPolicy
                .applying(values, to: original)
            guard !ProviderPluginResultPolicy.matches(updated, original) else { return .unchanged }
            config.setProviderConfig(updated)
            try Self.writeConfig(
                config,
                to: self.configStore,
                watcher: self.configFileWatcher,
                permit: self.configPersistenceCoordinator.makeWritePermit())
            self.config = config.normalized()
            self.updateProviderState(config: self.config)
            self.bumpConfigRevision(reason: "plugin-settings", affectsBackgroundWork: false)
            return .saved
        } catch {
            return .failed
        }
    }

    func schedulePersistConfig() {
        // Defaults or stale settings must not replace a repaired file before its reload arrives.
        guard !self.configLoading, !self.configNeedsReload else { return }
        self.configPersistTask?.cancel()
        #if DEBUG
        let persistSynchronously = Self.isRunningTests && !self._test_configPersistenceUsesDebounce
        #else
        let persistSynchronously = Self.isRunningTests
        #endif
        if persistSynchronously {
            Self.persistConfig(
                self.config,
                to: self.configStore,
                watcher: self.configFileWatcher,
                permit: self.configPersistenceCoordinator.makeWritePermit())
            return
        }
        self.configPersistTask = Task { @MainActor in
            do { try await Task.sleep(for: .milliseconds(350)) } catch { return }
            guard !Task.isCancelled, !self.configNeedsReload else { return }
            let write = self.persistConfigInBackground()
            await write.value
            if self.configPersistWriteTask == write { self.configPersistWriteTask = nil }
            if !Task.isCancelled { self.configPersistTask = nil }
        }
    }

    func persistPendingConfigForTermination() -> Task<Void, Never>? {
        guard !self.configNeedsReload, let pending = self.configPersistTask else { return nil }
        pending.cancel()
        let save = self.persistConfigInBackground()
        self.configPersistTask = save
        return save
    }

    private func persistConfigInBackground() -> Task<Void, Never> {
        let previousWrite = self.configPersistWriteTask
        let store = self.configStore
        let watcher = self.configFileWatcher
        let permit = self.configPersistenceCoordinator.makeWritePermit()
        // Drain physical writes without needing the main actor, which may be in AppKit's quit loop.
        let write = Task.detached(priority: .utility) { [snapshot = self.config] in
            await previousWrite?.value
            guard !Task.isCancelled else { return }
            Self.persistConfig(snapshot, to: store, watcher: watcher, permit: permit)
        }
        self.configPersistWriteTask = write
        return write
    }

    private nonisolated static func persistConfig(
        _ config: CodexBarConfig,
        to store: CodexBarConfigStore,
        watcher: ConfigFileWatcher?,
        permit: SettingsConfigPersistenceCoordinator.WritePermit)
    {
        do {
            try self.writeConfig(config, to: store, watcher: watcher, permit: permit)
        } catch is CancellationError {
            // A failed read or reload made this snapshot unsafe to publish.
        } catch {
            CodexBarLog.logger(LogCategories.configStore).error("Failed to persist config: \(error)")
        }
    }

    nonisolated static func writeConfig(
        _ config: CodexBarConfig,
        to store: CodexBarConfigStore,
        watcher: ConfigFileWatcher?,
        permit: SettingsConfigPersistenceCoordinator.WritePermit) throws
    {
        let data = try store.encodedData(for: config)
        var publicationLocked = false
        defer { if publicationLocked { permit.endPublication() } }
        try ConfigFileWatcher.withAppWrite(data, watcher: watcher) {
            try store.saveEncodedData(data) {
                try permit.beginPublication(validating: store)
                publicationLocked = true
            }
        }
    }
}

/// Reloads invalidate every older snapshot. Only the final publication and reload read share
/// this lock; staging and fsync never hold it or need the main actor.
final class SettingsConfigPersistenceCoordinator: @unchecked Sendable {
    struct WritePermit: Sendable {
        fileprivate let coordinator: SettingsConfigPersistenceCoordinator
        fileprivate let generation: UInt64

        func beginPublication(validating store: CodexBarConfigStore) throws {
            self.coordinator.lock.lock()
            guard !self.coordinator.readFailed, self.generation == self.coordinator.generation else {
                self.coordinator.lock.unlock()
                throw CancellationError()
            }
            do {
                _ = try store.load()
            } catch {
                self.coordinator.readFailed = true
                self.coordinator.lock.unlock()
                throw error
            }
        }

        func endPublication() {
            self.coordinator.lock.unlock()
        }
    }

    private let lock = NSLock()
    private var generation: UInt64 = 0
    private var readFailed = false

    func makeWritePermit() -> WritePermit {
        self.lock.withLock { WritePermit(coordinator: self, generation: self.generation) }
    }

    func load(_ store: CodexBarConfigStore, reload: Bool = false) throws -> CodexBarConfig? {
        try self.lock.withLock {
            self.generation &+= 1
            let config = try store.load()
            if reload, config != nil { self.readFailed = false }
            return config
        }
    }
}
