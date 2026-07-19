import Foundation

#if os(macOS)

/// Fetches Augment usage via `auggie account status` CLI command
public struct AuggieCLIProbe: Sendable {
    private static let log = CodexBarLog.logger(LogCategories.auggieCLI)

    public init() {}

    public func fetch() async throws -> AugmentStatusSnapshot {
        let output = try await self.runAuggieAccountStatus()
        return try self.parse(output)
    }

    /// Timeout for the `auggie account status` command.
    private static let commandTimeout: TimeInterval = 15

    private func runAuggieAccountStatus() async throws -> String {
        let env = ProcessInfo.processInfo.environment
        let loginPATH = LoginShellPathCache.shared.current
        let executable = BinaryLocator.resolveAuggieBinary(env: env, loginPATH: loginPATH) ?? "auggie"

        var pathEnv = env
        pathEnv["PATH"] = PathBuilder.effectivePATH(
            purposes: [.tty, .nodeTooling],
            env: env,
            loginPATH: loginPATH)

        let result = try await SubprocessRunner.run(
            binary: executable,
            arguments: ["account", "status"],
            environment: pathEnv,
            timeout: Self.commandTimeout,
            label: "auggie-account-status")

        let output = result.stdout
        let errorOutput = result.stderr

        guard !output.isEmpty else {
            if !errorOutput.isEmpty {
                Self.log.error("Auggie stderr: \(errorOutput)")
            }
            throw AuggieCLIError.noOutput
        }

        // Check for auth errors
        if output.contains("Authentication failed") || output.contains("auggie login") {
            throw AuggieCLIError.notAuthenticated
        }

        return output
    }

    func parse(_ output: String) throws -> AugmentStatusSnapshot {
        // Legacy output:
        // Max Plan 450,000 credits / month
        // 11,657 remaining · 953,170 / 964,827 credits used
        // 2 days remaining in this billing cycle (ends 1/8/2026)
        //
        // Current output (2026+):
        // 319,054 credits remaining                     Max Plan
        // 450,000 credits / month
        // 9 days remaining in this billing cycle (ends 6/9/2026)

        var maxCredits: Int?
        var remaining: Int?
        var used: Int?
        var total: Int?
        var billingCycleEnd: Date?

        for line in output.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.contains("credits / month") {
                if let match = trimmed.range(of: #"([\d,]+)\s+credits\s*/\s*month"#, options: .regularExpression) {
                    let numberStr = String(trimmed[match]).replacingOccurrences(of: ",", with: "")
                        .replacingOccurrences(of: " credits", with: "")
                        .replacingOccurrences(of: " / month", with: "")
                    maxCredits = Int(numberStr)
                    total = total ?? Int(numberStr)
                }
            } else if trimmed.contains("Max Plan"), trimmed.contains("credits"), !trimmed.contains("remaining") {
                if let match = trimmed.range(of: #"([\d,]+)\s+credits"#, options: .regularExpression) {
                    let numberStr = String(trimmed[match]).replacingOccurrences(of: ",", with: "")
                        .replacingOccurrences(of: " credits", with: "")
                    maxCredits = Int(numberStr)
                }
            }

            if trimmed.contains("credits remaining"), !trimmed.contains("billing cycle") {
                if let match = trimmed.range(of: #"([\d,]+)\s+credits\s+remaining"#, options: .regularExpression) {
                    let numberStr = String(trimmed[match]).replacingOccurrences(of: ",", with: "")
                        .replacingOccurrences(of: " credits", with: "")
                        .replacingOccurrences(of: " remaining", with: "")
                    remaining = Int(numberStr)
                }
            }

            // Parse "11,657 remaining · 953,170 / 964,827 credits used"
            if trimmed.contains("remaining"), trimmed.contains("credits used") {
                if let remMatch = trimmed.range(of: #"([\d,]+)\s+remaining"#, options: .regularExpression) {
                    let numStr = String(trimmed[remMatch])
                        .replacingOccurrences(of: ",", with: "")
                        .replacingOccurrences(of: " remaining", with: "")
                    remaining = Int(numStr)
                }

                if let usedMatch = trimmed.range(
                    of: #"([\d,]+)\s*/\s*([\d,]+)\s+credits used"#,
                    options: .regularExpression)
                {
                    let parts = String(trimmed[usedMatch])
                        .replacingOccurrences(of: " credits used", with: "")
                        .split(separator: "/")
                    if parts.count == 2 {
                        used = Int(parts[0].replacingOccurrences(of: ",", with: "")
                            .trimmingCharacters(in: .whitespaces))
                        total = Int(parts[1].replacingOccurrences(of: ",", with: "")
                            .trimmingCharacters(in: .whitespaces))
                    }
                }
            }

            if trimmed.contains("billing cycle"), trimmed.contains("ends") {
                if let dateMatch = trimmed.range(of: #"ends\s+([\d/]+)"#, options: .regularExpression) {
                    let dateStr = String(trimmed[dateMatch])
                        .replacingOccurrences(of: "ends", with: "")
                        .trimmingCharacters(in: .whitespaces)

                    let formatter = DateFormatter()
                    formatter.dateFormat = "M/d/yyyy"
                    formatter.locale = Locale(identifier: "en_US_POSIX")
                    formatter.timeZone = TimeZone.current
                    billingCycleEnd = formatter.date(from: dateStr)
                }
            }
        }

        guard let finalRemaining = remaining else {
            Self.log.error("Failed to parse auggie output: \(output)")
            throw AuggieCLIError.parseError("Could not extract credits from output")
        }

        let finalTotal = total ?? maxCredits
        guard let finalTotal else {
            Self.log.error("Failed to parse auggie output: \(output)")
            throw AuggieCLIError.parseError("Could not extract credits from output")
        }

        let finalUsed = used ?? max(0, finalTotal - finalRemaining)

        return AugmentStatusSnapshot(
            creditsRemaining: Double(finalRemaining),
            creditsUsed: Double(finalUsed),
            creditsLimit: Double(finalTotal),
            billingCycleEnd: billingCycleEnd,
            accountEmail: nil,
            accountPlan: maxCredits.map { "\($0.formatted()) credits/month" },
            rawJSON: nil)
    }
}

#else

public struct AuggieCLIProbe: Sendable {
    public init() {}

    public func fetch() async throws -> AugmentStatusSnapshot {
        throw AugmentStatusProbeError.notSupported
    }
}

#endif

public enum AuggieCLIError: LocalizedError {
    case noOutput
    case notAuthenticated
    case parseError(String)

    public var errorDescription: String? {
        switch self {
        case .noOutput:
            "Auggie CLI returned no output"
        case .notAuthenticated:
            "Not authenticated. Run 'auggie login' to authenticate."
        case let .parseError(msg):
            "Failed to parse auggie output: \(msg)"
        }
    }
}
