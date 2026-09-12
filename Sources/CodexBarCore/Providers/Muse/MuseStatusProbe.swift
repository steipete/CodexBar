import Foundation

public enum MuseStatusProbe {
    public struct ProbeResult: Sendable {
        public let isInstalled: Bool
        public let executablePath: String?
        public let hasConfig: Bool
        public let hasSessions: Bool
        public let apiKeyPresent: Bool
    }

    /// Cheap filesystem-only probe. Safe to call from the main actor; never spawns the Muse CLI.
    public static func probe(
        environment: [String: String] = ProcessInfo.processInfo.environment) -> ProbeResult
    {
        let apiKey = MuseSettingsReader.apiKey(environment: environment)
        let config = MuseSettingsReader.readSettingsJSON(environment: environment)
        let sessionRoots = MuseSettingsReader.defaultSessionRoots(environment: environment)
        let hasSessions = sessionRoots.contains { root in
            (try? FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty) == false
        }
        let executablePath = self.locateExecutable(environment: environment)

        return ProbeResult(
            isInstalled: executablePath != nil,
            executablePath: executablePath,
            hasConfig: config != nil,
            hasSessions: hasSessions,
            apiKeyPresent: apiKey != nil)
    }

    /// Resolves the Muse CLI binary from well-known install locations, then PATH.
    public static func locateExecutable(
        environment: [String: String] = ProcessInfo.processInfo.environment) -> String?
    {
        let fileManager = FileManager.default
        let home = fileManager.homeDirectoryForCurrentUser.path
        let standardPaths = [
            "\(home)/.local/bin/muse",
            "/opt/homebrew/bin/muse",
            "/usr/local/bin/muse",
            "\(home)/.cargo/bin/muse",
        ]
        for path in standardPaths where fileManager.isExecutableFile(atPath: path) {
            return path
        }
        if let pathVar = environment["PATH"] {
            for dir in pathVar.split(separator: ":") {
                let candidate = URL(fileURLWithPath: String(dir)).appendingPathComponent("muse").path
                if fileManager.isExecutableFile(atPath: candidate) {
                    return candidate
                }
            }
        }
        return nil
    }

    /// Runs `muse --version`. Only used by the descriptor version detector, which the host runs off the main actor.
    public static func detectCLIVersion(
        environment: [String: String] = ProcessInfo.processInfo.environment) -> String?
    {
        guard let path = self.locateExecutable(environment: environment)
            ?? TTYCommandRunner.which("muse")
        else { return nil }
        guard let output = ProviderVersionDetector.run(path: path, args: ["--version"], mergeStandardError: true)
        else { return nil }
        // Output is like "Muse Code 1.1.1 (1.1.1-R2514.1)"
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = "Muse Code "
        if trimmed.hasPrefix(prefix) {
            return String(trimmed.dropFirst(prefix.count))
        }
        return trimmed.isEmpty ? nil : trimmed
    }
}
