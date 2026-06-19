import Foundation

enum CodexChatGPTBaseURLResolver {
    static let defaultBackendAPIBaseURL = "https://chatgpt.com/backend-api"

    enum BackendAPIResolution {
        case chatGPTHostsOnly
        case always
    }

    static func resolveNormalizedBaseURL(
        env: [String: String],
        configContents: String? = nil,
        backendAPIResolution: BackendAPIResolution) -> String
    {
        let baseURL = self.resolveBaseURL(env: env, configContents: configContents)
        return self.normalizeBaseURL(baseURL, backendAPIResolution: backendAPIResolution)
    }

    private static func resolveBaseURL(env: [String: String], configContents: String?) -> String {
        if let configContents, let parsed = self.parseChatGPTBaseURL(from: configContents) {
            return parsed
        }
        if let contents = self.loadConfigContents(env: env),
           let parsed = self.parseChatGPTBaseURL(from: contents)
        {
            return parsed
        }
        return Self.defaultBackendAPIBaseURL
    }

    private static func normalizeBaseURL(_ value: String, backendAPIResolution: BackendAPIResolution) -> String {
        var trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { trimmed = Self.defaultBackendAPIBaseURL }
        while trimmed.hasSuffix("/") {
            trimmed.removeLast()
        }

        switch backendAPIResolution {
        case .chatGPTHostsOnly:
            if self.isChatGPTHost(trimmed), !trimmed.contains("/backend-api") {
                trimmed += "/backend-api"
            }
        case .always:
            if !trimmed.contains("/backend-api") {
                trimmed += "/backend-api"
            }
        }

        return trimmed
    }

    private static func isChatGPTHost(_ value: String) -> Bool {
        value.hasPrefix("https://chatgpt.com") || value.hasPrefix("https://chat.openai.com")
    }

    private static func parseChatGPTBaseURL(from contents: String) -> String? {
        for rawLine in contents.split(whereSeparator: \.isNewline) {
            let line = rawLine.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: true).first
            let trimmed = line?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !trimmed.isEmpty else { continue }
            let parts = trimmed.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: true)
            guard parts.count == 2 else { continue }
            let key = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
            guard key == "chatgpt_base_url" else { continue }
            var value = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
            if value.hasPrefix("\""), value.hasSuffix("\"") {
                value = String(value.dropFirst().dropLast())
            } else if value.hasPrefix("'"), value.hasSuffix("'") {
                value = String(value.dropFirst().dropLast())
            }
            return value.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }

    private static func loadConfigContents(env: [String: String]) -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let codexHome = env["CODEX_HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        let root = (codexHome?.isEmpty == false) ? URL(fileURLWithPath: codexHome!) : home
            .appendingPathComponent(".codex")
        let url = root.appendingPathComponent("config.toml")
        return try? String(contentsOf: url, encoding: .utf8)
    }
}
