import Foundation

/// Reads the Hugging Face access token from CodexBar config projection, the official
/// environment variables, or the token file written by `hf auth login`.
public struct HuggingFaceSettingsReader: Sendable {
    public static let configAPIKeyEnvironmentKey = "CODEXBAR_HUGGINGFACE_API_KEY"
    public static let apiKeyEnvironmentKeys = [
        "HF_TOKEN",
        "HUGGING_FACE_HUB_TOKEN",
    ]
    public static let tokenPathEnvironmentKey = "HF_TOKEN_PATH"
    public static let homeEnvironmentKey = "HF_HOME"
    public static let cacheHomeEnvironmentKey = "XDG_CACHE_HOME"

    public static func apiKey(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> String?
    {
        for key in [self.configAPIKeyEnvironmentKey] + self.apiKeyEnvironmentKeys {
            if let token = self.cleaned(environment[key]) {
                return token
            }
        }
        return self.cliToken(environment: environment, homeDirectory: homeDirectory)
    }

    static func cliToken(environment: [String: String], homeDirectory: URL) -> String? {
        let url = self.tokenFileURL(environment: environment, homeDirectory: homeDirectory)
        guard FileManager.default.isReadableFile(atPath: url.path),
              let raw = try? String(contentsOf: url, encoding: .utf8)
        else {
            return nil
        }
        return self.cleaned(raw.split(whereSeparator: \.isNewline).first.map(String.init))
    }

    static func tokenFileURL(environment: [String: String], homeDirectory: URL) -> URL {
        if let path = self.cleaned(environment[self.tokenPathEnvironmentKey]) {
            return URL(fileURLWithPath: NSString(string: path).expandingTildeInPath, isDirectory: false)
        }
        if let hfHome = self.cleaned(environment[self.homeEnvironmentKey]) {
            return URL(fileURLWithPath: NSString(string: hfHome).expandingTildeInPath, isDirectory: true)
                .appendingPathComponent("token", isDirectory: false)
        }
        // huggingface_hub derives its default home from XDG_CACHE_HOME before ~/.cache.
        let cacheRoot: URL = if let xdgCacheHome = self.cleaned(environment[self.cacheHomeEnvironmentKey]) {
            URL(fileURLWithPath: NSString(string: xdgCacheHome).expandingTildeInPath, isDirectory: true)
        } else {
            homeDirectory.appendingPathComponent(".cache", isDirectory: true)
        }
        return cacheRoot
            .appendingPathComponent("huggingface", isDirectory: true)
            .appendingPathComponent("token", isDirectory: false)
    }

    private static func cleaned(_ raw: String?) -> String? {
        guard var value = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        if (value.hasPrefix("\"") && value.hasSuffix("\""))
            || (value.hasPrefix("'") && value.hasSuffix("'"))
        {
            value = String(value.dropFirst().dropLast())
        }
        value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
