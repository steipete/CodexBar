import Foundation

public struct OpenCodeUsageSnapshot: Sendable {
    public let totalCost: Double
    public let avgCostPerDay: Double
    public let totalSessions: Int
    public let totalMessages: Int
    public let days: Int
    public let inputTokens: Int
    public let outputTokens: Int
    public let cacheReadTokens: Int
    public let cacheWriteTokens: Int
    public let updatedAt: Date

    public func toUsageSnapshot() -> UsageSnapshot {
        // Primary: Show cost as a "percentage" where 100% = $100 spent
        // This gives a visual indication of spending
        let costPercent = min(100, (self.totalCost / 100.0) * 100)

        let primary = RateWindow(
            usedPercent: costPercent,
            windowMinutes: nil,
            resetsAt: nil,
            resetDescription: String(format: "$%.2f total", self.totalCost))

        // Secondary: Show average cost per day as a percentage where 100% = $10/day
        let avgPercent = min(100, (self.avgCostPerDay / 10.0) * 100)
        let secondary = RateWindow(
            usedPercent: avgPercent,
            windowMinutes: nil,
            resetsAt: nil,
            resetDescription: String(format: "$%.2f/day", self.avgCostPerDay))

        let identity = ProviderIdentitySnapshot(
            providerID: .opencode,
            accountEmail: nil,
            accountOrganization: "\(self.totalSessions) sessions",
            loginMethod: nil)

        return UsageSnapshot(
            primary: primary,
            secondary: secondary,
            tertiary: nil,
            providerCost: nil,
            zaiUsage: nil,
            updatedAt: self.updatedAt,
            identity: identity)
    }
}

public enum OpenCodeStatusProbeError: LocalizedError, Sendable {
    case cliNotFound
    case cliFailed(String)
    case parseError(String)
    case timeout
    case noData

    public var errorDescription: String? {
        switch self {
        case .cliNotFound:
            "opencode not found. Install it from https://opencode.ai"
        case let .cliFailed(message):
            message
        case let .parseError(msg):
            "Failed to parse OpenCode stats: \(msg)"
        case .timeout:
            "OpenCode CLI timed out."
        case .noData:
            "No usage data available. Run some OpenCode sessions first."
        }
    }
}

public struct OpenCodeStatusProbe: Sendable {
    public init() {}

    private static let logger = CodexBarLog.logger("opencode")

    public static func detectVersion() -> String? {
        guard let binary = Self.findBinary() else { return nil }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = ["--version"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard let output = String(data: data, encoding: .utf8) else { return nil }
            let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        } catch {
            self.logger.debug("opencode version detection failed: \(error.localizedDescription)")
            return nil
        }
    }

    private static func findBinary() -> String? {
        // Check common locations for opencode
        let possiblePaths = [
            "\(NSHomeDirectory())/.opencode/bin/opencode",
            "\(NSHomeDirectory())/.local/share/opencode/bin/opencode",
            "/usr/local/bin/opencode",
            "/opt/homebrew/bin/opencode",
        ]

        for path in possiblePaths {
            if FileManager.default.fileExists(atPath: path) {
                return path
            }
        }

        // Fall back to PATH lookup
        return TTYCommandRunner.which("opencode")
    }

    public func fetch() async throws -> OpenCodeUsageSnapshot {
        let output = try await self.runStatsCommand()
        return try self.parse(output: output)
    }

    private struct OpenCodeCLIResult: Sendable {
        let stdout: String
        let stderr: String
        let terminationStatus: Int32
    }

    private func runStatsCommand() async throws -> String {
        let result = try await self.runCommand(arguments: ["stats"], timeout: 15.0)
        let trimmedStdout = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedStderr = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)

        if result.terminationStatus != 0 {
            let message = trimmedStderr.isEmpty ? trimmedStdout : trimmedStderr
            throw OpenCodeStatusProbeError.cliFailed(
                message.isEmpty ? "OpenCode CLI failed with status \(result.terminationStatus)." : message)
        }

        if trimmedStdout.isEmpty {
            throw OpenCodeStatusProbeError.noData
        }

        return result.stdout
    }

    private func runCommand(arguments: [String], timeout: TimeInterval) async throws -> OpenCodeCLIResult {
        guard let binary = Self.findBinary() else {
            throw OpenCodeStatusProbeError.cliNotFound
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = arguments

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = FileHandle.nullDevice

        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "dumb" // Disable color output for easier parsing
        env["NO_COLOR"] = "1"
        process.environment = env

        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global().async {
                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: error)
                    return
                }

                let deadline = Date().addingTimeInterval(timeout)
                while process.isRunning, Date() < deadline {
                    Thread.sleep(forTimeInterval: 0.1)
                }

                if process.isRunning {
                    process.terminate()
                    process.waitUntilExit()
                    continuation.resume(throwing: OpenCodeStatusProbeError.timeout)
                    return
                }

                let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                let stdoutOutput = String(data: stdoutData, encoding: .utf8) ?? ""
                let stderrOutput = String(data: stderrData, encoding: .utf8) ?? ""
                continuation.resume(returning: OpenCodeCLIResult(
                    stdout: stdoutOutput,
                    stderr: stderrOutput,
                    terminationStatus: process.terminationStatus))
            }
        }
    }

    func parse(output: String) throws -> OpenCodeUsageSnapshot {
        let stripped = Self.stripANSI(output)
        let trimmed = stripped.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmed.isEmpty {
            throw OpenCodeStatusProbeError.parseError("Empty output from opencode stats.")
        }

        var totalCost: Double = 0
        var avgCostPerDay: Double = 0
        var sessions: Int = 0
        var messages: Int = 0
        var days: Int = 0
        var inputTokens: Int = 0
        var outputTokens: Int = 0
        var cacheRead: Int = 0
        var cacheWrite: Int = 0

        // Parse Sessions count
        if let match = stripped.range(of: #"Sessions\s+(\d+)"#, options: .regularExpression) {
            let str = String(stripped[match])
            if let numMatch = str.range(of: #"\d+"#, options: .regularExpression) {
                sessions = Int(String(str[numMatch])) ?? 0
            }
        }

        // Parse Messages count
        if let match = stripped.range(of: #"Messages\s+(\d+)"#, options: .regularExpression) {
            let str = String(stripped[match])
            if let numMatch = str.range(of: #"\d+"#, options: .regularExpression) {
                messages = Int(String(str[numMatch])) ?? 0
            }
        }

        // Parse Days count
        if let match = stripped.range(of: #"Days\s+(\d+)"#, options: .regularExpression) {
            let str = String(stripped[match])
            if let numMatch = str.range(of: #"\d+"#, options: .regularExpression) {
                days = Int(String(str[numMatch])) ?? 0
            }
        }

        // Parse Total Cost: $X.XX
        if let match = stripped.range(of: #"Total Cost\s+\$(\d+\.?\d*)"#, options: .regularExpression) {
            let str = String(stripped[match])
            if let numMatch = str.range(of: #"\d+\.?\d*"#, options: .regularExpression) {
                totalCost = Double(String(str[numMatch])) ?? 0
            }
        }

        // Parse Avg Cost/Day: $X.XX
        if let match = stripped.range(of: #"Avg Cost/Day\s+\$(\d+\.?\d*)"#, options: .regularExpression) {
            let str = String(stripped[match])
            if let numMatch = str.range(of: #"\d+\.?\d*"#, options: .regularExpression) {
                avgCostPerDay = Double(String(str[numMatch])) ?? 0
            }
        }

        // Parse Input tokens (handles K, M suffixes)
        if let match = stripped.range(of: #"Input\s+([\d.]+)([KMB]?)"#, options: .regularExpression) {
            inputTokens = Self.parseTokenCount(String(stripped[match]))
        }

        // Parse Output tokens
        if let match = stripped.range(of: #"Output\s+([\d.]+)([KMB]?)"#, options: .regularExpression) {
            outputTokens = Self.parseTokenCount(String(stripped[match]))
        }

        // Parse Cache Read tokens
        if let match = stripped.range(of: #"Cache Read\s+([\d.]+)([KMB]?)"#, options: .regularExpression) {
            cacheRead = Self.parseTokenCount(String(stripped[match]))
        }

        // Parse Cache Write tokens
        if let match = stripped.range(of: #"Cache Write\s+([\d.]+)([KMB]?)"#, options: .regularExpression) {
            cacheWrite = Self.parseTokenCount(String(stripped[match]))
        }

        // Require at least some data to be parsed
        if sessions == 0, totalCost == 0 {
            throw OpenCodeStatusProbeError.noData
        }

        return OpenCodeUsageSnapshot(
            totalCost: totalCost,
            avgCostPerDay: avgCostPerDay,
            totalSessions: sessions,
            totalMessages: messages,
            days: days,
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            cacheReadTokens: cacheRead,
            cacheWriteTokens: cacheWrite,
            updatedAt: Date())
    }

    private static func parseTokenCount(_ str: String) -> Int {
        // Extract number and optional suffix (K, M, B)
        let pattern = #"([\d.]+)\s*([KMB]?)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []),
              let match = regex.firstMatch(in: str, options: [], range: NSRange(str.startIndex..., in: str))
        else {
            return 0
        }

        guard let numberRange = Range(match.range(at: 1), in: str),
              let number = Double(String(str[numberRange]))
        else {
            return 0
        }

        var multiplier: Double = 1
        if let suffixRange = Range(match.range(at: 2), in: str) {
            let suffix = String(str[suffixRange]).uppercased()
            switch suffix {
            case "K": multiplier = 1_000
            case "M": multiplier = 1_000_000
            case "B": multiplier = 1_000_000_000
            default: break
            }
        }

        return Int(number * multiplier)
    }

    private static func stripANSI(_ text: String) -> String {
        let pattern = #"\x1B\[[0-9;?]*[A-Za-z]|\x1B\].*?\x07|\x1B\[[0-9;]*m"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return text
        }
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: "")
    }
}
