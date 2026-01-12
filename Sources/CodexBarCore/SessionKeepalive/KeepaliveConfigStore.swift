import Foundation

/// Persistent storage for session keepalive configurations.
///
/// Stores per-provider keepalive settings in UserDefaults, allowing configurations
/// to persist across app launches.
public final class KeepaliveConfigStore: @unchecked Sendable {
    // MARK: - Singleton

    public static let shared = KeepaliveConfigStore()

    // MARK: - UserDefaults Keys

    private let userDefaults: UserDefaults
    private let keyPrefix = "com.codexbar.keepalive."

    // MARK: - Initialization

    public init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    // MARK: - Public API

    /// Save a keepalive configuration for a provider.
    ///
    /// - Parameters:
    ///   - config: The configuration to save
    ///   - provider: The provider this config applies to
    public func save(_ config: KeepaliveConfig, for provider: UsageProvider) {
        let key = self.key(for: provider)
        do {
            let encoder = JSONEncoder()
            let data = try encoder.encode(config)
            self.userDefaults.set(data, forKey: key)
            print("[KeepaliveConfigStore] Saved config for \(provider.rawValue): \(config)")
        } catch {
            print("[KeepaliveConfigStore] Failed to save config for \(provider.rawValue): \(error)")
        }
    }

    /// Load a keepalive configuration for a provider.
    ///
    /// - Parameter provider: The provider to load config for
    /// - Returns: The saved configuration, or nil if none exists
    public func load(for provider: UsageProvider) -> KeepaliveConfig? {
        let key = self.key(for: provider)
        guard let data = self.userDefaults.data(forKey: key) else {
            return nil
        }

        do {
            let decoder = JSONDecoder()
            let config = try decoder.decode(KeepaliveConfig.self, from: data)
            print("[KeepaliveConfigStore] Loaded config for \(provider.rawValue): \(config)")
            return config
        } catch {
            print("[KeepaliveConfigStore] Failed to load config for \(provider.rawValue): \(error)")
            return nil
        }
    }

    /// Load a configuration with a fallback default.
    ///
    /// - Parameters:
    ///   - provider: The provider to load config for
    ///   - defaultConfig: The default to use if no saved config exists
    /// - Returns: The saved configuration, or the default if none exists
    public func loadOrDefault(for provider: UsageProvider, default defaultConfig: KeepaliveConfig) -> KeepaliveConfig {
        self.load(for: provider) ?? defaultConfig
    }

    /// Delete the saved configuration for a provider.
    ///
    /// - Parameter provider: The provider to delete config for
    public func delete(for provider: UsageProvider) {
        let key = self.key(for: provider)
        self.userDefaults.removeObject(forKey: key)
        print("[KeepaliveConfigStore] Deleted config for \(provider.rawValue)")
    }

    /// Load all saved configurations.
    ///
    /// - Returns: Dictionary of provider to configuration
    public func loadAll() -> [UsageProvider: KeepaliveConfig] {
        var configs: [UsageProvider: KeepaliveConfig] = [:]

        for provider in UsageProvider.allCases {
            if let config = self.load(for: provider) {
                configs[provider] = config
            }
        }

        return configs
    }

    /// Save multiple configurations at once.
    ///
    /// - Parameter configs: Dictionary of provider to configuration
    public func saveAll(_ configs: [UsageProvider: KeepaliveConfig]) {
        for (provider, config) in configs {
            self.save(config, for: provider)
        }
    }

    /// Delete all saved configurations.
    public func deleteAll() {
        for provider in UsageProvider.allCases {
            self.delete(for: provider)
        }
    }

    // MARK: - Private Helpers

    private func key(for provider: UsageProvider) -> String {
        "\(self.keyPrefix)\(provider.rawValue)"
    }
}

// MARK: - Default Configurations

extension KeepaliveConfigStore {
    /// Get the recommended default configuration for a provider.
    ///
    /// - Parameter provider: The provider to get defaults for
    /// - Returns: The recommended default configuration
    public static func defaultConfig(for provider: UsageProvider) -> KeepaliveConfig {
        switch provider {
        case .augment:
            return .augmentDefault
        case .claude:
            return .claudeDefault
        case .codex:
            return .codexDefault
        default:
            // For other providers, default to disabled until we implement their refresh logic
            return .disabled
        }
    }

    /// Load configuration with provider-specific defaults.
    ///
    /// - Parameter provider: The provider to load config for
    /// - Returns: Saved config, or provider-specific default if none exists
    public func loadWithProviderDefaults(for provider: UsageProvider) -> KeepaliveConfig {
        self.loadOrDefault(for: provider, default: Self.defaultConfig(for: provider))
    }
}

