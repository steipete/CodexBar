import Foundation

enum ClaudeCLIAuthStatusProbe {
    enum AuthenticationStatus: Equatable {
        case loggedIn
        case loggedOut
        case unavailable
    }

    private struct Response: Decodable {
        let loggedIn: Bool
    }

    @TaskLocal private static var resultOverrideForTesting: Bool?
    @TaskLocal private static var timeoutOverrideForTesting: TimeInterval?

    static func withResultOverrideForTesting<T>(
        _ result: Bool?,
        operation: () async throws -> T) async rethrows -> T
    {
        try await self.$resultOverrideForTesting.withValue(result) {
            try await operation()
        }
    }

    static func withTimeoutOverrideForTesting<T>(
        _ timeout: TimeInterval,
        operation: () async throws -> T) async rethrows -> T
    {
        try await self.$timeoutOverrideForTesting.withValue(timeout) {
            try await operation()
        }
    }

    static func isLoggedIn(
        binary: String,
        environment: [String: String],
        workingDirectory: URL? = nil,
        timeout: TimeInterval = 5) async -> Bool
    {
        await self.authenticationStatus(
            binary: binary,
            environment: environment,
            workingDirectory: workingDirectory,
            timeout: timeout) == .loggedIn
    }

    static func authenticationStatus(
        binary: String,
        environment: [String: String],
        workingDirectory: URL? = nil,
        timeout: TimeInterval = 5) async -> AuthenticationStatus
    {
        if let resultOverrideForTesting = self.resultOverrideForTesting {
            return resultOverrideForTesting ? .loggedIn : .loggedOut
        }
        do {
            let workingDirectory = workingDirectory ?? ClaudeStatusProbe.preparedProbeWorkingDirectoryURL()
            var launchEnvironment = ClaudeCLISession.launchEnvironment(baseEnv: environment)
            launchEnvironment["PWD"] = workingDirectory.path
            let result = try await SubprocessRunner.run(
                binary: binary,
                arguments: ["auth", "status", "--json"],
                environment: launchEnvironment,
                timeout: self.timeoutOverrideForTesting ?? timeout,
                standardInput: FileHandle.nullDevice,
                currentDirectoryURL: workingDirectory,
                acceptsNonZeroExit: true,
                label: "claude-auth-status")
            return self.parseStatus(result.stdout) ?? .unavailable
        } catch {
            return .unavailable
        }
    }

    static func parseLoggedIn(_ output: String) -> Bool {
        self.parseStatus(output) == .loggedIn
    }

    static func parseStatus(_ output: String) -> AuthenticationStatus? {
        guard let data = output.data(using: .utf8),
              let response = try? JSONDecoder().decode(Response.self, from: data)
        else {
            return nil
        }
        return response.loggedIn ? .loggedIn : .loggedOut
    }
}
