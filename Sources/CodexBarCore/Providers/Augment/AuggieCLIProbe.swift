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

    private func runAuggieAccountStatus() async throws -> String {
        let env = ProcessInfo.processInfo.environment
        let loginPATH = LoginShellPathCache.shared.current
        let executable = BinaryLocator.resolveAuggieBinary(env: env, loginPATH: loginPATH) ?? "auggie"

        var pathEnv = env
        pathEnv["PATH"] = PathBuilder.effectivePATH(
            purposes: [.tty, .nodeTooling],
            env: env,
            loginPATH: loginPATH)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["account", "status"]
        process.environment = pathEnv

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()
        process.waitUntilExit()

        let outputData = stdout.fileHandleForReading.readDataToEndOfFile()
        let errorData = stderr.fileHandleForReading.readDataToEndOfFile()

        let output = String(data: outputData, encoding: .utf8) ?? ""
        let errorOutput = String(data: errorData, encoding: .utf8) ?? ""

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

    private func parse(_ output: String) throws -> AugmentStatusSnapshot {
        // Parse output like:
        // Max Plan 450,000 credits / month
        // 11,657 remaining · 953,170 / 964,827 credits used
        // 2 days remaining in this billing cycle (ends 1/8/2026)

        var maxCredits: Int?
        var remaining: Int?
        var used: Int?
        var total: Int?
        var billingCycleEnd: Date?

        for line in output.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Parse "Max Plan 450,000 credits / month"
            if trimmed.contains("Max Plan"), trimmed.contains("credits") {
                if let match = trimmed.range(of: #"([\d,]+)\s+credits"#, options: .regularExpression) {
                    let numberStr = String(trimmed[match]).replacingOccurrences(of: ",", with: "")
                        .replacingOccurrences(of: " credits", with: "")
                    maxCredits = Int(numberStr)
                }
            }

            // Parse "11,657 remaining · 953,170 / 964,827 credits used"
            if trimmed.contains("remaining"), trimmed.contains("credits used") {
                // Extract remaining
                if let remMatch = trimmed.range(of: #"([\d,]+)\s+remaining"#, options: .regularExpression) {
                    let numStr = String(trimmed[remMatch])
                        .replacingOccurrences(of: ",", with: "")
                        .replacingOccurrences(of: " remaining", with: "")
                    remaining = Int(numStr)
                }

                // Extract used / total
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

            // Parse "2 days remaining in this billing cycle (ends 1/8/2026)"
            if trimmed.contains("billing cycle"), trimmed.contains("ends") {
                // Extract date from "(ends 1/8/2026)"
                if let dateMatch = trimmed.range(of: #"ends\s+([\d/]+)"#, options: .regularExpression) {
                    let dateStr = String(trimmed[dateMatch])
                        .replacingOccurrences(of: "ends", with: "")
                        .trimmingCharacters(in: .whitespaces)

                    // Parse date like "1/8/2026"
                    let formatter = DateFormatter()
                    formatter.dateFormat = "M/d/yyyy"
                    formatter.locale = Locale(identifier: "en_US_POSIX")
                    formatter.timeZone = TimeZone.current
                    billingCycleEnd = formatter.date(from: dateStr)
                }
            }
        }

        guard let finalRemaining = remaining, let finalUsed = used, let finalTotal = total else {
            Self.log.error("Failed to parse auggie output: \(output)")
            throw AuggieCLIError.parseError("Could not extract credits from output")
        }

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
