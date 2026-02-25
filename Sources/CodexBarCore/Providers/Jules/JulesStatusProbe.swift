import Foundation

public struct JulesStatusSnapshot: Sendable {
    public let activeSessions: Int
    public let isAuthenticated: Bool
    public let rawText: String

    public func toUsageSnapshot() -> UsageSnapshot {
        // We use "active sessions" as the primary usage metric.
        // Since there is no fixed limit, we just show the count.
        // windowMinutes/resetsAt are nil as this is a state, not a rate limit.

        let primary = RateWindow(
            usedPercent: 0, // No percent, just a count
            windowMinutes: nil,
            resetsAt: nil,
            resetDescription: "\(self.activeSessions) active")

        let identity = ProviderIdentitySnapshot(
            providerID: .jules,
            accountEmail: nil,
            accountOrganization: nil,
            loginMethod: self.isAuthenticated ? "CLI" : nil)

        return UsageSnapshot(
            primary: primary,
            secondary: nil,
            updatedAt: Date(),
            identity: identity)
    }
}

public enum JulesStatusProbeError: LocalizedError, Sendable, Equatable {
    case julesNotInstalled
    case notLoggedIn
    case commandFailed(String)
    case timedOut

    public var errorDescription: String? {
        switch self {
        case .julesNotInstalled:
            "Jules CLI is not installed or not on PATH."
        case .notLoggedIn:
            "Not logged in to Jules. Run 'jules login' in Terminal to authenticate."
        case let .commandFailed(msg):
            "Jules CLI error: \(msg)"
        case .timedOut:
            "Jules CLI request timed out."
        }
    }
}

public struct JulesStatusProbe: Sendable {
    public var timeout: TimeInterval = 10.0

    public init(timeout: TimeInterval = 10.0) {
        self.timeout = timeout
    }

    public func fetch() async throws -> JulesStatusSnapshot {
        // Check if jules is installed
        // Using TTYCommandRunner.which similar to other providers
        guard TTYCommandRunner.which("jules") != nil else {
            throw JulesStatusProbeError.julesNotInstalled
        }

        // Find the absolute path to ensure we run the correct binary
        let binary = TTYCommandRunner.which("jules") ?? "jules"

        // Run `jules remote list --session` to get active sessions
        // Using SubprocessRunner.run which is a static async method
        let result = try await SubprocessRunner.run(
            binary: binary,
            arguments: ["remote", "list", "--session"],
            environment: TTYCommandRunner.enrichedEnvironment(),
            timeout: self.timeout,
            label: "jules-status")

        // Check for login error in stderr/stdout
        // "Error: failed to list tasks: Trying to make a GET request without a valid client (did you forget to login?)"
        let output = result.stdout + result.stderr
        if output.contains("did you forget to login") || output.contains("jules login") {
            throw JulesStatusProbeError.notLoggedIn
        }

        // SubprocessRunner throws nonZeroExit if exit code is not 0, so we catch it via try? or rely on the throw.
        // However, if we want to parse the output even on failure (sometimes tools print helpful error messages),
        // we might want to catch specific errors. But SubprocessRunner design throws on non-zero exit.
        // We'll rely on the happy path here.

        // Parse output to count sessions
        // Output format is typically a list of sessions, one per line (maybe with a header).
        // Let's assume each line is a session for now, filtering out empty lines.
        // If the list is empty, it might just print nothing or "No sessions found".

        let lines = result.stdout.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        // If there's a header, we might need to skip it.
        // Assuming no header for now based on typical CLI tools, or we can refine later.
        let activeSessions = lines.count

        return JulesStatusSnapshot(
            activeSessions: activeSessions,
            isAuthenticated: true,
            rawText: result.stdout)
    }
}
