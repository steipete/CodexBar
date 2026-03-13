import Foundation

public struct ProviderCredentialKey: Hashable, Sendable {
    public let provider: UsageProvider

    public init(provider: UsageProvider) {
        self.provider = provider
    }
}

public protocol ProviderCredentialStore: Sendable {
    func apiKey(for key: ProviderCredentialKey) -> String?
}

public struct EnvironmentProviderCredentialStore: ProviderCredentialStore {
    private let env: [String: String]

    public init(env: [String: String] = ProcessInfo.processInfo.environment) {
        self.env = env
    }

    public func apiKey(for key: ProviderCredentialKey) -> String? {
        let names = Self.environmentNames(for: key.provider)
        for name in names {
            if let value = self.env[name]?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
                return value
            }
        }
        return nil
    }

    private static func environmentNames(for provider: UsageProvider) -> [String] {
        switch provider {
        case .zai:
            [ZaiSettingsReader.apiTokenKey]
        case .copilot:
            ["COPILOT_API_TOKEN"]
        case .minimax:
            [MiniMaxAPISettingsReader.apiTokenKey]
        case .kimik2:
            KimiK2SettingsReader.apiKeyEnvironmentKeys
        case .synthetic:
            [SyntheticSettingsReader.apiKeyKey]
        case .warp:
            WarpSettingsReader.apiKeyEnvironmentKeys
        default:
            []
        }
    }
}

public struct FileProviderCredentialStore: ProviderCredentialStore {
    public let fileURL: URL
    private let fileManager: FileManager
    private let decoder: JSONDecoder

    public init(
        fileURL: URL = Self.defaultURL(),
        fileManager: FileManager = .default,
        decoder: JSONDecoder = JSONDecoder())
    {
        self.fileURL = fileURL
        self.fileManager = fileManager
        self.decoder = decoder
    }

    public func apiKey(for key: ProviderCredentialKey) -> String? {
        guard let map = self.loadMap() else { return nil }
        guard let value = map[key.provider.rawValue]?.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        return value.isEmpty ? nil : value
    }

    public static func defaultURL(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home
            .appendingPathComponent(".codexbar", isDirectory: true)
            .appendingPathComponent("credentials.json")
    }

    private func loadMap() -> [String: String]? {
        guard self.fileManager.fileExists(atPath: self.fileURL.path) else { return nil }
        guard let data = try? Data(contentsOf: self.fileURL) else { return nil }
        return try? self.decoder.decode([String: String].self, from: data)
    }
}

public struct CompositeProviderCredentialStore: ProviderCredentialStore {
    private let stores: [any ProviderCredentialStore]

    public init(stores: [any ProviderCredentialStore]) {
        self.stores = stores
    }

    public func apiKey(for key: ProviderCredentialKey) -> String? {
        for store in self.stores {
            if let value = store.apiKey(for: key), !value.isEmpty {
                return value
            }
        }
        return nil
    }
}
