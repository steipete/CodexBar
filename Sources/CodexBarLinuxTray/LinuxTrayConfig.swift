import CodexBarCore
import Foundation

struct LinuxTrayRuntimeConfig: Codable, Sendable {
    var refreshSeconds: Int
    var staleAfterRefreshes: Int
    var iconName: String

    static let `default` = LinuxTrayRuntimeConfig(
        refreshSeconds: 120,
        staleAfterRefreshes: 3,
        iconName: "utilities-terminal")

    var normalized: LinuxTrayRuntimeConfig {
        LinuxTrayRuntimeConfig(
            refreshSeconds: max(30, self.refreshSeconds),
            staleAfterRefreshes: max(2, self.staleAfterRefreshes),
            iconName: self.iconName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? Self.default.iconName
                : self.iconName)
    }
}

struct LinuxTrayRuntimeConfigStore {
    let fileURL: URL

    init(fileURL: URL = Self.defaultURL()) {
        self.fileURL = fileURL
    }

    func load() -> LinuxTrayRuntimeConfig {
        guard let data = try? Data(contentsOf: self.fileURL),
              let decoded = try? JSONDecoder().decode(LinuxTrayRuntimeConfig.self, from: data)
        else {
            return .default
        }
        return decoded.normalized
    }

    static func defaultURL(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home
            .appendingPathComponent(".codexbar", isDirectory: true)
            .appendingPathComponent("linux-tray.json")
    }
}

struct ProviderRuntimeSettings: Sendable {
    let sourceMode: ProviderSourceMode
    let env: [String: String]
}

struct ProviderRuntimeResolver {
    let credentials: any ProviderCredentialStore
    let baseEnv: [String: String]

    init(
        credentials: any ProviderCredentialStore,
        baseEnv: [String: String] = ProcessInfo.processInfo.environment)
    {
        self.credentials = credentials
        self.baseEnv = baseEnv
    }

    func resolve(provider: UsageProvider, providerConfig: ProviderConfig?) -> ProviderRuntimeSettings {
        let preferred = providerConfig?.source ?? .auto
        let sourceMode = preferred.usesWeb ? .cli : preferred

        var env = ProviderConfigEnvironment.applyAPIKeyOverride(
            base: self.baseEnv,
            provider: provider,
            config: providerConfig)
        let configHasAPIKey = providerConfig?.sanitizedAPIKey != nil
        if !configHasAPIKey,
           let apiKey = self.credentials.apiKey(for: .init(provider: provider))
        {
            env = ProviderConfigEnvironment.applyAPIKeyOverride(
                base: env,
                provider: provider,
                config: ProviderConfig(id: provider, apiKey: apiKey))
        }

        return ProviderRuntimeSettings(sourceMode: sourceMode, env: env)
    }
}
