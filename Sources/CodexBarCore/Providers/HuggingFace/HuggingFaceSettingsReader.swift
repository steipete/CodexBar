import Foundation

public enum HuggingFaceSettingsReader {
    public static let tokenEnvironmentKey = "HF_TOKEN"
    public static let hubTokenEnvironmentKey = "HUGGING_FACE_HUB_TOKEN"
    public static let tokenPathEnvironmentKey = "HF_TOKEN_PATH"
    public static let homeEnvironmentKey = "HF_HOME"
    public static let cacheHomeEnvironmentKey = "XDG_CACHE_HOME"

    public static func token(environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        self.token(
            environment: environment,
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser,
            fileManager: .default)
    }

    static func token(
        environment: [String: String],
        homeDirectory: URL,
        fileManager: FileManager = .default) -> String?
    {
        if let token = self.cleaned(environment[self.tokenEnvironmentKey]) {
            return token
        }
        if let token = self.cleaned(environment[self.hubTokenEnvironmentKey]) {
            return token
        }

        let tokenURL = self.tokenFileURL(environment: environment, homeDirectory: homeDirectory)
        guard fileManager.fileExists(atPath: tokenURL.path),
              let raw = try? String(contentsOf: tokenURL, encoding: .utf8)
        else {
            return nil
        }

        let firstLine = raw.split(whereSeparator: \.isNewline).first.map(String.init)
        return self.cleaned(firstLine)
    }

    static func tokenFileURL(environment: [String: String], homeDirectory: URL) -> URL {
        if let explicitPath = self.cleaned(environment[self.tokenPathEnvironmentKey]) {
            return self.expandedPath(explicitPath, homeDirectory: homeDirectory)
        }

        if let hfHome = self.cleaned(environment[self.homeEnvironmentKey]) {
            return self.expandedPath(hfHome, homeDirectory: homeDirectory)
                .appendingPathComponent("token", isDirectory: false)
        }

        if let cacheHome = self.cleaned(environment[self.cacheHomeEnvironmentKey]) {
            return self.expandedPath(cacheHome, homeDirectory: homeDirectory)
                .appendingPathComponent("huggingface/token", isDirectory: false)
        }

        return homeDirectory.appendingPathComponent(".cache/huggingface/token", isDirectory: false)
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

    private static func expandedPath(_ path: String, homeDirectory: URL) -> URL {
        if path == "~" {
            return homeDirectory
        }
        if path.hasPrefix("~/") {
            return homeDirectory.appendingPathComponent(String(path.dropFirst(2)), isDirectory: false)
        }
        return URL(fileURLWithPath: path)
    }
}

public enum HuggingFaceSettingsError: LocalizedError, Sendable, Equatable {
    case missingToken

    public var errorDescription: String? {
        switch self {
        case .missingToken:
            "Hugging Face user access token not configured. Set HF_TOKEN or HUGGING_FACE_HUB_TOKEN, " +
                "run hf auth login, or configure in Settings."
        }
    }
}
