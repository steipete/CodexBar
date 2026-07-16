import Foundation

enum ClaudeCLIAuthStatusProbe {
    private struct Response: Decodable {
        let loggedIn: Bool
    }

    @TaskLocal private static var resultOverrideForTesting: Bool?

    static func withResultOverrideForTesting<T>(
        _ result: Bool?,
        operation: () async throws -> T) async rethrows -> T
    {
        try await self.$resultOverrideForTesting.withValue(result) {
            try await operation()
        }
    }

    static func isLoggedIn(
        binary: String,
        environment: [String: String],
        timeout: TimeInterval = 5) async -> Bool
    {
        if let resultOverrideForTesting = self.resultOverrideForTesting {
            return resultOverrideForTesting
        }
        do {
            let result = try await SubprocessRunner.run(
                binary: binary,
                arguments: ["auth", "status", "--json"],
                environment: ClaudeCLISession.launchEnvironment(baseEnv: environment),
                timeout: timeout,
                standardInput: FileHandle.nullDevice,
                label: "claude-auth-status")
            return self.parseLoggedIn(result.stdout)
        } catch {
            return false
        }
    }

    static func parseLoggedIn(_ output: String) -> Bool {
        guard let data = output.data(using: .utf8),
              let response = try? JSONDecoder().decode(Response.self, from: data)
        else {
            return false
        }
        return response.loggedIn
    }
}
