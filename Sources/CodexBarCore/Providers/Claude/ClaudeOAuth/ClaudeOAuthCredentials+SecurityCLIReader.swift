import Dispatch
import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

extension ClaudeOAuthCredentialsStore {
    private static let securityBinaryPath = "/usr/bin/security"
    private static let securityCLIReadTimeout: TimeInterval = 1.5

    struct SecurityCLIReadRequest: Sendable {
        let account: String?
    }

    static func shouldPreferSecurityCLIKeychainRead(
        readStrategy: ClaudeOAuthKeychainReadStrategy = ClaudeOAuthKeychainReadStrategyPreference.current())
        -> Bool
    {
        readStrategy == .securityCLIExperimental
    }

    #if os(macOS)
    private enum SecurityCLIReadError: Error, Sendable {
        case binaryUnavailable
        case launchFailed
        case timedOut
        case nonZeroExit(status: Int32, stderrLength: Int)
    }

    private struct SecurityCLIReadCommandResult: Sendable {
        let status: Int32
        let stdout: Data
        let stderrLength: Int
        let durationMs: Double
    }

    /// Attempts a Claude keychain read via `/usr/bin/security` when the experimental reader is enabled.
    /// - Important: `interaction` is diagnostics context only and does not gate CLI execution.
    static func loadFromClaudeKeychainViaSecurityCLIIfEnabled(
        interaction: ProviderInteraction,
        readStrategy: ClaudeOAuthKeychainReadStrategy = ClaudeOAuthKeychainReadStrategyPreference.current())
        -> Data?
    {
        guard self.shouldPreferSecurityCLIKeychainRead(readStrategy: readStrategy) else { return nil }
        let interactionMetadata = interaction == .userInitiated ? "user" : "background"

        do {
            let preferredAccount = self.preferredClaudeKeychainAccountForSecurityCLIRead(
                interaction: interaction)
            let output: Data
            let status: Int32
            let stderrLength: Int
            let durationMs: Double
            #if DEBUG
            if let override = self.taskSecurityCLIReadOverride ?? self.securityCLIReadOverride {
                switch override {
                case let .data(data):
                    output = data ?? Data()
                    status = 0
                    stderrLength = 0
                    durationMs = 0
                case .timedOut:
                    throw SecurityCLIReadError.timedOut
                case .nonZeroExit:
                    throw SecurityCLIReadError.nonZeroExit(status: 1, stderrLength: 0)
                case let .dynamic(read):
                    output = read(SecurityCLIReadRequest(account: preferredAccount)) ?? Data()
                    status = 0
                    stderrLength = 0
                    durationMs = 0
                }
            } else {
                let result = try self.runClaudeSecurityCLIRead(
                    timeout: self.securityCLIReadTimeout,
                    account: preferredAccount)
                output = result.stdout
                status = result.status
                stderrLength = result.stderrLength
                durationMs = result.durationMs
            }
            #else
            let result = try self.runClaudeSecurityCLIRead(
                timeout: self.securityCLIReadTimeout,
                account: preferredAccount)
            output = result.stdout
            status = result.status
            stderrLength = result.stderrLength
            durationMs = result.durationMs
            #endif

            let sanitized = self.sanitizeSecurityCLIOutput(output)
            guard !sanitized.isEmpty else { return nil }
            let parsedCredentials: ClaudeOAuthCredentials
            do {
                parsedCredentials = try ClaudeOAuthCredentials.parse(data: sanitized)
            } catch {
                self.log.warning(
                    "Claude keychain security CLI output invalid; falling back",
                    metadata: [
                        "reader": "securityCLI",
                        "callerInteraction": interactionMetadata,
                        "status": "\(status)",
                        "duration_ms": String(format: "%.2f", durationMs),
                        "stderr_length": "\(stderrLength)",
                        "payload_bytes": "\(sanitized.count)",
                        "parse_error_type": String(describing: type(of: error)),
                    ])
                return nil
            }

            var metadata: [String: String] = [
                "reader": "securityCLI",
                "callerInteraction": interactionMetadata,
                "status": "\(status)",
                "duration_ms": String(format: "%.2f", durationMs),
                "stderr_length": "\(stderrLength)",
                "payload_bytes": "\(sanitized.count)",
                "accountPinned": preferredAccount == nil ? "0" : "1",
            ]
            for (key, value) in parsedCredentials.diagnosticsMetadata(now: Date()) {
                metadata[key] = value
            }
            self.log.debug(
                "Claude keychain security CLI read succeeded",
                metadata: metadata)
            return sanitized
        } catch let error as SecurityCLIReadError {
            var metadata: [String: String] = [
                "reader": "securityCLI",
                "callerInteraction": interactionMetadata,
                "error_type": String(describing: type(of: error)),
            ]
            switch error {
            case .binaryUnavailable:
                metadata["reason"] = "binaryUnavailable"
            case .launchFailed:
                metadata["reason"] = "launchFailed"
            case .timedOut:
                metadata["reason"] = "timedOut"
            case let .nonZeroExit(status, stderrLength):
                metadata["reason"] = "nonZeroExit"
                metadata["status"] = "\(status)"
                metadata["stderr_length"] = "\(stderrLength)"
            }
            self.log.warning("Claude keychain security CLI read failed; falling back", metadata: metadata)
            return nil
        } catch {
            self.log.warning(
                "Claude keychain security CLI read failed; falling back",
                metadata: [
                    "reader": "securityCLI",
                    "callerInteraction": interactionMetadata,
                    "error_type": String(describing: type(of: error)),
                ])
            return nil
        }
    }

    private static func sanitizeSecurityCLIOutput(_ data: Data) -> Data {
        var sanitized = data
        while let last = sanitized.last, last == 0x0A || last == 0x0D {
            sanitized.removeLast()
        }
        return sanitized
    }

    private static func runClaudeSecurityCLIRead(
        timeout: TimeInterval,
        account: String?) throws -> SecurityCLIReadCommandResult
    {
        guard FileManager.default.isExecutableFile(atPath: self.securityBinaryPath) else {
            throw SecurityCLIReadError.binaryUnavailable
        }

        var arguments = [
            "find-generic-password",
            "-s",
            self.claudeKeychainService,
        ]
        if let account, !account.isEmpty {
            arguments.append(contentsOf: ["-a", account])
        }
        arguments.append("-w")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: self.securityBinaryPath)
        process.arguments = arguments

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = nil

        let startedAt = DispatchTime.now().uptimeNanoseconds
        do {
            try process.run()
        } catch {
            throw SecurityCLIReadError.launchFailed
        }

        var processGroup: pid_t?
        let pid = process.processIdentifier
        if setpgid(pid, pid) == 0 {
            processGroup = pid
        }

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }

        if process.isRunning {
            self.terminate(process: process, processGroup: processGroup)
            throw SecurityCLIReadError.timedOut
        }

        let stdout = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderr = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        let status = process.terminationStatus
        let durationMs = Double(DispatchTime.now().uptimeNanoseconds - startedAt) / 1_000_000.0
        guard status == 0 else {
            throw SecurityCLIReadError.nonZeroExit(status: status, stderrLength: stderr.count)
        }

        return SecurityCLIReadCommandResult(
            status: status,
            stdout: stdout,
            stderrLength: stderr.count,
            durationMs: durationMs)
    }

    private static func terminate(process: Process, processGroup: pid_t?) {
        guard process.isRunning else { return }
        process.terminate()
        if let processGroup {
            kill(-processGroup, SIGTERM)
        }
        let deadline = Date().addingTimeInterval(0.4)
        while process.isRunning, Date() < deadline {
            usleep(50000)
        }
        if process.isRunning {
            if let processGroup {
                kill(-processGroup, SIGKILL)
            }
            kill(process.processIdentifier, SIGKILL)
        }
    }
    #else
    static func loadFromClaudeKeychainViaSecurityCLIIfEnabled(
        interaction _: ProviderInteraction,
        readStrategy _: ClaudeOAuthKeychainReadStrategy = ClaudeOAuthKeychainReadStrategyPreference.current())
        -> Data?
    {
        nil
    }
    #endif
}
