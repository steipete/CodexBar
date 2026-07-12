import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

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
    public let overageCreditsUsed: Double?
    public let estimatedOverageCostUSD: Double?
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
        overageCreditsUsed: Double? = nil,
        estimatedOverageCostUSD: Double? = nil,
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
        self.overageCreditsUsed = overageCreditsUsed
        self.estimatedOverageCostUSD = estimatedOverageCostUSD
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
            overageCreditsUsed: self.overageCreditsUsed,
            estimatedOverageCostUSD: self.estimatedOverageCostUSD,
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
    public let overageCreditsUsed: Double?
    public let estimatedOverageCostUSD: Double?
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
        overageCreditsUsed: Double?,
        estimatedOverageCostUSD: Double?,
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
        self.overageCreditsUsed = overageCreditsUsed
        self.estimatedOverageCostUSD = estimatedOverageCostUSD
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
    struct PipeProcessRegistry: Sendable {
        let beginLaunch: @Sendable () -> Bool
        let endLaunch: @Sendable () -> Void
        let register: @Sendable (pid_t, String) -> Bool
        let updateProcessGroup: @Sendable (pid_t, pid_t?) -> Void
        let unregister: @Sendable (pid_t) -> Void

        static let live = Self(
            beginLaunch: { TTYCommandRunner.beginActiveProcessLaunchForAppShutdown() },
            endLaunch: { TTYCommandRunner.endActiveProcessLaunchForAppShutdown() },
            register: { pid, binary in
                TTYCommandRunner.registerActiveProcessForAppShutdown(pid: pid, binary: binary)
            },
            updateProcessGroup: { pid, processGroup in
                TTYCommandRunner.updateActiveProcessGroupForAppShutdown(pid: pid, processGroup: processGroup)
            },
            unregister: { pid in
                TTYCommandRunner.unregisterActiveProcessForAppShutdown(pid: pid)
            })
    }

    private let cliBinaryResolver: @Sendable () -> String?
    private let accountProbeTimeout: TimeInterval
    private let usageProbeTimeout: TimeInterval
    private let contextProbeTimeout: TimeInterval
    private let pipeTimeoutCap: TimeInterval
    private let pipeProcessRegistry: PipeProcessRegistry

    public init() {
        self.cliBinaryResolver = { TTYCommandRunner.which("kiro-cli") }
        self.accountProbeTimeout = 3.0
        self.usageProbeTimeout = 20.0
        self.contextProbeTimeout = 8.0
        self.pipeTimeoutCap = 5.0
        self.pipeProcessRegistry = .live
    }

    init(
        cliBinaryResolver: @escaping @Sendable () -> String?,
        accountProbeTimeout: TimeInterval = 3.0,
        usageProbeTimeout: TimeInterval = 20.0,
        contextProbeTimeout: TimeInterval = 8.0,
        pipeTimeoutCap: TimeInterval = 5.0,
        pipeProcessRegistry: PipeProcessRegistry = .live)
    {
        self.cliBinaryResolver = cliBinaryResolver
        self.accountProbeTimeout = accountProbeTimeout
        self.usageProbeTimeout = usageProbeTimeout
        self.contextProbeTimeout = contextProbeTimeout
        self.pipeTimeoutCap = pipeTimeoutCap
        self.pipeProcessRegistry = pipeProcessRegistry
    }

    private static let logger = CodexBarLog.logger(LogCategories.kiro)

    public static func detectVersion() -> String? {
        guard let path = TTYCommandRunner.which("kiro-cli"),
              let output = ProviderVersionDetector.run(
                  path: path,
                  args: ["--version"],
                  mergeStandardError: true)
        else {
            self.logger.debug("kiro-cli version detection failed")
            return nil
        }
        // Output is like "kiro-cli 1.23.1"
        if output.hasPrefix("kiro-cli ") {
            return String(output.dropFirst("kiro-cli ".count))
        }
        return output
    }

    public func fetch() async throws -> KiroUsageSnapshot {
        let accountTask = Task { await self.fetchAccountStatus() }

        let output: String
        do {
            output = try await self.runUsageCommand()
        } catch is CancellationError {
            accountTask.cancel()
            _ = await accountTask.value
            throw CancellationError()
        } catch {
            if try await self.awaitAccountStatus(accountTask) == .notLoggedIn {
                throw KiroStatusProbeError.notLoggedIn
            }
            throw error
        }

        var contextUsage: KiroContextUsageSnapshot?
        do {
            contextUsage = try await self.fetchContextUsage()
        } catch is CancellationError {
            accountTask.cancel()
            _ = await accountTask.value
            throw CancellationError()
        } catch {
            Self.logger.debug("Kiro context usage probe failed: \(error.localizedDescription)")
        }

        let accountStatus = try await self.awaitAccountStatus(accountTask)
        let accountInfo = accountStatus.account
        do {
            return try self.parse(
                output: output,
                accountEmail: accountInfo?.email,
                authMethod: accountInfo?.authMethod,
                contextUsage: contextUsage)
        } catch KiroStatusProbeError.parseError where accountStatus == .notLoggedIn {
            throw KiroStatusProbeError.notLoggedIn
        }
    }

    struct KiroAccountInfo: Equatable {
        let authMethod: String?
        let email: String?
    }

    struct KiroCLIResult: Sendable {
        let stdout: String
        let stderr: String
        let terminationStatus: Int32
        let stoppedAfterOutput: Bool

        var output: String {
            let stdout = self.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            let stderr = self.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return [stdout, stderr]
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
        }
    }

    private enum KiroCommandKind: String, Sendable {
        case whoAmI = "whoami"
        case usage
        case context
    }

    private enum KiroTransportOutcome: Sendable {
        case result(KiroCLIResult)
        case failure(KiroStatusProbeError)
        case cancelled
    }

    private enum KiroTransportEvent: Sendable {
        case pipe(KiroTransportOutcome)
        case pty(KiroTransportOutcome)
        case fallbackReady
    }

    private final class KiroPipeActivityState: @unchecked Sendable {
        private let lock = NSLock()
        private var lastActivity = ContinuousClock.now
        private var receivedOutput = false

        var lastActivityAt: ContinuousClock.Instant {
            self.lock.withLock { self.lastActivity }
        }

        var hasReceivedOutput: Bool {
            self.lock.withLock { self.receivedOutput }
        }

        func markActivity() {
            self.lock.withLock {
                self.lastActivity = .now
                self.receivedOutput = true
            }
        }
    }

    private final class KiroTransportCancellationState: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false

        var isCancelled: Bool {
            self.lock.withLock { self.cancelled }
        }

        func cancel() {
            self.lock.withLock { self.cancelled = true }
        }
    }

    private enum KiroAccountProbeStatus: Equatable {
        case account(KiroAccountInfo)
        case notLoggedIn
        case unavailable

        var account: KiroAccountInfo? {
            guard case let .account(info) = self else { return nil }
            return info
        }
    }

    private func fetchAccountStatus() async -> KiroAccountProbeStatus {
        do {
            return try await .account(self.ensureLoggedIn())
        } catch KiroStatusProbeError.notLoggedIn {
            return .notLoggedIn
        } catch {
            Self.logger.debug("Kiro account probe failed: \(error.localizedDescription)")
            return .unavailable
        }
    }

    private func awaitAccountStatus(
        _ task: Task<KiroAccountProbeStatus, Never>) async throws -> KiroAccountProbeStatus
    {
        let status = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        try Task.checkCancellation()
        return status
    }

    private func ensureLoggedIn() async throws -> KiroAccountInfo {
        let result = try await self.runCommand(
            arguments: ["whoami"],
            timeout: self.accountProbeTimeout,
            idleTimeout: 1.5,
            kind: .whoAmI)
        if result.stoppedAfterOutput {
            if Self.isLoginRequired(result.output) {
                throw KiroStatusProbeError.notLoggedIn
            }
            throw KiroStatusProbeError.timeout
        }
        return try self.validateWhoAmIOutput(
            stdout: result.stdout,
            stderr: result.stderr,
            terminationStatus: result.terminationStatus)
    }

    func validateWhoAmIOutput(stdout: String, stderr: String, terminationStatus: Int32) throws -> KiroAccountInfo {
        let combined = KiroCLIResult(
            stdout: stdout,
            stderr: stderr,
            terminationStatus: terminationStatus,
            stoppedAfterOutput: false).output

        if Self.isLoginRequired(combined) {
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

    private static func isLoginRequired(_ output: String) -> Bool {
        let lowered = Self.stripANSI(output).lowercased()
        return lowered.contains("not logged in")
            || lowered.contains("login required")
            || lowered.contains("failed to initialize auth portal")
            || lowered.contains("kiro-cli login")
            || lowered.contains("oauth error")
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
            timeout: self.usageProbeTimeout,
            idleTimeout: 4.0,
            kind: .usage)
        let output = result.output
        if Self.isLoginRequired(output) {
            throw KiroStatusProbeError.notLoggedIn
        }

        try Self.validateCommandCompletion(
            result,
            command: "usage",
            allowIdleOutput: (try? self.parse(output: output)) != nil)
        return output
    }

    private func fetchContextUsage() async throws -> KiroContextUsageSnapshot? {
        let result = try await self.runCommand(
            arguments: ["chat", "--no-interactive", "/context"],
            timeout: self.contextProbeTimeout,
            idleTimeout: 3.0,
            kind: .context)
        let contextUsage = self.parseContextUsage(output: result.output)
        try Self.validateCommandCompletion(
            result,
            command: "context",
            allowIdleOutput: contextUsage != nil)
        return contextUsage
    }

    private func runViaPipe(
        arguments: [String],
        timeout: TimeInterval,
        idleTimeout: TimeInterval,
        activityState state: KiroPipeActivityState) async throws -> KiroCLIResult
    {
        try Task.checkCancellation()
        guard let binary = self.cliBinaryResolver() else {
            throw KiroStatusProbeError.cliNotFound
        }

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()

        var env = TTYCommandRunner.enrichedEnvironment()
        env["TERM"] = "xterm-256color"

        guard self.pipeProcessRegistry.beginLaunch() else {
            throw KiroStatusProbeError.cliFailed("App shutdown in progress")
        }
        var launchReservationHeld = true
        defer {
            if launchReservationHeld {
                self.pipeProcessRegistry.endLaunch()
            }
        }

        let stdoutCapture = ProcessPipeCapture(pipe: stdoutPipe, onData: { state.markActivity() })
        let stderrCapture = ProcessPipeCapture(pipe: stderrPipe, onData: { state.markActivity() })
        stdoutCapture.start()
        stderrCapture.start()

        let process: SpawnedProcessGroup
        do {
            try Task.checkCancellation()
            process = try SpawnedProcessGroup.launch(
                binary: binary,
                arguments: arguments,
                environment: env,
                stdoutPipe: stdoutPipe,
                stderrPipe: stderrPipe)
        } catch {
            stdoutCapture.stop()
            stderrCapture.stop()
            throw error
        }

        guard self.pipeProcessRegistry.register(
            process.pid,
            URL(fileURLWithPath: binary).lastPathComponent)
        else {
            await Self.terminateCancelledPipeProcess(
                process,
                stdoutCapture: stdoutCapture,
                stderrCapture: stderrCapture)
            throw KiroStatusProbeError.cliFailed("App shutdown in progress")
        }
        self.pipeProcessRegistry.updateProcessGroup(process.pid, process.processGroup)
        self.pipeProcessRegistry.endLaunch()
        launchReservationHeld = false
        defer { self.pipeProcessRegistry.unregister(process.pid) }

        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(max(0, timeout)))
        var didHitDeadline = false
        var didTerminateForIdle = false

        do {
            while process.isRunning {
                try Task.checkCancellation()
                let now = clock.now
                if now >= deadline {
                    didHitDeadline = true
                    break
                }
                if state.hasReceivedOutput,
                   state.lastActivityAt.duration(to: now) >= .seconds(max(0, idleTimeout))
                {
                    didTerminateForIdle = true
                    break
                }
                try await Task.sleep(for: .milliseconds(100))
            }
        } catch {
            await Self.terminateCancelledPipeProcess(
                process,
                stdoutCapture: stdoutCapture,
                stderrCapture: stderrCapture)
            throw error
        }

        if process.isRunning {
            await process.terminate()
            guard !process.isRunning else {
                stdoutCapture.stop()
                stderrCapture.stop()
                throw KiroStatusProbeError.timeout
            }
            if !state.hasReceivedOutput {
                stdoutCapture.stop()
                stderrCapture.stop()
                throw KiroStatusProbeError.timeout
            }
        }
        await process.terminateResidualProcesses()

        async let stdoutDataTask = stdoutCapture.finish(timeout: .seconds(1))
        async let stderrDataTask = stderrCapture.finish(timeout: .seconds(1))
        let (stdoutData, stderrData) = await (stdoutDataTask, stderrDataTask)
        if !stdoutCapture.reachedEOF || !stderrCapture.reachedEOF {
            await process.terminateResidualProcesses()
        }
        await process.finish()
        guard let terminationStatus = process.terminationStatus else {
            throw KiroStatusProbeError.timeout
        }
        return KiroCLIResult(
            stdout: ProcessPipeCapture.decodeUTF8(stdoutData),
            stderr: ProcessPipeCapture.decodeUTF8(stderrData),
            terminationStatus: terminationStatus,
            stoppedAfterOutput: didTerminateForIdle || didHitDeadline)
    }

    private static func terminateCancelledPipeProcess(
        _ process: SpawnedProcessGroup,
        stdoutCapture: ProcessPipeCapture,
        stderrCapture: ProcessPipeCapture) async
    {
        let cleanupTask = Task.detached(priority: .userInitiated) {
            await process.terminate()
            stdoutCapture.stop()
            stderrCapture.stop()
        }
        await cleanupTask.value
    }

    private func runViaPTY(
        arguments: [String],
        timeout: TimeInterval,
        idleTimeout: TimeInterval,
        cancellationState: KiroTransportCancellationState) throws -> KiroCLIResult
    {
        guard let binary = self.cliBinaryResolver() else {
            throw KiroStatusProbeError.cliNotFound
        }
        do {
            let result = try TTYCommandRunner().run(
                binary: binary,
                send: "",
                options: TTYCommandRunner.Options(
                    rows: 50,
                    cols: 200,
                    timeout: timeout,
                    idleTimeout: idleTimeout,
                    extraArgs: arguments,
                    returnOnEmptyProcessExit: true,
                    cancellationCheck: {
                        cancellationState.isCancelled || Task<Never, Never>.isCancelled
                    }))
            switch result.completion {
            case let .processExited(status):
                return KiroCLIResult(
                    stdout: result.text,
                    stderr: "",
                    terminationStatus: status,
                    stoppedAfterOutput: false)
            case .idleTimeout:
                return KiroCLIResult(
                    stdout: result.text,
                    stderr: "",
                    terminationStatus: 0,
                    stoppedAfterOutput: true)
            case .outputCondition, .deadlineExceeded:
                throw KiroStatusProbeError.timeout
            }
        } catch TTYCommandRunner.Error.binaryNotFound {
            throw KiroStatusProbeError.cliNotFound
        } catch TTYCommandRunner.Error.timedOut {
            throw KiroStatusProbeError.timeout
        } catch let TTYCommandRunner.Error.launchFailed(message) {
            throw KiroStatusProbeError.cliFailed(message)
        }
    }

    private func runViaPTYAsync(
        arguments: [String],
        timeout: TimeInterval,
        idleTimeout: TimeInterval,
        cancellationState: KiroTransportCancellationState) async throws -> KiroCLIResult
    {
        let task = Task.detached(priority: .userInitiated) {
            try self.runViaPTY(
                arguments: arguments,
                timeout: timeout,
                idleTimeout: idleTimeout,
                cancellationState: cancellationState)
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            cancellationState.cancel()
        }
    }

    private static func validateCommandCompletion(
        _ result: KiroCLIResult,
        command: String,
        allowIdleOutput: Bool) throws
    {
        if result.stoppedAfterOutput {
            guard allowIdleOutput else { throw KiroStatusProbeError.timeout }
            return
        }
        guard result.terminationStatus == 0 else {
            let message = Self.stripANSI(result.output).trimmingCharacters(in: .whitespacesAndNewlines)
            throw KiroStatusProbeError.cliFailed(
                message.isEmpty
                    ? "Kiro CLI \(command) failed with status \(result.terminationStatus)."
                    : message)
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
        let overageCreditsUsed = Self.firstCapture(
            in: stripped,
            pattern: #"(?i)Credits used:\s*(\d+\.?\d*)"#)
            .flatMap(Double.init)
        let estimatedOverageCostUSD = Self.firstCapture(
            in: stripped,
            pattern: #"(?i)Est\.\s*cost:\s*\$?(\d+\.?\d*)\s*USD"#)
            .flatMap(Double.init)
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
                overageCreditsUsed: overageCreditsUsed,
                estimatedOverageCostUSD: estimatedOverageCostUSD,
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
            overageCreditsUsed: overageCreditsUsed,
            estimatedOverageCostUSD: estimatedOverageCostUSD,
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
        // Horizontal whitespace only ([ \t]) so the match cannot bridge a newline into the next line.
        if let planMatch = text.range(of: #"\|[ \t]*(KIRO[ \t]+\w+)"#, options: .regularExpression) {
            let raw = String(text[planMatch]).replacingOccurrences(of: "|", with: "")
            planName = raw.trimmingCharacters(in: .whitespaces)
        }

        // Parse plan name from "Estimated Usage | resets on 2026-06-01 | KIRO FREE" (kiro-cli 2.x)
        if let estimatedMatch = text.range(
            of: #"Estimated Usage[ \t]*\|[^\n|]*\|[ \t]*([A-Z][A-Z0-9 ]+)"#,
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
        if let newPlanMatch = text.range(of: #"Plan:[ \t]*(.+)"#, options: .regularExpression) {
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
                if word.caseInsensitiveCompare("KIRO") == .orderedSame {
                    return "Kiro"
                }
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
}

extension KiroStatusProbe {
    /// Recent Kiro CLIs can keep their TUI alive indefinitely under a PTY even with `--no-interactive`,
    /// while older releases emit no output through pipes. Prefer pipes and retain PTY as a bounded fallback.
    private func runCommand(
        arguments: [String],
        timeout: TimeInterval,
        idleTimeout: TimeInterval,
        kind: KiroCommandKind) async throws -> KiroCLIResult
    {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(max(0, timeout)))
        let fallbackDelay = min(max(0, self.pipeTimeoutCap), max(0, timeout / 2))
        let pipeActivity = KiroPipeActivityState()
        let cancellationState = KiroTransportCancellationState()

        return try await withThrowingTaskGroup(of: KiroTransportEvent.self) { group in
            defer {
                cancellationState.cancel()
                group.cancelAll()
            }
            group.addTask {
                await .pipe(self.pipeOutcome(
                    arguments: arguments,
                    timeout: timeout,
                    idleTimeout: idleTimeout,
                    activityState: pipeActivity))
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(fallbackDelay))
                return .fallbackReady
            }

            var ptyStarted = false
            var pipeFinishedWithoutAcceptedResult = false
            var pendingPTYResult: KiroCLIResult?
            var pendingPTYFailure: KiroStatusProbeError?
            while let event = try await group.next() {
                try Task.checkCancellation()
                switch event {
                case .fallbackReady:
                    guard !ptyStarted, !pipeActivity.hasReceivedOutput else { continue }
                    let remaining = Self.timeInterval(from: clock.now.duration(to: deadline))
                    guard remaining > 0 else { continue }
                    ptyStarted = true
                    group.addTask {
                        await .pty(self.ptyOutcome(
                            arguments: arguments,
                            timeout: remaining,
                            idleTimeout: min(idleTimeout, remaining),
                            cancellationState: cancellationState))
                    }

                case let .pipe(.result(result)):
                    if try self.shouldReturnPipeResult(
                        result,
                        for: kind,
                        before: deadline,
                        now: clock.now)
                    {
                        cancellationState.cancel()
                        group.cancelAll()
                        return result
                    }
                    pipeFinishedWithoutAcceptedResult = true
                    Self.logger.debug("Kiro pipe \(kind.rawValue) output was incomplete; awaiting PTY fallback")
                    if let pending = try Self.resolvePendingPTY(
                        result: pendingPTYResult,
                        failure: pendingPTYFailure,
                        before: deadline,
                        now: clock.now)
                    {
                        return pending
                    }
                    if !ptyStarted {
                        let remaining = Self.timeInterval(from: clock.now.duration(to: deadline))
                        guard remaining > 0 else { throw KiroStatusProbeError.timeout }
                        ptyStarted = true
                        group.addTask {
                            await .pty(self.ptyOutcome(
                                arguments: arguments,
                                timeout: remaining,
                                idleTimeout: min(idleTimeout, remaining),
                                cancellationState: cancellationState))
                        }
                    }

                case .pipe(.failure(.timeout)):
                    pipeFinishedWithoutAcceptedResult = true
                    Self.logger.debug("Kiro pipe \(kind.rawValue) probe timed out; awaiting PTY fallback")
                    if let pending = try Self.resolvePendingPTY(
                        result: pendingPTYResult,
                        failure: pendingPTYFailure,
                        before: deadline,
                        now: clock.now)
                    {
                        return pending
                    }

                case let .pipe(.failure(error)):
                    cancellationState.cancel()
                    group.cancelAll()
                    throw error

                case .pipe(.cancelled), .pty(.cancelled):
                    throw CancellationError()

                case let .pty(.result(result)):
                    guard self.shouldAcceptPTYResult(result, for: kind) else {
                        if pipeFinishedWithoutAcceptedResult {
                            try Self.ensureBeforeDeadline(clock.now, deadline: deadline)
                            return result
                        }
                        pendingPTYResult = result
                        continue
                    }
                    guard clock.now <= deadline else { throw KiroStatusProbeError.timeout }
                    cancellationState.cancel()
                    group.cancelAll()
                    return result

                case let .pty(.failure(error)):
                    if pipeFinishedWithoutAcceptedResult {
                        throw error
                    }
                    pendingPTYFailure = error
                }
            }
            if let pending = try Self.resolvePendingPTY(
                result: pendingPTYResult,
                failure: pendingPTYFailure,
                before: deadline,
                now: clock.now)
            {
                return pending
            }
            throw KiroStatusProbeError.timeout
        }
    }

    private func pipeOutcome(
        arguments: [String],
        timeout: TimeInterval,
        idleTimeout: TimeInterval,
        activityState: KiroPipeActivityState) async -> KiroTransportOutcome
    {
        do {
            return try await .result(self.runViaPipe(
                arguments: arguments,
                timeout: timeout,
                idleTimeout: idleTimeout,
                activityState: activityState))
        } catch is CancellationError {
            return .cancelled
        } catch let error as KiroStatusProbeError {
            return .failure(error)
        } catch {
            return .failure(.cliFailed(error.localizedDescription))
        }
    }

    private func ptyOutcome(
        arguments: [String],
        timeout: TimeInterval,
        idleTimeout: TimeInterval,
        cancellationState: KiroTransportCancellationState) async -> KiroTransportOutcome
    {
        do {
            return try await .result(self.runViaPTYAsync(
                arguments: arguments,
                timeout: timeout,
                idleTimeout: idleTimeout,
                cancellationState: cancellationState))
        } catch is CancellationError {
            return .cancelled
        } catch let error as KiroStatusProbeError {
            return .failure(error)
        } catch {
            return .failure(.cliFailed(error.localizedDescription))
        }
    }

    fileprivate static func resolvePendingPTY(
        result: KiroCLIResult?,
        failure: KiroStatusProbeError?,
        before deadline: ContinuousClock.Instant,
        now: ContinuousClock.Instant) throws -> KiroCLIResult?
    {
        if result != nil || failure != nil {
            guard now <= deadline else { throw KiroStatusProbeError.timeout }
        }
        if let result {
            return result
        }
        if let failure {
            throw failure
        }
        return nil
    }

    private static func ensureBeforeDeadline(
        _ now: ContinuousClock.Instant,
        deadline: ContinuousClock.Instant) throws
    {
        guard now <= deadline else { throw KiroStatusProbeError.timeout }
    }

    private func shouldAcceptPipeResult(_ result: KiroCLIResult, for kind: KiroCommandKind) -> Bool {
        let output = result.output
        if Self.isLoginRequired(output) {
            return true
        }

        switch kind {
        case .whoAmI:
            let account = self.parseWhoAmIOutput(output)
            return account.authMethod != nil || account.email != nil
        case .usage:
            return (try? self.parse(output: output)) != nil
        case .context:
            if self.parseContextUsage(output: output) != nil {
                return true
            }
            return result.terminationStatus == 0
                && !result.stoppedAfterOutput
                && output.isEmpty
        }
    }

    private func shouldReturnPipeResult(
        _ result: KiroCLIResult,
        for kind: KiroCommandKind,
        before deadline: ContinuousClock.Instant,
        now: ContinuousClock.Instant) throws -> Bool
    {
        let accepted = self.shouldAcceptPipeResult(result, for: kind)
        guard accepted else { return false }
        if !Self.isLoginRequired(result.output), now > deadline {
            throw KiroStatusProbeError.timeout
        }
        return true
    }

    private func shouldAcceptPTYResult(_ result: KiroCLIResult, for kind: KiroCommandKind) -> Bool {
        if Self.isLoginRequired(result.output) {
            return true
        }
        return result.terminationStatus == 0 && self.shouldAcceptPipeResult(result, for: kind)
    }

    fileprivate static func timeInterval(from duration: Duration) -> TimeInterval {
        let components = duration.components
        return max(
            0,
            TimeInterval(components.seconds)
                + TimeInterval(components.attoseconds) / 1_000_000_000_000_000_000)
    }
}

extension String {
    fileprivate var nilIfEmpty: String? {
        self.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : self
    }
}
