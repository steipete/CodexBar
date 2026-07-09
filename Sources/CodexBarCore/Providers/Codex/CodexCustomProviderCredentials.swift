import Foundation

/// Zero-config credential resolution for the Codex "Custom API" usage source.
///
/// Reads the custom provider's base URL from `~/.codex/config.toml` (top-level
/// `model_provider`, then `base_url` under `[model_providers.<that provider>]`)
/// and the API key from `~/.codex/auth.json`'s `OPENAI_API_KEY`. Both honor
/// `CODEX_HOME` so they track the same account switching as the rest of Codex.
///
/// This is a pure file reader: no network, no Keychain. The TOML handling is a
/// small hand-written fragment scanner in the style of the existing
/// `parseChatGPTBaseURL` line scanner, extended to track the current `[table]`
/// header. No third-party TOML library is introduced.
public enum CodexCustomProviderCredentials {
    /// Resolves the custom provider credentials for the given environment.
    ///
    /// Returns `nil` (rather than a wrong host) when either the base URL or the
    /// API key cannot be resolved — the custom source then surfaces as
    /// unavailable instead of querying a guessed host.
    public static func resolve(
        env: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default) -> (baseURL: URL, apiKey: String)?
    {
        guard let baseURL = self.resolveBaseURL(env: env, fileManager: fileManager) else { return nil }
        guard let apiKey = self.resolveAPIKey(env: env, fileManager: fileManager) else { return nil }
        return (baseURL, apiKey)
    }

    /// Returns the resolved base URL, or `nil` when `config.toml` has no
    /// `model_provider` or the named provider has no `base_url`.
    public static func resolveBaseURL(
        env: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default) -> URL?
    {
        let configURL = CodexHomeScope
            .ambientHomeURL(env: env, fileManager: fileManager)
            .appendingPathComponent("config.toml")
        guard let contents = try? String(contentsOf: configURL, encoding: .utf8) else { return nil }
        return self.baseURL(from: contents)
    }

    /// Returns `OPENAI_API_KEY` from `auth.json`, or `nil` when absent.
    public static func resolveAPIKey(
        env: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default) -> String?
    {
        let authURL = CodexHomeScope
            .ambientHomeURL(env: env, fileManager: fileManager)
            .appendingPathComponent("auth.json")
        guard let data = try? Data(contentsOf: authURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let apiKey = json["OPENAI_API_KEY"] as? String
        else {
            return nil
        }
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Parses `config.toml` contents into a base URL.
    ///
    /// Reads the top-level `model_provider` value, then resolves `base_url`
    /// under `[model_providers.<model_provider>]`. Returns `nil` when the
    /// provider is not configured or its `base_url` is missing/invalid.
    static func baseURL(from contents: String) -> URL? {
        let provider = self.modelProvider(from: contents)
        guard let provider, !provider.isEmpty else { return nil }
        guard let rawBaseURL = self.baseURL(forProvider: provider, from: contents) else { return nil }
        guard let url = URL(string: rawBaseURL),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https"
        else {
            return nil
        }
        return url
    }

    /// Extracts the top-level `model_provider` value (the one outside any
    /// `[table]` header).
    static func modelProvider(from contents: String) -> String? {
        var inTable = false
        for rawLine in contents.split(whereSeparator: \.isNewline) {
            let stripped = Self.stripComment(rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !stripped.isEmpty else { continue }

            if stripped.hasPrefix("[") {
                inTable = true
                continue
            }
            // A `model_provider = "…"` line before any table header is the top-level value.
            // Once inside a table, skip — table-scoped `model_provider` keys are not the
            // top-level selector.
            if inTable { continue }
            if let value = Self.value(forKey: "model_provider", in: stripped) {
                return value
            }
        }
        return nil
    }

    /// Resolves `base_url` under the `[model_providers.<provider>]` table.
    static func baseURL(forProvider provider: String, from contents: String) -> String? {
        let targetHeader = "[model_providers.\(provider)]"
        let targetHeaderQuoted = "[model_providers.\"\(provider)\"]"
        var inTargetTable = false
        for rawLine in contents.split(whereSeparator: \.isNewline) {
            let stripped = Self.stripComment(rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !stripped.isEmpty else { continue }

            if stripped.hasPrefix("[") {
                inTargetTable = stripped == targetHeader || stripped == targetHeaderQuoted
                continue
            }
            guard inTargetTable else { continue }
            if let value = Self.value(forKey: "base_url", in: stripped) {
                return value
            }
        }
        return nil
    }

    /// Splits a `key = value` line, trimming surrounding quotes from the value.
    private static func value(forKey key: String, in line: String) -> String? {
        let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: true)
        guard parts.count == 2 else { return nil }
        let parsedKey = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
        guard parsedKey == key else { return nil }
        var value = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
        if (value.hasPrefix("\"") && value.hasSuffix("\"")) ||
            (value.hasPrefix("'") && value.hasSuffix("'"))
        {
            value = String(value.dropFirst().dropLast())
        }
        value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private static func stripComment(_ line: Substring) -> Substring {
        line.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: true).first ?? ""
    }
}
