import CodexBarCore
import Foundation

private enum ConfigChangeOrigin {
    case localUser
    case externalSync
}

private struct ConfigChangeContext {
    let origin: ConfigChangeOrigin
    let reason: String
    let affectsBackgroundWork: Bool

    static func local(reason: String, affectsBackgroundWork: Bool) -> Self {
        Self(origin: .localUser, reason: reason, affectsBackgroundWork: affectsBackgroundWork)
    }

    static func external(reason: String, affectsBackgroundWork: Bool) -> Self {
        Self(origin: .externalSync, reason: reason, affectsBackgroundWork: affectsBackgroundWork)
    }

    var shouldBroadcast: Bool {
        switch self.origin {
        case .localUser:
            true
        case .externalSync:
            false
        }
    }
}

extension SettingsStore {
    private func updateConfig(
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
        self.bumpConfigRevision(.local(reason: reason, affectsBackgroundWork: affectsBackgroundWork))
    }

    func updateProviderConfig(provider: UsageProvider, mutate: (inout ProviderConfig) -> Void) {
        self.updateConfig(reason: "provider-\(provider.rawValue)", affectsBackgroundWork: true) { config in
            if let index = config.providers.firstIndex(where: { $0.id == provider }) {
                var entry = config.providers[index]
                mutate(&entry)
                config.providers[index] = entry
            } else {
                var entry = ProviderConfig(id: provider)
                mutate(&entry)
                config.providers.append(entry)
            }
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
        if let index = config.providers.firstIndex(where: { $0.id == provider }) {
            var entry = config.providers[index]
            mutate(&entry)
            config.providers[index] = entry
        } else {
            var entry = ProviderConfig(id: provider)
            mutate(&entry)
            config.providers.append(entry)
        }
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
            var seen: Set<UsageProvider> = []
            for index in config.providers.indices {
                let provider = config.providers[index].id
                config.providers[index].tokenAccounts = accounts[provider]
                seen.insert(provider)
            }
            for (provider, data) in accounts where !seen.contains(provider) {
                config.providers.append(ProviderConfig(id: provider, tokenAccounts: data))
            }
        }
    }

    func setProviderOrder(_ order: [UsageProvider]) {
        self.updateConfig(reason: "order", affectsBackgroundWork: false) { config in
            let configsByID = Dictionary(uniqueKeysWithValues: config.providers.map { ($0.id, $0) })
            var seen: Set<UsageProvider> = []
            var ordered: [ProviderConfig] = []
            ordered.reserveCapacity(max(order.count, config.providers.count))

            for provider in order {
                guard !seen.contains(provider) else { continue }
                seen.insert(provider)
                ordered.append(configsByID[provider] ?? ProviderConfig(id: provider))
            }

            for provider in UsageProvider.allCases where !seen.contains(provider) {
                ordered.append(configsByID[provider] ?? ProviderConfig(id: provider))
            }

            config.providers = ordered
        }
    }

    func reloadConfig(reason: String, affectsBackgroundWork: Bool? = nil) {
        guard !self.configLoading else { return }
        do {
            guard let loaded = try self.configStore.load() else { return }
            self.applyExternalConfig(
                loaded,
                reason: "reload-\(reason)",
                affectsBackgroundWork: affectsBackgroundWork)
        } catch {
            CodexBarLog.logger(LogCategories.configStore).error("Failed to reload config: \(error)")
        }
    }

    func applyExternalConfig(
        _ config: CodexBarConfig,
        reason: String,
        affectsBackgroundWork: Bool? = nil)
    {
        guard !self.configLoading else { return }
        let normalized = config.normalized()
        let inferredBackgroundWorkChange = Self.configChangeAffectsBackgroundWork(
            from: self.config,
            to: normalized)
        let resolvedBackgroundWorkChange = (affectsBackgroundWork ?? false) || inferredBackgroundWorkChange
        self.configLoading = true
        self.config = normalized
        self.updateProviderState(config: normalized)
        self.configLoading = false
        self.bumpConfigRevision(.external(
            reason: "sync-\(reason)",
            affectsBackgroundWork: resolvedBackgroundWorkChange))
    }

    private static func configChangeAffectsBackgroundWork(
        from previous: CodexBarConfig,
        to current: CodexBarConfig) -> Bool
    {
        guard let previousData = orderIndependentConfigData(previous),
              let currentData = orderIndependentConfigData(current)
        else {
            return true
        }
        return previousData != currentData
    }

    private static func orderIndependentConfigData(_ config: CodexBarConfig) -> Data? {
        var canonical = config.normalized()
        canonical.providers.sort { $0.id.rawValue < $1.id.rawValue }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try? encoder.encode(canonical)
    }

    private func bumpConfigRevision(_ context: ConfigChangeContext) {
        // Account routing derives from config paths and source selection. Never let an old
        // reconciliation snapshot survive a config reload, even when another provider changed.
        self.invalidateCodexAccountReconciliationSnapshotCache()
        self.cachedCodexAccountMenuProjection = nil
        self.configRevision &+= 1
        if context.affectsBackgroundWork {
            self.noteBackgroundWorkSettingsChanged()
        }
        CodexBarLog.logger(LogCategories.settings)
            .debug(
                "Config revision bumped (\(context.reason)) -> \(self.configRevision)",
                metadata: ["backgroundWork": context.affectsBackgroundWork ? "1" : "0"])
        guard context.shouldBroadcast else { return }
        NotificationCenter.default.post(
            name: .codexbarProviderConfigDidChange,
            object: self,
            userInfo: [
                "config": self.config,
                "reason": context.reason,
                "revision": self.configRevision,
                "affectsBackgroundWork": context.affectsBackgroundWork,
            ])
    }

    func normalizedConfigValue(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    func schedulePersistConfig() {
        guard !self.configLoading else { return }
        self.configPersistTask?.cancel()
        if Self.isRunningTests {
            do {
                try self.configStore.save(self.config)
            } catch {
                CodexBarLog.logger(LogCategories.configStore).error("Failed to persist config: \(error)")
            }
            return
        }
        let store = self.configStore
        self.configPersistTask = Task { @MainActor in
            do {
                try await Task.sleep(nanoseconds: 350_000_000)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            let snapshot = self.config
            let error: (any Error)? = await Task.detached(priority: .utility) {
                do {
                    try store.save(snapshot)
                    return nil
                } catch {
                    return error
                }
            }.value
            if let error {
                CodexBarLog.logger(LogCategories.configStore).error("Failed to persist config: \(error)")
            }
        }
    }
}
