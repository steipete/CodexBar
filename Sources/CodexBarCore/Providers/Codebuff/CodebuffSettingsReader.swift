import Foundation

/// Reads Codebuff settings from the environment or the local credentials file
/// that the `codebuff` CLI (formerly `manicode`) writes when the user logs in.
public enum CodebuffSettingsReader {
    /// Environment variable key for the Codebuff API token.
    public static let apiTokenKey = "CODEBUFF_API_KEY"

    /// Returns the API token from environment if present and non-empty.
    public static func apiKey(environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        self.cleaned(environment[self.apiTokenKey])
    }

    /// Returns the API base URL, defaulting to the production endpoint.
    public static func apiURL(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let override = self.validAPIURL(environment: environment) {
            return override
        }
        return URL(string: "https://www.codebuff.com")!
    }

    public static func validateEndpointOverrides(
        environment: [String: String] = ProcessInfo.processInfo.environment) throws
    {
        if self.hasExplicitNonHTTPSURL(environment["CODEBUFF_API_URL"]) {
            throw CodebuffSettingsError.invalidEndpointOverride("CODEBUFF_API_URL")
        }
    }

    /// Returns the auth token from the local credentials file if present.
    public static func authToken(
        authFileURL: URL? = nil,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> String?
    {
        let fileURL = authFileURL ?? self.defaultAuthFileURL(homeDirectory: homeDirectory)
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return self.parseAuthToken(data: data)
    }

    /// Default on-disk credentials path: `~/.config/manicode/credentials.json`.
    static func defaultAuthFileURL(homeDirectory: URL) -> URL {
        homeDirectory
            .appendingPathComponent(".config", isDirectory: true)
            .appendingPathComponent("manicode", isDirectory: true)
            .appendingPathComponent("credentials.json", isDirectory: false)
    }

    static func parseAuthToken(data: Data) -> String? {
        guard let payload = try? JSONDecoder().decode(CredentialsFile.self, from: data) else {
            return nil
        }
        return self.cleaned(payload.default?.authToken) ?? self.cleaned(payload.authToken)
    }

    static func cleaned(_ raw: String?) -> String? {
        guard var value = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }

        if (value.hasPrefix("\"") && value.hasSuffix("\"")) ||
            (value.hasPrefix("'") && value.hasSuffix("'"))
        {
            value = String(value.dropFirst().dropLast())
        }

        value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private static func validAPIURL(environment: [String: String]) -> URL? {
        guard let raw = self.cleaned(environment["CODEBUFF_API_URL"]) else { return nil }
        if let url = URL(string: raw), let scheme = url.scheme {
            return scheme.lowercased() == "https" ? url : nil
        }
        return URL(string: "https://\(raw)")
    }

    private static func hasExplicitNonHTTPSURL(_ raw: String?) -> Bool {
        guard let cleaned = self.cleaned(raw),
              let scheme = URL(string: cleaned)?.scheme
        else { return false }
        return scheme.lowercased() != "https"
    }
}

private struct CredentialsFile: Decodable {
    let `default`: CredentialsProfile?
    let authToken: String?
}

private struct CredentialsProfile: Decodable {
    let authToken: String?
    let fingerprintId: String?
    let email: String?
    let name: String?
}
