import Foundation

public enum GrokHomeScope {
    public static func normalizedHomePath(
        _ rawPath: String?,
        fileManager: FileManager = .default)
        -> String?
    {
        guard var path = rawPath?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty else {
            return nil
        }
        if path == "~" {
            path = fileManager.homeDirectoryForCurrentUser.path
        } else if path.hasPrefix("~/") {
            path = fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent(String(path.dropFirst(2)), isDirectory: true)
                .path
        } else if path.hasPrefix("~") {
            return nil
        }
        guard (path as NSString).isAbsolutePath else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL.path
    }

    public static func ambientHomeURL(
        env: [String: String],
        fileManager: FileManager = .default)
        -> URL
    {
        if let raw = env["GROK_HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
            return URL(fileURLWithPath: raw, isDirectory: true)
        }
        return fileManager.homeDirectoryForCurrentUser.appendingPathComponent(".grok", isDirectory: true)
    }

    public static func scopedEnvironment(base: [String: String], grokHome: String?) -> [String: String] {
        guard let grokHome, !grokHome.isEmpty else { return base }
        var env = base
        env["GROK_HOME"] = grokHome
        env.removeValue(forKey: GrokSettingsReader.oauthTokenEnvironmentKey)
        return env
    }
}
