import CodexBarCore
import Foundation

extension SettingsStore {
    private func updateConfig(reason: String, mutate: (inout CodexBarConfig) -> Void) {
        guard !self.configLoading else { return }
        var config = self.config
        mutate(&config)
        self.config = config.normalized()
        self.schedulePersistConfig()
        self.bumpConfigRevision(reason: reason)
    }

    func updateProviderConfig(provider: UsageProvider, mutate: (inout ProviderConfig) -> Void) {
        self.updateConfig(reason: "provider-\(provider.rawValue)") { config in
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

    func updateProviderTokenAccounts(_ accounts: [UsageProvider: ProviderTokenAccountData]) {
        self.updateConfig(reason: "token-accounts") { config in
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
        self.updateConfig(reason: "order") { config in
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

    func reloadConfig(reason: String) {
        guard !self.configLoading else { return }
        do {
            guard let loaded = try self.configStore.load() else { return }
            self.applyExternalConfig(loaded, reason: "reload-\(reason)")
        } catch {
            CodexBarLog.logger("config-store").error("Failed to reload config: \(error)")
        }
    }

    func applyExternalConfig(_ config: CodexBarConfig, reason: String) {
        guard !self.configLoading else { return }
        self.configLoading = true
        self.config = config
        self.configLoading = false
        self.bumpConfigRevision(reason: "sync-\(reason)")
    }

    private func bumpConfigRevision(reason: String) {
        self.configRevision &+= 1
        CodexBarLog.logger("settings")
            .debug("Config revision bumped (\(reason)) -> \(self.configRevision)")
        NotificationCenter.default.post(
            name: .codexbarProviderConfigDidChange,
            object: self,
            userInfo: [
                "config": self.config,
                "reason": reason,
                "revision": self.configRevision,
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
                CodexBarLog.logger("config-store").error("Failed to persist config: \(error)")
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
                CodexBarLog.logger("config-store").error("Failed to persist config: \(error)")
            }
        }
    }
}
