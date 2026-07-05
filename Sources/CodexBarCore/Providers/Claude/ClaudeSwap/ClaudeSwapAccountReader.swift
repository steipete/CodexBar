import Foundation

public enum ClaudeSwapAccountReaderError: LocalizedError, Sendable {
    case executablePathNotConfigured
    case outputTooLarge(byteCount: Int)

    public var errorDescription: String? {
        switch self {
        case .executablePathNotConfigured:
            "No claude-swap executable path is configured."
        case let .outputTooLarge(byteCount):
            "claude-swap produced \(byteCount) bytes of output; refusing to parse more than " +
                "\(ClaudeSwapAccountReader.maxOutputBytes)."
        }
    }
}

/// Read-only adapter over the external `claude-swap` executable.
///
/// Executes exactly `cswap --list --json` (never a shell, never config-defined
/// passthrough arguments) with a bounded runtime and bounded output, per the
/// Phase 1 contract in `docs/claude-multi-account-and-status-items.md`. CodexBar
/// never reads claude-swap or Claude Code credential storage; the subprocess is
/// solely responsible for its own credential access.
public enum ClaudeSwapAccountReader {
    public static let maxOutputBytes = 262_144
    public static let defaultTimeout: TimeInterval = 30

    public static func readAccountList(
        executablePath: String,
        timeout: TimeInterval = ClaudeSwapAccountReader.defaultTimeout) async throws -> ClaudeSwapAccountList
    {
        // Handled claude-swap failures print a schema-v1 error envelope to stdout
        // and exit non-zero, so non-zero exits still parse; the parser surfaces
        // the envelope as `ClaudeSwapListParserError.reportedError`.
        let result = try await self.run(
            executablePath: executablePath,
            arguments: ["--list", "--json"],
            timeout: timeout,
            acceptsNonZeroExit: true,
            label: "claude-swap list")
        return try ClaudeSwapListParser.parse(Data(result.utf8))
    }

    /// Best-effort version probe (`cswap --version` prints `cswap <version>`).
    public static func readVersion(
        executablePath: String,
        timeout: TimeInterval = 10) async -> String?
    {
        guard let output = try? await self.run(
            executablePath: executablePath,
            arguments: ["--version"],
            timeout: timeout,
            label: "claude-swap version")
        else {
            return nil
        }
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let version = trimmed.split(whereSeparator: \.isWhitespace).last, !version.isEmpty else {
            return nil
        }
        return String(version)
    }

    public static func resolvedExecutablePath(_ configuredPath: String) throws -> String {
        let trimmed = configuredPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ClaudeSwapAccountReaderError.executablePathNotConfigured
        }
        return (trimmed as NSString).expandingTildeInPath
    }

    private static func run(
        executablePath: String,
        arguments: [String],
        timeout: TimeInterval,
        acceptsNonZeroExit: Bool = false,
        label: String) async throws -> String
    {
        let binary = try self.resolvedExecutablePath(executablePath)
        let result = try await SubprocessRunner.run(
            binary: binary,
            arguments: arguments,
            environment: ProcessInfo.processInfo.environment,
            timeout: timeout,
            acceptsNonZeroExit: acceptsNonZeroExit,
            label: label)
        guard result.stdout.utf8.count <= self.maxOutputBytes else {
            throw ClaudeSwapAccountReaderError.outputTooLarge(byteCount: result.stdout.utf8.count)
        }
        return result.stdout
    }
}
