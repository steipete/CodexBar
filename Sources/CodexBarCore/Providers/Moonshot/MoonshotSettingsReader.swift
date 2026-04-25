import Foundation

public struct MoonshotSettingsReader: Sendable {
    public static let apiKeyEnvironmentKeys = [
        "MOONSHOT_API_KEY",
        "MOONSHOT_KEY",
    ]
    public static let regionEnvironmentKey = "MOONSHOT_REGION"

    public static func apiKey(
        environment: [String: String] = ProcessInfo.processInfo.environment) -> String?
    {
        for key in self.apiKeyEnvironmentKeys {
            guard let raw = environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !raw.isEmpty
            else {
                continue
            }
            let cleaned = Self.cleaned(raw)
            if !cleaned.isEmpty {
                return cleaned
            }
        }

        // Fall back to Kimi CLI config file
        if let configContents = Self.loadKimiConfigContents() {
            if let key = Self.parseKimiConfigAPIKey(configContents) {
                return key
            }
        }

        return nil
    }

    public static func region(
        environment: [String: String] = ProcessInfo.processInfo.environment) -> MoonshotRegion
    {
        guard let raw = environment[self.regionEnvironmentKey] else {
            return .international
        }
        let cleaned = Self.cleaned(raw).lowercased()
        return MoonshotRegion(rawValue: cleaned) ?? .international
    }

    private static func cleaned(_ raw: String) -> String {
        var value = raw
        if (value.hasPrefix("\"") && value.hasSuffix("\"")) ||
            (value.hasPrefix("'") && value.hasSuffix("'"))
        {
            value.removeFirst()
            value.removeLast()
        }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Kimi CLI config fallback

    static func parseKimiConfigAPIKey(_ contents: String) -> String? {
        let lines = contents.split(whereSeparator: \.isNewline)
        var inMoonshotSection = false

        for rawLine in lines {
            let line = rawLine.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first
            let trimmed = line?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !trimmed.isEmpty else { continue }

            if trimmed.hasPrefix("[") {
                inMoonshotSection = (trimmed == "[providers.\"managed:moonshot-ai\"]")
                continue
            }

            guard inMoonshotSection else { continue }

            let parts = trimmed.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: true)
            guard parts.count == 2 else { continue }
            let key = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
            guard key == "api_key" else { continue }
            var value = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
            value = Self.cleaned(value)
            return value.isEmpty ? nil : value
        }

        return nil
    }

    private static func loadKimiConfigContents() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let url = home.appendingPathComponent(".kimi/config.toml")
        return try? String(contentsOf: url, encoding: .utf8)
    }
}
