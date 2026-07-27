import Foundation

public enum CommandCodeAPIKeyReader {
    public static let environmentKeys = ["COMMAND_CODE_API_KEY", "CODEXBAR_COMMANDCODE_API_KEY"]

    public static func apiKey(environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        for key in self.environmentKeys {
            if let value = self.cleaned(environment[key]) {
                return value
            }
        }

        let homeDirectory: URL = if let home = self.cleaned(environment["HOME"]) {
            URL(
                fileURLWithPath: NSString(string: home).expandingTildeInPath,
                isDirectory: true)
        } else {
            FileManager.default.homeDirectoryForCurrentUser
        }

        guard let data = try? Data(contentsOf: self.defaultAuthFileURL(homeDirectory: homeDirectory)) else {
            return nil
        }
        return self.parseAuthFile(data: data)
    }

    public static func defaultAuthFileURL(homeDirectory: URL) -> URL {
        homeDirectory
            .appendingPathComponent(".commandcode", isDirectory: true)
            .appendingPathComponent("auth.json", isDirectory: false)
    }

    static func parseAuthFile(data: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        for key in ["apiKey", "api_key", "token", "accessToken"] {
            if let value = self.cleaned(root[key] as? String) {
                return value
            }
        }
        return nil
    }

    static func cleaned(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}
