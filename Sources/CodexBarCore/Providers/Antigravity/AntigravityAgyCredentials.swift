import Foundation

public enum AntigravityCredentialSourcePreference: Sendable {
    /// Prefer CodexBar-managed OAuth, then fall back to the Antigravity CLI (`agy`) session.
    case automatic
    /// Use only the Antigravity CLI OAuth session at `~/.gemini/oauth_creds.json`.
    case agyCLI
    /// Use only CodexBar-managed OAuth at `~/.codexbar/antigravity/oauth_creds.json`.
    case codexbarStore
}

/// Reads Antigravity CLI (`agy`) OAuth credentials shared with the Gemini home directory.
public enum AntigravityAgyCredentials {
    private static let log = CodexBarLog.logger(LogCategories.antigravity)

    public static func credentialsURL(homeDirectory: String = NSHomeDirectory()) -> URL {
        URL(fileURLWithPath: homeDirectory, isDirectory: true)
            .appendingPathComponent(".gemini", isDirectory: true)
            .appendingPathComponent("oauth_creds.json")
    }

    public static func isCLIInstalled(
        env: [String: String] = ProcessInfo.processInfo.environment,
        loginPATH: [String]? = LoginShellPathCache.shared.current) -> Bool
    {
        BinaryLocator.resolveAgyBinary(env: env, loginPATH: loginPATH) != nil
    }

    public static func hasStoredCredentials(
        homeDirectory: String = NSHomeDirectory(),
        fileManager: FileManager = .default) -> Bool
    {
        fileManager.fileExists(atPath: self.credentialsURL(homeDirectory: homeDirectory).path)
    }

    public static func isAvailable(
        homeDirectory: String = NSHomeDirectory(),
        env: [String: String] = ProcessInfo.processInfo.environment,
        loginPATH: [String]? = LoginShellPathCache.shared.current,
        fileManager: FileManager = .default) -> Bool
    {
        self.isCLIInstalled(env: env, loginPATH: loginPATH)
            && self.hasStoredCredentials(homeDirectory: homeDirectory, fileManager: fileManager)
    }

    public static func loadCredentials(
        homeDirectory: String = NSHomeDirectory(),
        fileManager: FileManager = .default) throws -> AntigravityOAuthCredentials?
    {
        let url = self.credentialsURL(homeDirectory: homeDirectory)
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        let credentials = try JSONDecoder().decode(AntigravityOAuthCredentials.self, from: data)
        self.log.debug("Loaded Antigravity CLI OAuth credentials", metadata: [
            "path": url.path,
            "hasRefreshToken": credentials.refreshToken?.isEmpty == false ? "1" : "0",
        ])
        return credentials
    }
}
