import Foundation

public struct KiloResolvedBearerToken: Sendable, Equatable {
    public let token: String
    public let sourceLabel: String

    public init(token: String, sourceLabel: String) {
        self.token = token
        self.sourceLabel = sourceLabel
    }
}

/// Resolves the Kilo bearer token shared by usage fetches and organization discovery.
///
/// Behavior mirrors the per-strategy resolution in `KiloProviderDescriptor`:
/// - `.api`: explicit `apiKey`, falling back to `KILO_API_KEY` env var.
/// - `.cli`: token from `~/.local/share/kilo/auth.json` (`kilo.access`).
/// - `.auto`: API first, falling back to CLI when API credentials are missing.
public enum KiloBearerTokenResolver {
    public static func resolve(
        source: KiloUsageDataSource,
        apiKey: String?,
        environment: [String: String] = ProcessInfo.processInfo.environment) throws -> KiloResolvedBearerToken
    {
        switch source {
        case .api:
            return try self.resolveAPI(apiKey: apiKey, environment: environment)
        case .cli:
            return try self.resolveCLI(environment: environment)
        case .auto:
            if let resolved = try? self.resolveAPI(apiKey: apiKey, environment: environment) {
                return resolved
            }
            return try self.resolveCLI(environment: environment)
        }
    }

    private static func resolveAPI(
        apiKey: String?,
        environment: [String: String]) throws -> KiloResolvedBearerToken
    {
        let direct = KiloSettingsReader.cleaned(apiKey)
        let envValue = KiloSettingsReader.cleaned(environment[KiloSettingsReader.apiTokenKey])
        if let token = direct ?? envValue {
            return KiloResolvedBearerToken(token: token, sourceLabel: "api")
        }
        throw KiloUsageError.missingCredentials
    }

    private static func resolveCLI(
        environment: [String: String]) throws -> KiloResolvedBearerToken
    {
        let url = self.authFileURL(environment: environment)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw KiloUsageError.cliSessionMissing(url.path)
        }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw KiloUsageError.cliSessionUnreadable(url.path)
        }
        guard let token = KiloSettingsReader.parseAuthToken(data: data) else {
            throw KiloUsageError.cliSessionInvalid(url.path)
        }
        return KiloResolvedBearerToken(token: token, sourceLabel: "cli")
    }

    static func authFileURL(environment: [String: String]) -> URL {
        if let home = KiloSettingsReader.cleaned(environment["HOME"]) {
            let expandedHome = NSString(string: home).expandingTildeInPath
            return KiloSettingsReader.defaultAuthFileURL(
                homeDirectory: URL(fileURLWithPath: expandedHome, isDirectory: true))
        }
        return KiloSettingsReader.defaultAuthFileURL(
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser)
    }
}
