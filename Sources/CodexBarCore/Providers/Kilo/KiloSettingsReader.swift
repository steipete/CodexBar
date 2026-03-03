import Foundation

public enum KiloSettingsReader {
    public static let apiTokenKey = "KILO_API_KEY"

    public static func apiKey(environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        self.cleaned(environment[self.apiTokenKey])
    }

    public static func apiURL(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        _ = environment
        return URL(string: "https://app.kilo.ai/api/trpc")!
    }

    public static func authToken(
        authFileURL: URL? = nil,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> String?
    {
        let fileURL = authFileURL ?? self.defaultAuthFileURL(homeDirectory: homeDirectory)
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return self.parseAuthToken(data: data)
    }

    static func defaultAuthFileURL(homeDirectory: URL) -> URL {
        homeDirectory
            .appendingPathComponent(".local", isDirectory: true)
            .appendingPathComponent("share", isDirectory: true)
            .appendingPathComponent("kilo", isDirectory: true)
            .appendingPathComponent("auth.json", isDirectory: false)
    }

    static func parseAuthToken(data: Data) -> String? {
        guard let payload = try? JSONDecoder().decode(AuthFile.self, from: data) else {
            return nil
        }
        return self.cleaned(payload.kilo?.access)
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

private struct AuthFile: Decodable {
    let kilo: KiloSection?

    struct KiloSection: Decodable {
        let access: String?
    }
}
