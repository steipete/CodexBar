import Foundation

public enum FactorySettingsReader {
    public static let apiTokenKey = "FACTORY_API_KEY"

    /// Resolves a Factory API key from `FACTORY_API_KEY`, then optional `~/.factory/.env`.
    /// Dotenv lookup uses `HOME` from `environment` when present; otherwise the process home directory
    /// when `environment` is omitted. Tests can pass an empty env (no `HOME`) to skip dotenv.
    public static func apiKey(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL? = nil) -> String?
    {
        if let fromEnv = self.cleaned(environment[self.apiTokenKey]) {
            return fromEnv
        }
        guard let home = homeDirectory ?? self.homeDirectory(from: environment) else {
            return nil
        }
        return self.apiKeyFromFactoryDotEnv(homeDirectory: home)
    }

    public static func apiKeyFromFactoryDotEnv(homeDirectory: URL) -> String? {
        let envFile = homeDirectory
            .appendingPathComponent(".factory", isDirectory: true)
            .appendingPathComponent(".env", isDirectory: false)
        guard let contents = try? String(contentsOf: envFile, encoding: .utf8) else {
            return nil
        }
        return self.parseFactoryAPIKey(fromDotEnv: contents)
    }

    static func parseFactoryAPIKey(fromDotEnv contents: String) -> String? {
        for rawLine in contents.split(whereSeparator: \.isNewline) {
            var line = String(rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            if line.hasPrefix("export ") {
                line = String(line.dropFirst("export ".count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            guard let separator = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<separator]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard key == self.apiTokenKey else { continue }
            let value = String(line[line.index(after: separator)...])
            return self.cleaned(value)
        }
        return nil
    }

    static func homeDirectory(from environment: [String: String]) -> URL? {
        guard let home = self.cleaned(environment["HOME"]) else {
            return nil
        }
        let expanded = NSString(string: home).expandingTildeInPath
        return URL(fileURLWithPath: expanded, isDirectory: true)
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
}
