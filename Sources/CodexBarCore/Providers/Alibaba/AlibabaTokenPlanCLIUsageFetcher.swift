import CoreFoundation
import Foundation

enum AlibabaTokenPlanCLIUsageError: LocalizedError, Sendable, Equatable {
    case unavailable
    case commandFailed
    case timedOut
    case invalidOutput

    var errorDescription: String? {
        switch self {
        case .unavailable:
            "Bailian CLI 'bl' is not installed or not on PATH."
        case .commandFailed:
            "Bailian CLI could not load Token Plan usage. Sign in with 'bl' and try again."
        case .timedOut:
            "Bailian CLI Token Plan usage timed out."
        case .invalidOutput:
            "Bailian CLI returned an unsupported Token Plan usage response."
        }
    }
}

enum AlibabaTokenPlanCLIUsageParser {
    static func parse(_ data: Data, now: Date = Date()) throws -> AlibabaTokenPlanUsageSnapshot {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let payload = object as? [String: Any]
        else {
            throw AlibabaTokenPlanCLIUsageError.invalidOutput
        }

        let fiveHourRatio = self.ratio(payload["per5HourPercentage"])
        let weeklyRatio = self.ratio(payload["per1WeekPercentage"])
        guard fiveHourRatio != nil || weeklyRatio != nil else {
            throw AlibabaTokenPlanCLIUsageError.invalidOutput
        }

        return AlibabaTokenPlanUsageSnapshot(
            planName: "Token Plan",
            usedQuota: nil,
            totalQuota: nil,
            remainingQuota: nil,
            resetsAt: nil,
            fiveHourUsedPercent: fiveHourRatio.map { $0 * 100 },
            fiveHourResetsAt: fiveHourRatio == nil ? nil : self.resetDate(payload["per5HourResetTime"]),
            weeklyUsedPercent: weeklyRatio.map { $0 * 100 },
            weeklyResetsAt: weeklyRatio == nil ? nil : self.resetDate(payload["per1WeekResetTime"]),
            updatedAt: now)
    }

    private static func ratio(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID()
        else { return nil }
        let ratio = number.doubleValue
        return ratio.isFinite && (0...1).contains(ratio) ? ratio : nil
    }

    private static func resetDate(_ value: Any?) -> Date? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID()
        else { return nil }
        let milliseconds = number.doubleValue
        guard milliseconds.isFinite, milliseconds > 0 else { return nil }
        return Date(timeIntervalSince1970: milliseconds / 1000)
    }
}

enum AlibabaTokenPlanCLIUsageFetcher {
    static let timeout: TimeInterval = 15
    static let maxOutputBytes = 64 * 1024

    static func arguments(region: AlibabaTokenPlanAPIRegion) -> [String] {
        [
            "usage", "token-plan",
            "--console-region", region.currentRegionID,
            "--console-site", region.cliConsoleSite,
            "--output", "json",
        ]
    }

    static func fetch(
        region: AlibabaTokenPlanAPIRegion,
        environment: [String: String],
        now: Date = Date()) async throws -> AlibabaTokenPlanUsageSnapshot
    {
        var processEnvironment = environment
        processEnvironment["PATH"] = PathBuilder.effectivePATH(
            purposes: [.tty],
            env: environment,
            loginPATH: LoginShellPathCache.shared.current)
        guard let binary = self.resolveBinary(environment: processEnvironment) else {
            throw AlibabaTokenPlanCLIUsageError.unavailable
        }
        do {
            let result = try await SubprocessRunner.run(
                binary: binary,
                arguments: self.arguments(region: region),
                environment: processEnvironment,
                timeout: self.timeout,
                maxOutputBytes: self.maxOutputBytes,
                label: "bailian-token-plan-usage")
            return try AlibabaTokenPlanCLIUsageParser.parse(Data(result.stdout.utf8), now: now)
        } catch let error as AlibabaTokenPlanCLIUsageError {
            throw error
        } catch let error as SubprocessRunnerError {
            switch error {
            case .timedOut:
                throw AlibabaTokenPlanCLIUsageError.timedOut
            case .binaryNotFound:
                throw AlibabaTokenPlanCLIUsageError.unavailable
            case .launchFailed, .outputTooLarge, .nonZeroExit:
                throw AlibabaTokenPlanCLIUsageError.commandFailed
            }
        } catch let error as CancellationError {
            throw error
        } catch {
            throw AlibabaTokenPlanCLIUsageError.commandFailed
        }
    }

    static func resolveBinary(
        environment: [String: String],
        fileManager: FileManager = .default) -> String?
    {
        guard let path = environment["PATH"] else { return nil }
        for directory in path.split(separator: ":", omittingEmptySubsequences: false) {
            let base = directory.isEmpty ? "." : String(directory)
            let candidate = URL(fileURLWithPath: base).appendingPathComponent("bl").path
            if fileManager.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }
}
