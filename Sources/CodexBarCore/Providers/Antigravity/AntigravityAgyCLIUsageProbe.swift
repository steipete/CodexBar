import Foundation

public enum AntigravityAgyCLIUsageProbeError: LocalizedError, Sendable {
    case cliNotInstalled
    case captureFailed(String)
    case parseFailed(String)
    case timedOut

    public var errorDescription: String? {
        switch self {
        case .cliNotInstalled:
            "Antigravity CLI (`agy`) not found."
        case let .captureFailed(message):
            "Failed to capture Antigravity CLI usage: \(message)"
        case let .parseFailed(message):
            "Could not parse Antigravity CLI /usage output: \(message)"
        case .timedOut:
            "Timed out waiting for Antigravity CLI /usage panel."
        }
    }
}

/// Captures the interactive `/usage` panel from the Antigravity CLI (`agy`).
/// This matches the "Model Quota" view shown inside agy, including Claude and Gemini buckets.
public enum AntigravityAgyCLIUsageProbe: Sendable {
    private static let log = CodexBarLog.logger(LogCategories.antigravity)

    public static func fetch(
        timeout: TimeInterval = 20.0,
        env: [String: String] = ProcessInfo.processInfo.environment,
        loginPATH: [String]? = LoginShellPathCache.shared.current) async throws
        -> AntigravityStatusSnapshot
    {
        guard let binary = BinaryLocator.resolveAgyBinary(env: env, loginPATH: loginPATH) else {
            throw AntigravityAgyCLIUsageProbeError.cliNotInstalled
        }

        let captured = try await Self.captureUsage(binary: binary, timeout: timeout)
        let modelQuotas = try Self.parseUsageOutput(captured)
        guard !modelQuotas.isEmpty else {
            throw AntigravityAgyCLIUsageProbeError.parseFailed("No model quotas found in /usage output")
        }

        let account: String? = {
            guard let credentials = try? AntigravityAgyCredentials.loadCredentials(),
                  let email = credentials.email?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !email.isEmpty
            else { return nil }
            return email
        }()

        Self.log.info(
            "Antigravity agy /usage capture ok",
            metadata: ["modelCount": "\(modelQuotas.count)"])

        return AntigravityStatusSnapshot(
            modelQuotas: modelQuotas,
            accountEmail: account,
            accountPlan: nil)
    }

    static func parseUsageOutput(_ text: String) throws -> [AntigravityModelQuota] {
        let plain = Self.stripANSI(text)
        let lines = plain
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        var quotas: [AntigravityModelQuota] = []
        var pendingLabel: String?
        var seenLabels = Set<String>()

        for line in lines {
            if Self.shouldSkipLine(line) {
                continue
            }

            if let percent = Self.extractTrailingPercent(from: line) {
                guard let label = pendingLabel else { continue }
                let key = label.lowercased()
                guard seenLabels.insert(key).inserted else {
                    pendingLabel = nil
                    continue
                }
                quotas.append(AntigravityModelQuota(
                    label: label,
                    modelId: Self.modelID(from: label),
                    remainingFraction: percent / 100.0,
                    resetTime: nil,
                    resetDescription: nil))
                pendingLabel = nil
                continue
            }

            if Self.looksLikeModelLabel(line) {
                pendingLabel = Self.cleanLabel(line)
            }
        }

        guard !quotas.isEmpty else {
            throw AntigravityAgyCLIUsageProbeError.parseFailed("Model Quota panel not found")
        }

        return quotas.sorted {
            $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending
        }
    }

    private static func captureUsage(binary: String, timeout: TimeInterval) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let runner = TTYCommandRunner()
                    // `agy` signs in fresh on every cold launch ("Signing in…"), and that latency is
                    // variable. Sending `/usage` at a fixed delay races the sign-in: if it lands while
                    // agy is still authenticating the command is dropped and the panel never renders.
                    // Instead, wait for the ready prompt marker ("? for shortcuts") before sending
                    // `/usage`, and stop the moment the Model Quota panel footer appears. Warm starts
                    // finish in ~2-3s; the larger ceiling only applies to genuinely slow sign-ins.
                    let result = try runner.run(
                        binary: binary,
                        send: "",
                        options: TTYCommandRunner.Options(
                            rows: 40,
                            cols: 120,
                            timeout: max(timeout, 40),
                            initialDelay: 0.5,
                            sendOnSubstrings: ["? for shortcuts": "/usage\r"],
                            stopOnSubstrings: ["pgup/pgdown", "esc Close"],
                            settleAfterStop: 0.5))
                    continuation.resume(returning: result.text)
                } catch TTYCommandRunner.Error.timedOut {
                    continuation.resume(throwing: AntigravityAgyCLIUsageProbeError.timedOut)
                } catch TTYCommandRunner.Error.binaryNotFound {
                    continuation.resume(throwing: AntigravityAgyCLIUsageProbeError.cliNotInstalled)
                } catch {
                    continuation.resume(
                        throwing: AntigravityAgyCLIUsageProbeError.captureFailed(error.localizedDescription))
                }
            }
        }
    }

    private static func shouldSkipLine(_ line: String) -> Bool {
        let lowered = line.lowercased()
        if lowered == "model quota" || lowered.hasPrefix("└ model quota") {
            return true
        }
        if lowered == "quota available" || lowered == "quota exhausted" {
            return true
        }
        if lowered.contains("esc to cancel") || lowered.contains("ctrl+home") || lowered.contains("ctrl+end") {
            return true
        }
        if line.contains(" of ") && line.contains(" lines") {
            return true
        }
        if line.allSatisfy({ $0 == "█" || $0 == " " || $0 == "▌" || $0 == "▎" }) {
            return true
        }
        return false
    }

    private static func looksLikeModelLabel(_ line: String) -> Bool {
        guard line.count >= 3 else { return false }
        guard line.first?.isLetter == true || line.hasPrefix("GPT-") else { return false }
        if line.contains("██") { return false }
        if line.contains("Scroll") { return false }
        if Self.extractTrailingPercent(from: line) != nil { return false }
        return line.contains(where: \.isLetter)
    }

    private static func extractTrailingPercent(from line: String) -> Double? {
        guard let range = line.range(of: #"(\d{1,3})%\s*$"#, options: .regularExpression) else {
            return nil
        }
        let match = String(line[range])
        guard let value = Double(match.dropLast()) else { return nil }
        return max(0, min(100, value))
    }

    private static func modelID(from label: String) -> String {
        let slug = label
            .lowercased()
            .replacingOccurrences(of: #"[^a-z0-9]+"#, with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return slug.isEmpty ? label : slug
    }

    private static func cleanLabel(_ line: String) -> String {
        Self.stripANSI(line).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func stripANSI(_ text: String) -> String {
        // The ESC must be a real U+001B byte in the pattern. A raw string would pass Swift's `\u{001B}`
        // escape through verbatim, and NSRegularExpression (ICU) does not understand `\u{...}`. The
        // previous pattern also bundled a second, non-CSI alternation that was *invalid* ICU syntax, so
        // the whole `replacingOccurrences` was rejected and silently stripped nothing — every ANSI code
        // survived and broke label/percent detection on real `agy` captures (ANSI-free test fixtures hid
        // the bug). This valid CSI matcher — ESC `[`, params, intermediates, final byte — covers the
        // colour/erase/cursor sequences agy emits (`[1m`, `[m`, `[K`, `[80X`, `[38;2;…m`, etc.).
        let escape = "\u{001B}"
        var plain = text.replacingOccurrences(
            of: escape + #"\[[0-9;?]*[ -/]*[@-~]"#,
            with: "",
            options: .regularExpression)
        plain = plain.replacingOccurrences(of: "\u{0008}", with: "")
        return plain
    }
}
