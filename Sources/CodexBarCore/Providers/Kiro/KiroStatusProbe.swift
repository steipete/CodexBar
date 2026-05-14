import Foundation

public struct KiroUsageSnapshot: Sendable {
    public let planName: String
    public let displayPlanName: String
    public let accountEmail: String?
    public let authMethod: String?
    public let creditsUsed: Double
    public let creditsTotal: Double
    public let creditsPercent: Double
    public let bonusCreditsUsed: Double?
    public let bonusCreditsTotal: Double?
    public let bonusExpiryDays: Int?
    public let overagesStatus: String?
    public let manageURL: String?
    public let contextUsage: KiroContextUsageSnapshot?
    public let resetsAt: Date?
    public let updatedAt: Date

    public init(
        planName: String,
        displayPlanName: String? = nil,
        accountEmail: String? = nil,
        authMethod: String? = nil,
        creditsUsed: Double,
        creditsTotal: Double,
        creditsPercent: Double,
        bonusCreditsUsed: Double?,
        bonusCreditsTotal: Double?,
        bonusExpiryDays: Int?,
        overagesStatus: String? = nil,
        manageURL: String? = nil,
        contextUsage: KiroContextUsageSnapshot? = nil,
        resetsAt: Date?,
        updatedAt: Date)
    {
        self.planName = planName
        self.displayPlanName = displayPlanName ?? KiroStatusProbe.displayPlanName(planName)
        self.accountEmail = accountEmail
        self.authMethod = authMethod
        self.creditsUsed = creditsUsed
        self.creditsTotal = creditsTotal
        self.creditsPercent = creditsPercent
        self.bonusCreditsUsed = bonusCreditsUsed
        self.bonusCreditsTotal = bonusCreditsTotal
        self.bonusExpiryDays = bonusExpiryDays
        self.overagesStatus = overagesStatus
        self.manageURL = manageURL
        self.contextUsage = contextUsage
        self.resetsAt = resetsAt
        self.updatedAt = updatedAt
    }

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
            accountEmail: self.accountEmail,
            accountOrganization: nil,
            loginMethod: self.authMethod)

        let kiroUsage = KiroUsageDetails(
            planName: self.planName,
            displayPlanName: self.displayPlanName,
            creditsUsed: self.creditsUsed,
            creditsTotal: self.creditsTotal,
            creditsRemaining: self.creditsRemaining,
            bonusCreditsUsed: self.bonusCreditsUsed,
            bonusCreditsTotal: self.bonusCreditsTotal,
            bonusCreditsRemaining: self.bonusCreditsRemaining,
            bonusExpiryDays: self.bonusExpiryDays,
            overagesStatus: self.overagesStatus,
            manageURL: self.manageURL,
            contextUsage: self.contextUsage)

        return UsageSnapshot(
            primary: primary,
            secondary: secondary,
            tertiary: nil,
            kiroUsage: kiroUsage,
            providerCost: nil,
            zaiUsage: nil,
            updatedAt: self.updatedAt,
            identity: identity)
    }

    public var creditsRemaining: Double {
        max(0, self.creditsTotal - self.creditsUsed)
    }

    public var bonusCreditsRemaining: Double? {
        guard let bonusCreditsUsed, let bonusCreditsTotal else { return nil }
        return max(0, bonusCreditsTotal - bonusCreditsUsed)
    }
}

public struct KiroContextUsageSnapshot: Codable, Equatable, Sendable {
    public let totalPercentUsed: Double
    public let contextFilesPercent: Double?
    public let toolsPercent: Double?
    public let kiroResponsesPercent: Double?
    public let promptsPercent: Double?

    public init(
        totalPercentUsed: Double,
        contextFilesPercent: Double?,
        toolsPercent: Double?,
        kiroResponsesPercent: Double?,
        promptsPercent: Double?)
    {
        self.totalPercentUsed = totalPercentUsed
        self.contextFilesPercent = contextFilesPercent
        self.toolsPercent = toolsPercent
        self.kiroResponsesPercent = kiroResponsesPercent
        self.promptsPercent = promptsPercent
    }
}

public struct KiroUsageDetails: Codable, Equatable, Sendable {
    public let planName: String
    public let displayPlanName: String
    public let creditsUsed: Double
    public let creditsTotal: Double
    public let creditsRemaining: Double
    public let bonusCreditsUsed: Double?
    public let bonusCreditsTotal: Double?
    public let bonusCreditsRemaining: Double?
    public let bonusExpiryDays: Int?
    public let overagesStatus: String?
    public let manageURL: String?
    public let contextUsage: KiroContextUsageSnapshot?

    public init(
        planName: String,
        displayPlanName: String,
        creditsUsed: Double,
        creditsTotal: Double,
        creditsRemaining: Double,
        bonusCreditsUsed: Double?,
        bonusCreditsTotal: Double?,
        bonusCreditsRemaining: Double?,
        bonusExpiryDays: Int?,
        overagesStatus: String?,
        manageURL: String?,
        contextUsage: KiroContextUsageSnapshot?)
    {
        self.planName = planName
        self.displayPlanName = displayPlanName
        self.creditsUsed = creditsUsed
        self.creditsTotal = creditsTotal
        self.creditsRemaining = creditsRemaining
        self.bonusCreditsUsed = bonusCreditsUsed
        self.bonusCreditsTotal = bonusCreditsTotal
        self.bonusCreditsRemaining = bonusCreditsRemaining
        self.bonusExpiryDays = bonusExpiryDays
        self.overagesStatus = overagesStatus
        self.manageURL = manageURL
        self.contextUsage = contextUsage
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

    private static let logger = CodexBarLog.logger(LogCategories.kiro)

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
        let account = try await self.ensureLoggedIn()
        let output = try await self.runUsageCommand()
        var contextUsage: KiroContextUsageSnapshot?
        do {
            contextUsage = try await self.fetchContextUsage()
        } catch {
            Self.logger.debug("Kiro context usage probe failed: \(error.localizedDescription)")
        }
        return try self.parse(
            output: output,
            accountEmail: account.email,
            authMethod: account.authMethod,
            contextUsage: contextUsage)
    }

    private struct KiroCLIResult {
        let stdout: String
        let stderr: String
        let terminationStatus: Int32
        let terminatedForIdle: Bool
    }

    struct KiroAccountInfo: Equatable {
        let authMethod: String?
        let email: String?
    }

    private func ensureLoggedIn() async throws -> KiroAccountInfo {
        let result = try await self.runCommand(arguments: ["whoami"], timeout: 5.0)
        return try self.validateWhoAmIOutput(
            stdout: result.stdout,
            stderr: result.stderr,
            terminationStatus: result.terminationStatus)
    }

    func validateWhoAmIOutput(stdout: String, stderr: String, terminationStatus: Int32) throws -> KiroAccountInfo {
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

        return self.parseWhoAmIOutput(combined)
    }

    func parseWhoAmIOutput(_ output: String) -> KiroAccountInfo {
        let stripped = Self.stripANSI(output)
        var authMethod: String?
        var email: String?
        for rawLine in stripped.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            if line.localizedCaseInsensitiveContains("logged in with") {
                authMethod = line.replacingOccurrences(
                    of: #"(?i)^\s*logged in with\s+"#,
                    with: "",
                    options: [.regularExpression])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            } else if line.localizedCaseInsensitiveContains("email:") {
                email = line.replacingOccurrences(
                    of: #"(?i)^\s*email:\s*"#,
                    with: "",
                    options: [.regularExpression])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            } else if email == nil,
                      !line.contains(" "),
                      line.contains("@")
            {
                email = line
            }
        }
        return KiroAccountInfo(
            authMethod: authMethod?.nilIfEmpty,
            email: email?.nilIfEmpty)
    }

    private func runUsageCommand() async throws -> String {
        let result = try await self.runCommand(
            arguments: ["chat", "--no-interactive", "/usage"],
            timeout: 20.0,
            idleTimeout: 10.0)
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

        if result.terminatedForIdle, !Self.isUsageOutputComplete(combinedOutput) {
            throw KiroStatusProbeError.timeout
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

    private func fetchContextUsage() async throws -> KiroContextUsageSnapshot? {
        let result = try await self.runCommand(
            arguments: ["chat", "--no-interactive", "/context"],
            timeout: 8.0,
            idleTimeout: 3.0)
        let output = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? result.stderr
            : result.stdout
        return self.parseContextUsage(output: output)
    }

    private func runCommand(
        arguments: [String],
        timeout: TimeInterval,
        idleTimeout: TimeInterval = 5.0) async throws -> KiroCLIResult
    {
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
                self.lock.lock()
                defer { lock.unlock() }
                return self._lastActivityAt
            }

            var hasReceivedOutput: Bool {
                self.lock.lock()
                defer { lock.unlock() }
                return self._hasReceivedOutput
            }

            func appendStdout(_ data: Data) {
                self.lock.lock()
                defer { lock.unlock() }
                self._stdoutData.append(data)
                self._lastActivityAt = Date()
                self._hasReceivedOutput = true
            }

            func appendStderr(_ data: Data) {
                self.lock.lock()
                defer { lock.unlock() }
                self._stderrData.append(data)
                self._lastActivityAt = Date()
                self._hasReceivedOutput = true
            }

            func getOutput() -> (stdout: Data, stderr: Data) {
                self.lock.lock()
                defer { lock.unlock() }
                return (self._stdoutData, self._stderrData)
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
                var didHitDeadline = false
                var didTerminateForIdle = false

                while process.isRunning {
                    if Date() >= deadline {
                        didHitDeadline = true
                        break
                    }
                    // Idle timeout: if we got output but then it went silent
                    if state.hasReceivedOutput,
                       Date().timeIntervalSince(state.lastActivityAt) >= idleTimeout
                    {
                        // Process went idle after producing output - likely done or stuck
                        didTerminateForIdle = true
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
                    if didHitDeadline || !state.hasReceivedOutput {
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
                    terminationStatus: process.terminationStatus,
                    terminatedForIdle: didTerminateForIdle))
            }
        }
    }

    func parse(
        output: String,
        accountEmail: String? = nil,
        authMethod: String? = nil,
        contextUsage: KiroContextUsageSnapshot? = nil) throws -> KiroUsageSnapshot
    {
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
        var matchedPercent = false
        var matchedCredits = false
        var matchedNewFormat = false

        let parsedPlan = Self.parsePlanName(from: stripped)
        let planName = parsedPlan.name
        matchedNewFormat = parsedPlan.matchedNewFormat

        // Check if this is a managed plan with no usage data
        let isManagedPlan = lowered.contains("managed by admin")
            || lowered.contains("managed by organization")

        let resetsAt = Self.parseResetDate(in: stripped)

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

        let bonusCredits = Self.parseBonusCredits(in: stripped)

        let overagesStatus = Self.firstCapture(
            in: stripped,
            pattern: #"(?i)Overages:\s*([^\n]+)"#)
            .map(Self.cleanInlineValue)
            .flatMap(\.nilIfEmpty)
        let manageURL = Self.firstCapture(
            in: stripped,
            pattern: #"https://app\.kiro\.dev/account/usage"#)

        // Managed plans in new format may omit usage metrics. Only fall back to zeros when
        // we did not parse any usage values, so we do not mask real metrics.
        if matchedNewFormat, isManagedPlan, !matchedPercent, !matchedCredits {
            // Managed plans don't expose credits; return snapshot with plan name only
            return KiroUsageSnapshot(
                planName: planName,
                displayPlanName: Self.displayPlanName(planName),
                accountEmail: accountEmail?.nilIfEmpty,
                authMethod: authMethod?.nilIfEmpty,
                creditsUsed: 0,
                creditsTotal: 0,
                creditsPercent: 0,
                bonusCreditsUsed: bonusCredits.used,
                bonusCreditsTotal: bonusCredits.total,
                bonusExpiryDays: bonusCredits.expiryDays,
                overagesStatus: overagesStatus,
                manageURL: manageURL,
                contextUsage: contextUsage,
                resetsAt: nil,
                updatedAt: Date())
        }

        // Require at least one key pattern to match to avoid silent failures.
        // Managed plans without usage data return early above.
        if !matchedPercent, !matchedCredits {
            throw KiroStatusProbeError.parseError(
                "No recognizable usage patterns found. Kiro CLI output format may have changed.")
        }

        return KiroUsageSnapshot(
            planName: planName,
            displayPlanName: Self.displayPlanName(planName),
            accountEmail: accountEmail?.nilIfEmpty,
            authMethod: authMethod?.nilIfEmpty,
            creditsUsed: creditsUsed,
            creditsTotal: creditsTotal,
            creditsPercent: creditsPercent,
            bonusCreditsUsed: bonusCredits.used,
            bonusCreditsTotal: bonusCredits.total,
            bonusExpiryDays: bonusCredits.expiryDays,
            overagesStatus: overagesStatus,
            manageURL: manageURL,
            contextUsage: contextUsage,
            resetsAt: resetsAt,
            updatedAt: Date())
    }

    func parseContextUsage(output: String) -> KiroContextUsageSnapshot? {
        let stripped = Self.stripANSI(output)
        guard let total = Self.firstCapture(
            in: stripped,
            pattern: #"(?i)Context window:\s*(\d+\.?\d*)%\s+used"#)
            .flatMap(Double.init)
        else {
            return nil
        }
        return KiroContextUsageSnapshot(
            totalPercentUsed: total,
            contextFilesPercent: Self.percent(after: "Context files", in: stripped),
            toolsPercent: Self.percent(after: "Tools", in: stripped),
            kiroResponsesPercent: Self.percent(after: "Kiro responses", in: stripped),
            promptsPercent: Self.percent(after: "Your prompts", in: stripped))
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

    private static func parsePlanName(from text: String) -> (name: String, matchedNewFormat: Bool) {
        var planName = "Kiro"
        var matchedNewFormat = false

        // Parse plan name from "| KIRO FREE" or similar (legacy format)
        if let planMatch = text.range(of: #"\|\s*(KIRO\s+\w+)"#, options: .regularExpression) {
            let raw = String(text[planMatch]).replacingOccurrences(of: "|", with: "")
            planName = raw.trimmingCharacters(in: .whitespaces)
        }

        // Parse plan name from "Estimated Usage | resets on 2026-06-01 | KIRO FREE" (kiro-cli 2.x)
        if let estimatedMatch = text.range(
            of: #"Estimated Usage\s*\|[^\n|]*\|\s*([A-Z][A-Z0-9 ]+)"#,
            options: .regularExpression)
        {
            let line = String(text[estimatedMatch])
            if let plan = line.split(separator: "|").last?.trimmingCharacters(in: .whitespacesAndNewlines),
               !plan.isEmpty
            {
                planName = plan
            }
        }

        // Parse plan name from "Plan: Q Developer Pro" (new format, kiro-cli 1.24+)
        if let newPlanMatch = text.range(of: #"Plan:\s*(.+)"#, options: .regularExpression) {
            let line = String(text[newPlanMatch])
            let planLine = line.replacingOccurrences(of: "Plan:", with: "").trimmingCharacters(in: .whitespaces)
            if let firstLine = planLine.split(separator: "\n").first {
                planName = String(firstLine).trimmingCharacters(in: .whitespaces)
                matchedNewFormat = true
            }
        }

        return (planName, matchedNewFormat)
    }

    private static func parseResetDate(in text: String) -> Date? {
        guard let resetMatch = text.range(
            of: #"resets on (\d{4}-\d{2}-\d{2}|\d{2}/\d{2})"#,
            options: .regularExpression)
        else { return nil }

        let resetStr = String(text[resetMatch])
        guard let dateRange = resetStr.range(
            of: #"\d{4}-\d{2}-\d{2}|\d{2}/\d{2}"#,
            options: .regularExpression)
        else { return nil }

        return Self.parseResetDate(String(resetStr[dateRange]))
    }

    private static func parseBonusCredits(in text: String) -> (used: Double?, total: Double?, expiryDays: Int?) {
        var used: Double?
        var total: Double?
        var expiryDays: Int?
        if let bonusMatch = text.range(of: #"Bonus credits:\s*(\d+\.?\d*)/(\d+)"#, options: .regularExpression) {
            let bonusStr = String(text[bonusMatch])
            let numbers = bonusStr.matches(of: /(\d+\.?\d*)/)
            if numbers.count >= 2 {
                used = Double(String(numbers[0].output.1))
                total = Double(String(numbers[1].output.1))
            }
        }
        if let expiryMatch = text.range(of: #"expires in (\d+) days?"#, options: .regularExpression) {
            let expiryStr = String(text[expiryMatch])
            if let numMatch = expiryStr.range(of: #"\d+"#, options: .regularExpression) {
                expiryDays = Int(String(expiryStr[numMatch]))
            }
        }
        return (used, total, expiryDays)
    }

    private static func parseResetDate(_ dateStr: String) -> Date? {
        if dateStr.contains("-") {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = Calendar.current.timeZone
            formatter.dateFormat = "yyyy-MM-dd"
            return formatter.date(from: dateStr)
        }

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

    public static func displayPlanName(_ planName: String) -> String {
        let cleaned = Self.cleanInlineValue(planName)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: [.regularExpression])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleaned.localizedCaseInsensitiveContains("KIRO") else {
            return cleaned.isEmpty ? planName : cleaned
        }
        return cleaned
            .split(separator: " ")
            .map { word in
                if word.caseInsensitiveCompare("KIRO") == .orderedSame { return "Kiro" }
                return word.prefix(1).uppercased() + word.dropFirst().lowercased()
            }
            .joined(separator: " ")
    }

    private static func percent(after label: String, in text: String) -> Double? {
        let escaped = NSRegularExpression.escapedPattern(for: label)
        return self.firstCapture(
            in: text,
            pattern: #"(?i)"# + escaped + #"\s+(\d+\.?\d*)%"#)
            .flatMap(Double.init)
    }

    private static func firstCapture(in text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return nil }
        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: nsRange) else { return nil }
        let captureIndex = match.numberOfRanges > 1 ? 1 : 0
        guard let range = Range(match.range(at: captureIndex), in: text) else { return nil }
        return String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func cleanInlineValue(_ text: String) -> String {
        self.stripANSI(text)
            .replacingOccurrences(of: #"\x1B|\[[0-9;?]*[A-Za-z]"#, with: "", options: [.regularExpression])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isUsageOutputComplete(_ output: String) -> Bool {
        let stripped = self.stripANSI(output).lowercased()
        return stripped.contains("covered in plan")
            || stripped.contains("resets on")
            || stripped.contains("bonus credits")
            || stripped.contains("plan:")
            || stripped.contains("managed by admin")
    }
}

extension String {
    fileprivate var nilIfEmpty: String? {
        self.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : self
    }
}
