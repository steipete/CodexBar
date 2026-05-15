import Foundation

enum CodexStatusProbeIsolation {
    static func supportDirectory(environment: [String: String]) throws -> URL {
        let baseURL: URL = if let tmp = environment["TMPDIR"]?.trimmingCharacters(in: .whitespacesAndNewlines),
                              !tmp.isEmpty
        {
            URL(fileURLWithPath: tmp, isDirectory: true)
        } else {
            FileManager.default.temporaryDirectory
        }

        let directory = baseURL
            .appendingPathComponent("CodexBar", isDirectory: true)
            .appendingPathComponent("CodexStatusProbe", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    static func workingDirectory(environment: [String: String]) -> URL? {
        let home = environment["HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let home, !home.isEmpty else { return nil }
        return URL(fileURLWithPath: home, isDirectory: true)
    }

    static func codexArguments(stateHome: URL) -> [String] {
        [
            "-s",
            "read-only",
            "-a",
            "untrusted",
            "-c",
            "history.persistence=\"none\"",
            "-c",
            "experimental_thread_store={type=\"in_memory\",id=\"codexbar-status\"}",
            "-c",
            "sqlite_home=\"\(self.tomlEscaped(stateHome.path))\"",
        ]
    }

    private static func tomlEscaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
