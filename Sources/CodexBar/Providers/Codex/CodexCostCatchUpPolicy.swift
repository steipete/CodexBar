import Foundation
import IOKit.ps

enum CodexCostCatchUpMode: String, Sendable {
    case automatic
    case accelerated

    func scanDurationPerRefresh(after activeDuration: TimeInterval? = nil) -> TimeInterval {
        switch self {
        case .automatic: max(0.001, CodexCostCatchUpPolicy.automaticBurstDuration - (activeDuration ?? 0))
        case .accelerated: 10
        }
    }
}

enum CodexCostCatchUpPowerSource: String, Sendable {
    case ac
    case battery
    case unknown

    static func current() -> Self {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let source = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String?
        else {
            return .unknown
        }
        if source == kIOPSACPowerValue as String {
            return .ac
        }
        if source == kIOPSBatteryPowerValue as String {
            return .battery
        }
        return .unknown
    }
}

enum CodexCostCatchUpPauseReason: Sendable, Equatable {
    case lowPower
    case thermal
    case user
    case noProgress
    case error(String)
}

struct CodexCostCatchUpActivity: Sendable, Equatable {
    enum Phase: Sendable, Equatable {
        case indexing
        case paused
        case complete
    }

    var phase: Phase
    let mode: CodexCostCatchUpMode
    let processedBytes: Int64
    let totalBytes: Int64
    let completedFiles: Int
    let totalFiles: Int
    var pauseReason: CodexCostCatchUpPauseReason?
    let staleSnapshotUpdatedAt: Date?

    var requiresExplicitResume: Bool {
        guard self.phase == .paused else { return false }
        return switch self.pauseReason {
        case .user, .noProgress, .error: true
        case .lowPower, .thermal, .none: false
        }
    }

    var fractionCompleted: Double? {
        guard self.totalBytes > 0 else {
            guard self.totalFiles > 0 else { return nil }
            return min(1, max(0, Double(self.completedFiles) / Double(self.totalFiles)))
        }
        return min(1, max(0, Double(self.processedBytes) / Double(self.totalBytes)))
    }
}

struct CodexCostCatchUpPolicy: Sendable {
    struct Input: Sendable {
        let mode: CodexCostCatchUpMode
        let previousActiveDuration: TimeInterval?
        let powerSource: CodexCostCatchUpPowerSource
        let lowPowerModeEnabled: Bool
        let thermalState: ProcessInfo.ThermalState
        var completedPasses: Int = 0
    }

    struct Decision: Sendable, Equatable {
        enum Action: Sendable, Equatable {
            case runAfter(TimeInterval)
            case pause(TimeInterval, CodexCostCatchUpPauseReason)
        }

        let action: Action
        let targetDutyCycle: Double?
    }

    static let automaticBurstDuration: TimeInterval = 2
    static let constrainedRetryDelay: TimeInterval = 60

    func decision(for input: Input) -> Decision {
        if input.thermalState == .critical {
            return Decision(
                action: .pause(Self.constrainedRetryDelay, .thermal),
                targetDutyCycle: nil)
        }
        if input.mode == .automatic {
            // Report the stronger constraint when both pauses apply.
            if input.thermalState == .serious {
                return Decision(
                    action: .pause(Self.constrainedRetryDelay, .thermal),
                    targetDutyCycle: nil)
            }
            if input.lowPowerModeEnabled {
                return Decision(
                    action: .pause(Self.constrainedRetryDelay, .lowPower),
                    targetDutyCycle: nil)
            }
        }
        if input.mode == .accelerated {
            return Decision(action: .runAfter(0), targetDutyCycle: 1)
        }

        let dutyCycle = switch input.powerSource {
        case .ac: 0.001
        case .battery: 0.0002
        case .unknown: 0.0005
        }
        let activeDuration = max(0, input.previousActiveDuration ?? 0)
        // Cheap discovery pages share one burst; readiness is still checked after every page.
        if activeDuration < Self.automaticBurstDuration, input.completedPasses < 8 {
            return Decision(action: .runAfter(0), targetDutyCycle: dutyCycle)
        }
        let delay = activeDuration * (1 - dutyCycle) / dutyCycle
        return Decision(action: .runAfter(delay), targetDutyCycle: dutyCycle)
    }
}
