import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Credits/usage information from the Grok Build CLI (shown via /usage show inside the agent).
public struct GrokCreditsSnapshot: Sendable, Equatable {
    public let creditsUsedPercent: Double?
    public let resetsAt: Date?
    public let resetDescription: String?
    public let payAsYouGoEnabled: Bool

    public init(
        creditsUsedPercent: Double?,
        resetsAt: Date?,
        resetDescription: String?,
        payAsYouGoEnabled: Bool
    ) {
        self.creditsUsedPercent = creditsUsedPercent
        self.resetsAt = resetsAt
        self.resetDescription = resetDescription
        self.payAsYouGoEnabled = payAsYouGoEnabled
    }
}

public enum GrokCreditsProbeError: LocalizedError, Sendable {
    case binaryNotFound
    case commandFailed(String)
    case parseFailed(String)

    public var errorDescription: String? {
        switch self {
        case .binaryNotFound: "Grok CLI binary not found."
        case let .commandFailed(msg): "Failed to query Grok usage: \(msg)"
        case let .parseFailed(msg): "Could not parse Grok usage output: \(msg)"
        }
    }
}

/// Probes the official Grok Build CLI for the current credits/usage state
/// (the same data you see when typing `/usage show` inside a grok session).
public enum GrokCreditsProbe {
    private static let log = CodexBarLog.logger(LogCategories.providers)

    /// Locations where the Grok CLI binary is commonly installed.
    private static let grokBinaryCandidates: [String] = [
        "\(FileManager.default.homeDirectoryForCurrentUser.path)/.grok/bin/grok",
        "/usr/local/bin/grok",
        "/opt/homebrew/bin/grok",
    ]

    public static func fetch() async throws -> GrokCreditsSnapshot {
        let binary = try await resolveGrokBinary()

        // Try several command variations based on the actual `grok --help` output.
        // The reliable way is `-p` / `--single` + `--output-format`.
        let commandVariants: [[String]] = [
            ["-p", "/usage show", "--output-format", "plain"],
            ["--single", "/usage show", "--output-format", "plain"],
            ["-p", "/usage show"],
            ["--single", "/usage show"],
        ]

        var lastError: Error?
        for args in commandVariants {
            do {
                let output = try await runGrok(binary: binary, arguments: args, timeout: 20)
                let snapshot = try parseUsageOutput(output)
                if snapshot.creditsUsedPercent != nil || snapshot.resetsAt != nil {
                    return snapshot
                }
            } catch {
                lastError = error
                // try next variant
            }
        }

        if let error = lastError {
            throw error
        }
        throw GrokCreditsProbeError.commandFailed("Could not retrieve usage from Grok CLI")
    }

    private static func resolveGrokBinary() async throws -> String {
        for path in grokBinaryCandidates {
            if FileManager.default.fileExists(atPath: path) {
                return path
            }
        }

        // Fallback to PATH
        if let path = TTYCommandRunner.which("grok") {
            return path
        }

        throw GrokCreditsProbeError.binaryNotFound
    }

    private static func runGrok(
        binary: String,
        arguments: [String],
        timeout: TimeInterval
    ) async throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = arguments

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
        } catch {
            throw GrokCreditsProbeError.commandFailed("Could not launch grok binary: \(error.localizedDescription)")
        }

        // Wait with timeout
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline {
            try await Task.sleep(nanoseconds: 100_000_000) // 100ms
        }

        if process.isRunning {
            process.terminate()
            throw GrokCreditsProbeError.commandFailed("Grok CLI timed out while fetching usage")
        }

        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        let text = String(data: data, encoding: .utf8) ?? ""

        if process.terminationStatus != 0 {
            let errData = stderr.fileHandleForReading.readDataToEndOfFile()
            let errText = String(data: errData, encoding: .utf8) ?? ""
            log.warning("grok usage command exited with code \(process.terminationStatus): \(errText)")
        }

        return text
    }

    private static func parseUsageOutput(_ output: String) throws -> GrokCreditsSnapshot {
        var creditsPercent: Double?
        var resetsAt: Date?
        var resetDescription: String?
        var payAsYouGo = false

        let lines = output.components(separatedBy: .newlines)

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

            // "Credits used: 4%"
            if trimmed.contains("credits used:") {
                if let percentPart = trimmed.components(separatedBy: "credits used:").last,
                   let numberStr = percentPart.components(separatedBy: "%").first?.trimmingCharacters(in: .whitespaces),
                   let value = Double(numberStr) {
                    creditsPercent = value
                }
            }

            // "Resets: May 31, 16:00 PT"
            if trimmed.hasPrefix("resets:") {
                let rest = line.trimmingCharacters(in: .whitespacesAndNewlines)
                    .dropFirst("resets:".count)
                    .trimmingCharacters(in: .whitespaces)
                resetDescription = rest

                // Try to parse a date (very loose parser)
                let formatter = DateFormatter()
                formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.timeZone = TimeZone(identifier: "America/Los_Angeles")

                for format in ["MMM d, h:mm a", "MMMM d, h:mm a zzz", "yyyy-MM-dd HH:mm"] {
                    formatter.dateFormat = format
                    if let date = formatter.date(from: rest) {
                        var candidate = date
                        if candidate < Date() {
                            candidate = Calendar.current.date(byAdding: .day, value: 30, to: candidate) ?? date
                        }
                        resetsAt = candidate
                        break
                    }
                }
            }

            if trimmed.contains("pay as you go") {
                payAsYouGo = !trimmed.contains("disabled")
            }
        }

        return GrokCreditsSnapshot(
            creditsUsedPercent: creditsPercent,
            resetsAt: resetsAt,
            resetDescription: resetDescription,
            payAsYouGoEnabled: payAsYouGo
        )
    }
}
