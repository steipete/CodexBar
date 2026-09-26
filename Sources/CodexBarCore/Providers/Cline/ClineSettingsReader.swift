import Foundation

public enum ClineSettingsReader {
    public static let apiKeyEnvironmentKey = "CLINE_API_KEY"
    public static let alternateAPIKeyEnvironmentKey = "CLINEPASS_API_KEY"
    public static let apiKeyEnvironmentKeys = [
        Self.apiKeyEnvironmentKey,
        Self.alternateAPIKeyEnvironmentKey,
    ]
    public static let providerSettingsPathEnvironmentKey = "CLINE_PROVIDER_SETTINGS_PATH"
    public static let dataDirEnvironmentKey = "CLINE_DATA_DIR"
    public static let clineDirEnvironmentKey = "CLINE_DIR"
    public static let authSourceSettingKey = "CLINE_AUTH_SOURCE"
    public static let workOSPrefix = "workos:"

    public static func apiKey(
        environment: [String: String] = ProcessInfo.processInfo.environment) -> String?
    {
        for key in self.apiKeyEnvironmentKeys {
            if let value = SettingsValue.cleaned(environment[key]) {
                return value
            }
        }
        return nil
    }

    /// Bearer token for the Cline API, accepting both API keys and browser sign-in sessions.
    ///
    /// Precedence: explicit `CLINE_API_KEY` / `CLINEPASS_API_KEY` first, then the OAuth session Cline writes to
    /// `~/.cline/data/settings/providers.json` when you run `cline auth` (browser sign-in).
    /// OAuth access tokens are sent as `workos:<accessToken>`, matching Cline's own `formatClineApiKey`.
    public static func resolvedToken(
        environment: [String: String] = ProcessInfo.processInfo.environment) -> String?
    {
        if let key = self.apiKey(environment: environment) {
            return key
        }
        return self.authToken(environment: environment)
    }

    /// `true` when the resolved token comes from the browser OAuth session rather than an API key.
    public static func usesBrowserSession(
        environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool
    {
        self.apiKey(environment: environment) == nil && self.authToken(environment: environment) != nil
    }

    /// OAuth bearer token from Cline's `providers.json`, formatted as `workos:<accessToken>`.
    ///
    /// Reads `providers["cline"].settings` (shared by `cline` and `cline-pass`; see Cline's
    /// `provider-auth-registry.ts` `storageProviderId: "cline"`), falling back to `providers["cline-pass"]`
    /// for forward compatibility. Returns `nil` when the file is missing, unreadable, or has no token.
    public static func authToken(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> String?
    {
        let fileURL = self.providersFileURL(environment: environment, homeDirectory: homeDirectory)
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return self.parseAuthToken(data: data)
    }

    public static func authToken(authFileURL: URL?) -> String? {
        guard let fileURL = authFileURL else { return nil }
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return self.parseAuthToken(data: data)
    }

    static func providersFileURL(
        environment: [String: String],
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL
    {
        if let override = SettingsValue.cleaned(environment[self.providerSettingsPathEnvironmentKey]) {
            return URL(fileURLWithPath: NSString(string: override).expandingTildeInPath, isDirectory: false)
        }
        if let dataDir = SettingsValue.cleaned(environment[self.dataDirEnvironmentKey]) {
            let expanded = NSString(string: dataDir).expandingTildeInPath
            return URL(fileURLWithPath: expanded, isDirectory: true)
                .appendingPathComponent("settings", isDirectory: true)
                .appendingPathComponent("providers.json", isDirectory: false)
        }
        let clineDir: URL = if let override = SettingsValue.cleaned(environment[self.clineDirEnvironmentKey]) {
            URL(fileURLWithPath: NSString(string: override).expandingTildeInPath, isDirectory: true)
        } else {
            self.defaultHomeDirectory(environment: environment, fallback: homeDirectory)
                .appendingPathComponent(".cline", isDirectory: true)
        }
        return clineDir
            .appendingPathComponent("data", isDirectory: true)
            .appendingPathComponent("settings", isDirectory: true)
            .appendingPathComponent("providers.json", isDirectory: false)
    }

    static func defaultHomeDirectory(
        environment: [String: String],
        fallback: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL
    {
        if let raw = SettingsValue.cleaned(environment["HOME"]) {
            return URL(fileURLWithPath: NSString(string: raw).expandingTildeInPath, isDirectory: true)
        }
        return fallback
    }

    static func parseAuthToken(data: Data) -> String? {
        guard let root = try? JSONDecoder().decode(ProvidersFile.self, from: data) else { return nil }
        for providerID in ["cline", "cline-pass"] {
            guard let settings = root.providers[providerID]?.settings else { continue }
            if let access = SettingsValue.cleaned(settings.auth?.accessToken) {
                return Self.formatOAuthToken(access)
            }
            if let key = SettingsValue.cleaned(settings.apiKey) {
                return key
            }
            if let key = SettingsValue.cleaned(settings.auth?.apiKey) {
                return key
            }
        }
        return nil
    }

    static func formatOAuthToken(_ accessToken: String) -> String {
        let trimmed = accessToken.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.lowercased().hasPrefix(Self.workOSPrefix) {
            return trimmed
        }
        return "\(Self.workOSPrefix)\(trimmed)"
    }
}

private struct ProvidersFile: Decodable {
    let providers: [String: StoredProviderEntry]

    init(from decoder: Decoder) throws {
        struct FileShape: Decodable {
            let providers: [String: StoredProviderEntry]?
        }
        let shape = try FileShape(from: decoder)
        self.providers = shape.providers ?? [:]
    }
}

private struct StoredProviderEntry: Decodable {
    let settings: StoredProviderSettings?
}

private struct StoredProviderSettings: Decodable {
    let apiKey: String?
    let auth: StoredAuthSettings?
}

private struct StoredAuthSettings: Decodable {
    let apiKey: String?
    let accessToken: String?
}
