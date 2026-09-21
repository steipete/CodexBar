import Foundation

struct GitKrakenCLIProbe: Sendable {
    /// The injectable runner lets tests verify arguments and isolation without reading real credentials.
    typealias Runner = @Sendable (String, [String], [String: String]) async throws -> String
    private let runner: Runner

    init(runner: @escaping Runner = Self.run) {
        self.runner = runner
    }

    static func version(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        loginPATH: [String]? = LoginShellPathCache.shared.current) -> String?
    {
        guard let executable = self.executable(environment: environment, loginPATH: loginPATH),
              let output = ProviderVersionDetector.run(
                  path: executable,
                  args: ["version", "--json"],
                  environment: environment)
        else { return nil }
        return self.parseVersionOutput(output)
    }

    static func parseVersionOutput(_ output: String) -> String? {
        struct VersionPayload: Decodable {
            let version: String
        }

        guard let data = output.data(using: .utf8),
              let payload = try? JSONDecoder().decode(VersionPayload.self, from: data)
        else { return nil }
        let version = payload.version.trimmingCharacters(in: .whitespacesAndNewlines)
        return version.isEmpty ? nil : version
    }

    static func executable(environment: [String: String], loginPATH: [String]?) -> String? {
        let home = NSHomeDirectory()
        // Never resolve shell aliases: `gk` is commonly an alias for gitk, not GitKraken CLI.
        // Availability checks also must not launch an interactive login shell.
        return BinaryLocator.resolveBinary(
            name: "gk",
            overrideKey: "GITKRAKEN_CLI_PATH",
            env: environment,
            loginPATH: loginPATH,
            commandV: { _, _, _, _ in nil },
            aliasResolver: { _, _, _, _, _ in nil },
            wellKnownPaths: ["\(home)/.local/bin/gk", "/opt/homebrew/bin/gk", "/usr/local/bin/gk"],
            fileManager: .default,
            home: home)
    }

    func fetch(executable: String, environment: [String: String]) async throws -> GitKrakenUsage {
        try Task.checkCancellation()
        var commandEnvironment = environment
        commandEnvironment["NO_COLOR"] = "1"
        commandEnvironment["LANG"] = "C"
        commandEnvironment["LC_ALL"] = "C"
        commandEnvironment.removeValue(forKey: "GK_OUTPUT")
        // API credentials and API organization selection must never overwrite the CLI's own login/scope.
        commandEnvironment.removeValue(forKey: GitKrakenSettingsReader.tokenKey)
        commandEnvironment.removeValue(forKey: GitKrakenSettingsReader.organizationKey)
        let output: String
        do {
            output = try await self.runner(executable, ["ai", "tokens"], commandEnvironment)
        } catch SubprocessRunnerError.nonZeroExit {
            throw GitKrakenUsageError.cliFailed
        }
        try Task.checkCancellation()
        return try GitKrakenUsage.parseCLI(output)
    }

    private static func run(
        executable: String,
        arguments: [String],
        environment: [String: String]) async throws -> String
    {
        let result = try await SubprocessRunner.run(
            binary: executable,
            arguments: arguments,
            environment: environment,
            timeout: 15,
            maxOutputBytes: 65536,
            standardInput: FileHandle.nullDevice,
            label: "gitkraken-usage")
        // stderr is diagnostic output, not a second source of successful usage data.
        return result.stdout
    }
}
