import Foundation

public enum KimiSettingsReader {
    public static let apiTokenKeys = [
        "KIMI_CODE_API_KEY",
        "KIMI_API_KEY",
    ]

    public static func apiKey(environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        for key in self.apiTokenKeys {
            if let cleaned = self.cleaned(environment[key]) {
                return cleaned
            }
        }
        return nil
    }

    public static func codingBaseURL(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let raw = self.cleaned(environment["KIMI_CODE_BASE_URL"]),
           let url = URL(string: raw)
        {
            return url
        }
        return URL(string: "https://api.kimi.com/coding/v1")!
    }

    public static func oauthHost(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        let raw = self.cleaned(environment["KIMI_CODE_OAUTH_HOST"])
            ?? self.cleaned(environment["KIMI_OAUTH_HOST"])
            ?? "https://auth.kimi.com"
        return URL(string: raw)!
    }

    public static func shareDirectory(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL
    {
        if let raw = self.cleaned(environment["KIMI_HOME"]) {
            return URL(fileURLWithPath: raw, isDirectory: true)
        }
        return homeDirectory.appendingPathComponent(".kimi", isDirectory: true)
    }

    public static func credentialsFileURL(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL
    {
        self.shareDirectory(environment: environment, homeDirectory: homeDirectory)
            .appendingPathComponent("credentials", isDirectory: true)
            .appendingPathComponent("kimi-code.json", isDirectory: false)
    }

    public static func deviceIDFileURL(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL
    {
        self.shareDirectory(environment: environment, homeDirectory: homeDirectory)
            .appendingPathComponent("device_id", isDirectory: false)
    }

    static func cleaned(_ raw: String?) -> String? {
        guard var value = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }

        if (value.hasPrefix("\"") && value.hasSuffix("\"")) ||
            (value.hasPrefix("'") && value.hasSuffix("'"))
        {
            value.removeFirst()
            value.removeLast()
        }

        value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
