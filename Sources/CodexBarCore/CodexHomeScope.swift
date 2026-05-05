import Foundation

public enum CodexHomeScope {
    public static func ambientHomeURL(
        env: [String: String],
        fileManager: FileManager = .default)
        -> URL
    {
        if let raw = env["CODEX_HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
            return URL(fileURLWithPath: raw, isDirectory: true)
        }
        return fileManager.homeDirectoryForCurrentUser.appendingPathComponent(".codex", isDirectory: true)
    }

    public static func scopedEnvironment(base: [String: String], codexHome: String?) -> [String: String] {
        guard let codexHome, !codexHome.isEmpty else { return base }
        var env = base
        env["CODEX_HOME"] = codexHome
        return env
    }
}
