import Foundation

public struct KiroUsageSnapshot: Sendable {
    public let planName: String
    public let creditsUsed: Double
    public let creditsTotal: Double
    public let creditsPercent: Double
    public let bonusCreditsUsed: Double?
    public let bonusCreditsTotal: Double?
    public let bonusExpiryDays: Int?
    public let resetsAt: Date?
    public let updatedAt: Date

    public func toUsageSnapshot() -> UsageSnapshot {
        let primary = RateWindow(
            usedPercent: self.creditsPercent,
            windowMinutes: nil,
            resetsAt: self.resetsAt,
            resetDescription: nil)

        var secondary: RateWindow?
        if let bonusUsed = self.bonusCreditsUsed,
           let bonusTotal = self.bonusCreditsTotal,
           bonusTotal > 0
        {
            let bonusPercent = (bonusUsed / bonusTotal) * 100.0
            var expiryDate: Date?
            if let days = self.bonusExpiryDays {
                expiryDate = Calendar.current.date(byAdding: .day, value: days, to: Date())
            }
            secondary = RateWindow(
                usedPercent: bonusPercent,
                windowMinutes: nil,
                resetsAt: expiryDate,
                resetDescription: self.bonusExpiryDays.map { "expires in \($0)d" })
        }

        let identity = ProviderIdentitySnapshot(
            providerID: .kiro,
            accountEmail: nil,
            accountOrganization: self.planName,
            loginMethod: self.planName)

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

public enum KiroStatusProbeError: LocalizedError, Sendable {
    case cliNotFound
    case notLoggedIn
    case cliFailed(String)
    case parseError(String)
    case timeout

    public var errorDescription: String? {
        switch self {
        case .cliNotFound:
            "kiro-cli not found. Install it from https://kiro.dev"
        case .notLoggedIn:
            "Not logged in to Kiro. Run 'kiro-cli login' first."
        case let .cliFailed(message):
            message
        case let .parseError(msg):
            "Failed to parse Kiro usage: \(msg)"
        case .timeout:
            "Kiro CLI timed out."
        }
    }
}

public struct KiroStatusProbe: Sendable {
    public init() {}

    private static let logger = CodexBarLog.logger("kiro")

    public static func detectVersion() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["kiro-cli", "--version"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard let output = String(data: data, encoding: .utf8) else { return nil }
            // Output is like "kiro-cli 1.23.1"
            let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("kiro-cli ") {
                return String(trimmed.dropFirst("kiro-cli ".count))
            }
            return trimmed.isEmpty ? nil : trimmed
        } catch {
            self.logger.debug("kiro-cli version detection failed: \(error.localizedDescription)")
            return nil
        }
    }

    public func fetch() async throws -> KiroUsageSnapshot {
        try await self.ensureLoggedIn()
        let output = try await self.runUsageCommand()
        return try self.parse(output: output)
    }

    private struct KiroCLIResult: Sendable {
        let stdout: String
        let stderr: String
        let terminationStatus: Int32
    }

    private func ensureLoggedIn() async throws {
        let result = try await self.runCommand(arguments: ["whoami"], timeout: 5.0)
        try self.validateWhoAmIOutput(
            stdout: result.stdout,
            stderr: result.stderr,
            terminationStatus: result.terminationStatus)
    }

    func validateWhoAmIOutput(stdout: String, stderr: String, terminationStatus: Int32) throws {
        let trimmedStdout = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedStderr = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        let combined = trimmedStderr.isEmpty ? trimmedStdout : trimmedStderr
        let lowered = combined.lowercased()

        if lowered.contains("not logged in") || lowered.contains("login required") {
            throw KiroStatusProbeError.notLoggedIn
        }

        if terminationStatus != 0 {
            let message = combined.isEmpty
                ? "Kiro CLI failed with status \(terminationStatus)."
                : combined
            throw KiroStatusProbeError.cliFailed(message)
        }

        if combined.isEmpty {
            throw KiroStatusProbeError.cliFailed("Kiro CLI whoami returned no output.")
        }
    }

    private func runUsageCommand() async throws -> String {
        let result = try await self.runCommand(arguments: ["chat", "--no-interactive", "/usage"], timeout: 20.0)
        let trimmedStdout = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedStderr = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        let combinedOutput = trimmedStderr.isEmpty ? trimmedStdout : trimmedStderr
        let combinedStripped = Self.stripANSI(combinedOutput).lowercased()

        if combinedStripped.contains("not logged in")
            || combinedStripped.contains("login required")
            || combinedStripped.contains("failed to initialize auth portal")
            || combinedStripped.contains("kiro-cli login")
            || combinedStripped.contains("oauth error")
        {
            throw KiroStatusProbeError.notLoggedIn
        }

        if !trimmedStdout.isEmpty {
            return result.stdout
        }

        if !trimmedStderr.isEmpty {
            return result.stderr
        }

        if result.terminationStatus != 0 {
            let message = combinedOutput.isEmpty
                ? "Kiro CLI failed with status \(result.terminationStatus)."
                : combinedOutput
            throw KiroStatusProbeError.cliFailed(message)
        }

        return result.stdout
    }

    private func runCommand(
        arguments: [String],
        timeout: TimeInterval,
        idleTimeout: TimeInterval = 5.0
    ) async throws -> KiroCLIResult {
        guard let binary = TTYCommandRunner.which("kiro-cli") else {
            throw KiroStatusProbeError.cliNotFound
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
        env["TERM"] = "xterm-256color"
        process.environment = env

        // Thread-safe state for activity tracking
        final class ActivityState: @unchecked Sendable {
            private let lock = NSLock()
            private var _lastActivityAt = Date()
            private var _hasReceivedOutput = false
            private var _stdoutData = Data()
            private var _stderrData = Data()

            var lastActivityAt: Date {
                lock.lock()
                defer { lock.unlock() }
                return _lastActivityAt
            }

            var hasReceivedOutput: Bool {
                lock.lock()
                defer { lock.unlock() }
                return _hasReceivedOutput
            }

            func appendStdout(_ data: Data) {
                lock.lock()
                defer { lock.unlock() }
                _stdoutData.append(data)
                _lastActivityAt = Date()
                _hasReceivedOutput = true
            }

            func appendStderr(_ data: Data) {
                lock.lock()
                defer { lock.unlock() }
                _stderrData.append(data)
                _lastActivityAt = Date()
                _hasReceivedOutput = true
            }

            func getOutput() -> (stdout: Data, stderr: Data) {
                lock.lock()
                defer { lock.unlock() }
                return (_stdoutData, _stderrData)
            }
        }

        let state = ActivityState()

        // Set up readability handlers to track activity
        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty {
                state.appendStdout(data)
            }
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty {
                state.appendStderr(data)
            }
        }

        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global().async {
                do {
                    try process.run()
                } catch {
                    stdoutPipe.fileHandleForReading.readabilityHandler = nil
                    stderrPipe.fileHandleForReading.readabilityHandler = nil
                    continuation.resume(throwing: error)
                    return
                }

                let deadline = Date().addingTimeInterval(timeout)

                while process.isRunning, Date() < deadline {
                    // Idle timeout: if we got output but then it went silent
                    if state.hasReceivedOutput,
                       Date().timeIntervalSince(state.lastActivityAt) >= idleTimeout
                    {
                        // Process went idle after producing output - likely done or stuck
                        break
                    }
                    Thread.sleep(forTimeInterval: 0.1)
                }

                // Clean up handlers
                stdoutPipe.fileHandleForReading.readabilityHandler = nil
                stderrPipe.fileHandleForReading.readabilityHandler = nil

                if process.isRunning {
                    process.terminate()
                    process.waitUntilExit()
                    // Only throw timeout if we never got output
                    if !state.hasReceivedOutput {
                        continuation.resume(throwing: KiroStatusProbeError.timeout)
                        return
                    }
                }

                // Read any remaining data
                let remainingStdout = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                let remainingStderr = stderrPipe.fileHandleForReading.readDataToEndOfFile()

                var output = state.getOutput()
                output.stdout.append(remainingStdout)
                output.stderr.append(remainingStderr)

                let stdoutOutput = String(data: output.stdout, encoding: .utf8) ?? ""
                let stderrOutput = String(data: output.stderr, encoding: .utf8) ?? ""
                continuation.resume(returning: KiroCLIResult(
                    stdout: stdoutOutput,
                    stderr: stderrOutput,
                    terminationStatus: process.terminationStatus))
            }
        }
    }

    func parse(output: String) throws -> KiroUsageSnapshot {
        let stripped = Self.stripANSI(output)

        let trimmed = stripped.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            throw KiroStatusProbeError.parseError("Empty output from kiro-cli.")
        }

        let lowered = stripped.lowercased()
        if lowered.contains("could not retrieve usage information") {
            throw KiroStatusProbeError.parseError("Kiro CLI could not retrieve usage information.")
        }

        // Check for not logged in
        if lowered.contains("not logged in")
            || lowered.contains("login required")
            || lowered.contains("failed to initialize auth portal")
            || lowered.contains("kiro-cli login")
            || lowered.contains("oauth error")
        {
            throw KiroStatusProbeError.notLoggedIn
        }

        // Track which key patterns matched to detect format changes
        var matchedPlanName = false
        var matchedPercent = false
        var matchedCredits = false

        // Parse plan name from "| KIRO FREE" or similar
        var planName = "Kiro"
        if let planMatch = stripped.range(of: #"\|\s*(KIRO\s+\w+)"#, options: .regularExpression) {
            let raw = String(stripped[planMatch]).replacingOccurrences(of: "|", with: "")
            planName = raw.trimmingCharacters(in: .whitespaces)
            matchedPlanName = true
        }

        // Parse reset date from "resets on 01/01"
        var resetsAt: Date?
        if let resetMatch = stripped.range(of: #"resets on (\d{2}/\d{2})"#, options: .regularExpression) {
            let resetStr = String(stripped[resetMatch])
            if let dateRange = resetStr.range(of: #"\d{2}/\d{2}"#, options: .regularExpression) {
                let dateStr = String(resetStr[dateRange])
                resetsAt = Self.parseResetDate(dateStr)
            }
        }

        // Parse credits percentage from "████...█ X%"
        var creditsPercent: Double = 0
        if let percentMatch = stripped.range(of: #"█+\s*(\d+)%"#, options: .regularExpression) {
            let percentStr = String(stripped[percentMatch])
            if let numMatch = percentStr.range(of: #"\d+"#, options: .regularExpression) {
                creditsPercent = Double(String(percentStr[numMatch])) ?? 0
                matchedPercent = true
            }
        }

        // Parse credits used/total from "(X.XX of Y covered in plan)"
        var creditsUsed: Double = 0
        var creditsTotal: Double = 50 // default free tier
        let creditsPattern = #"\((\d+\.?\d*)\s+of\s+(\d+)\s+covered"#
        if let creditsMatch = stripped.range(of: creditsPattern, options: .regularExpression) {
            let creditsStr = String(stripped[creditsMatch])
            let numbers = creditsStr.matches(of: /(\d+\.?\d*)/)
            if numbers.count >= 2 {
                creditsUsed = Double(String(numbers[0].output.1)) ?? 0
                creditsTotal = Double(String(numbers[1].output.1)) ?? 50
                matchedCredits = true
            }
        }
        if !matchedPercent, matchedCredits, creditsTotal > 0 {
            creditsPercent = (creditsUsed / creditsTotal) * 100.0
        }

        // Parse bonus credits from "Bonus credits: X.XX/Y credits used, expires in Z days"
        var bonusUsed: Double?
        var bonusTotal: Double?
        var bonusExpiryDays: Int?
        if let bonusMatch = stripped.range(of: #"Bonus credits:\s*(\d+\.?\d*)/(\d+)"#, options: .regularExpression) {
            let bonusStr = String(stripped[bonusMatch])
            let numbers = bonusStr.matches(of: /(\d+\.?\d*)/)
            if numbers.count >= 2 {
                bonusUsed = Double(String(numbers[0].output.1))
                bonusTotal = Double(String(numbers[1].output.1))
            }
        }
        if let expiryMatch = stripped.range(of: #"expires in (\d+) days?"#, options: .regularExpression) {
            let expiryStr = String(stripped[expiryMatch])
            if let numMatch = expiryStr.range(of: #"\d+"#, options: .regularExpression) {
                bonusExpiryDays = Int(String(expiryStr[numMatch]))
            }
        }

        // Require at least one key pattern to match to avoid silent failures
        if !matchedPlanName, !matchedPercent, !matchedCredits {
            throw KiroStatusProbeError.parseError(
                "No recognizable usage patterns found. Kiro CLI output format may have changed.")
        }

        return KiroUsageSnapshot(
            planName: planName,
            creditsUsed: creditsUsed,
            creditsTotal: creditsTotal,
            creditsPercent: creditsPercent,
            bonusCreditsUsed: bonusUsed,
            bonusCreditsTotal: bonusTotal,
            bonusExpiryDays: bonusExpiryDays,
            resetsAt: resetsAt,
            updatedAt: Date())
    }

    private static func stripANSI(_ text: String) -> String {
        // Remove ANSI escape sequences
        let pattern = #"\x1B\[[0-9;?]*[A-Za-z]|\x1B\].*?\x07"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return text
        }
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: "")
    }

    private static func parseResetDate(_ dateStr: String) -> Date? {
        // Format: MM/DD - assume current or next year
        let parts = dateStr.split(separator: "/")
        guard parts.count == 2,
              let month = Int(parts[0]),
              let day = Int(parts[1])
        else { return nil }

        let calendar = Calendar.current
        let now = Date()
        let currentYear = calendar.component(.year, from: now)

        var components = DateComponents()
        components.month = month
        components.day = day
        components.year = currentYear

        if let date = calendar.date(from: components), date > now {
            return date
        }

        // If the date is in the past, it's next year
        components.year = currentYear + 1
        return calendar.date(from: components)
    }
}
