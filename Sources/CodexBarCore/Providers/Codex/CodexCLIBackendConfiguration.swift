import Foundation

enum CodexCLIBackendRateLimitError: LocalizedError, Equatable, Sendable {
    enum Backend: Equatable, Sendable {
        case amazonBedrock
        case customProvider
    }

    case chatGPTRateLimitsUnavailable(Backend)

    var errorDescription: String? {
        switch self {
        case .chatGPTRateLimitsUnavailable(.amazonBedrock):
            "Codex is configured for Amazon Bedrock; ChatGPT rate limits are unavailable. " +
                "Disable the Codex usage card or use cost-based tracking."
        case .chatGPTRateLimitsUnavailable(.customProvider):
            "Codex is configured for a custom provider; ChatGPT rate limits are unavailable. " +
                "Disable the Codex usage card or use cost-based tracking."
        }
    }

    static func classify(
        _ error: Error,
        environment: [String: String],
        fileManager: FileManager = .default) -> Self?
    {
        guard let contents = CodexCLIBackendConfiguration.loadContents(
            environment: environment,
            fileManager: fileManager)
        else { return nil }
        return self.classify(errorDescription: error.localizedDescription, configContents: contents)
    }

    static func classify(errorDescription: String, configContents: String) -> Self? {
        let lower = errorDescription.lowercased()
        guard lower.contains("codex account authentication required") ||
            lower.contains("account authentication required to read rate limits") ||
            lower.contains("requiresopenaiauth")
        else { return nil }
        guard let configuration = CodexCLIBackendConfiguration(contents: configContents),
              !configuration.requiresOpenAIAuth
        else { return nil }
        return .chatGPTRateLimitsUnavailable(configuration.backend)
    }
}

private struct CodexCLIBackendConfiguration {
    private static let maximumConfigBytes = 256 * 1024
    // Provider-specific by design: Codex CLI assigns fixed IDs to its ChatGPT-authenticated and Bedrock backends.
    private static let openAIProviderIDs: Set<String> = ["openai", "chatgpt"]
    private static let amazonBedrockProviderIDs: Set<String> = ["amazon-bedrock", "amazon-bedrock-runtime"]

    struct ProviderSettings {
        var name: String?
        var requiresOpenAIAuth: Bool?
    }

    let requiresOpenAIAuth: Bool
    let backend: CodexCLIBackendRateLimitError.Backend

    init?(contents: String) {
        var activeProviderID: String?
        var currentProviderID: String?
        var providerSettings: [String: ProviderSettings] = [:]

        for rawLine in contents.components(separatedBy: .newlines) {
            let line = Self.removingComment(from: rawLine)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }

            if line.hasPrefix("[") {
                currentProviderID = Self.modelProviderID(fromTableHeader: line)
                continue
            }

            let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            let key = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
            let value = String(parts[1])

            if currentProviderID == nil, key == "model_provider" {
                activeProviderID = Self.tomlString(value)
                continue
            }

            guard let currentProviderID else { continue }
            switch key {
            case "name":
                providerSettings[currentProviderID, default: ProviderSettings()].name = Self.tomlString(value)
            case "requires_openai_auth":
                providerSettings[currentProviderID, default: ProviderSettings()].requiresOpenAIAuth =
                    Self.tomlBool(value)
            default:
                continue
            }
        }

        guard let activeProviderID = activeProviderID?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !activeProviderID.isEmpty
        else { return nil }

        let normalizedID = activeProviderID.lowercased()
        if Self.openAIProviderIDs.contains(normalizedID) {
            self.requiresOpenAIAuth = true
            self.backend = .customProvider
            return
        }

        let settings = providerSettings[activeProviderID]
            ?? providerSettings.first(where: { $0.key.caseInsensitiveCompare(activeProviderID) == .orderedSame })?.value
        self.requiresOpenAIAuth = settings?.requiresOpenAIAuth ?? false
        let normalizedName = settings?.name?.lowercased() ?? ""
        // Provider-specific by design: Custom provider names can identify Bedrock under a user-defined provider ID.
        self.backend = Self.amazonBedrockProviderIDs.contains(normalizedID) || normalizedName.contains("bedrock")
            ? .amazonBedrock
            : .customProvider
    }

    static func loadContents(
        environment: [String: String],
        fileManager: FileManager) -> String?
    {
        let codexHome = environment["CODEX_HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        let root = if let codexHome, !codexHome.isEmpty {
            URL(fileURLWithPath: codexHome, isDirectory: true)
        } else {
            fileManager.homeDirectoryForCurrentUser.appendingPathComponent(".codex", isDirectory: true)
        }
        let configURL = root.appendingPathComponent("config.toml")
        guard let handle = try? FileHandle(forReadingFrom: configURL) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: Self.maximumConfigBytes),
              !data.isEmpty
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func modelProviderID(fromTableHeader line: String) -> String? {
        guard line.hasPrefix("["), line.hasSuffix("]"), !line.hasPrefix("[[") else { return nil }
        let header = line.dropFirst().dropLast().trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = "model_providers."
        guard header.hasPrefix(prefix) else { return nil }
        let rawID = String(header.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawID.isEmpty else { return nil }
        return Self.tomlString(rawID) ?? (rawID.contains(".") ? nil : rawID)
    }

    private static func removingComment(from line: String) -> String {
        var quote: Character?
        var escaped = false
        for index in line.indices {
            let character = line[index]
            if let activeQuote = quote {
                if activeQuote == "\"", character == "\\", !escaped {
                    escaped = true
                    continue
                }
                if character == activeQuote, !escaped {
                    quote = nil
                }
                escaped = false
                continue
            }
            if character == "\"" || character == "'" {
                quote = character
            } else if character == "#" {
                return String(line[..<index])
            }
        }
        return line
    }

    private static func tomlString(_ rawValue: String) -> String? {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let quote = value.first, quote == "\"" || quote == "'" else { return nil }
        if quote == "'" {
            guard let end = value.dropFirst().firstIndex(of: "'") else { return nil }
            return String(value[value.index(after: value.startIndex)..<end])
        }

        var escaped = false
        var index = value.index(after: value.startIndex)
        while index < value.endIndex {
            let character = value[index]
            if character == "\"", !escaped {
                let token = String(value[...index])
                return try? JSONDecoder().decode(String.self, from: Data(token.utf8))
            }
            if character == "\\" {
                escaped.toggle()
            } else {
                escaped = false
            }
            index = value.index(after: index)
        }
        return nil
    }

    private static func tomlBool(_ rawValue: String) -> Bool? {
        switch rawValue.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "true": true
        case "false": false
        default: nil
        }
    }
}
