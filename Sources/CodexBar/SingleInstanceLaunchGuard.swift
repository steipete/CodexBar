import AppKit
import CodexBarCore
import Foundation

struct RunningApplicationSnapshot: Equatable {
    let processIdentifier: pid_t
    let bundleURL: URL?
    let isTerminated: Bool
}

enum SingleInstanceLaunchDecision: Equatable {
    case continueLaunch
    case terminateCurrent(existingProcessIdentifier: pid_t)
}

enum SingleInstanceLaunchGuard {
    static func launchDecision(
        currentProcessIdentifier: pid_t,
        runningApplications: [RunningApplicationSnapshot]) -> SingleInstanceLaunchDecision
    {
        let activeProcessIdentifiers = runningApplications
            .filter { !$0.isTerminated }
            .map(\.processIdentifier)
        guard let preferredProcessIdentifier = activeProcessIdentifiers.min(),
              preferredProcessIdentifier != currentProcessIdentifier
        else {
            return .continueLaunch
        }
        return .terminateCurrent(existingProcessIdentifier: preferredProcessIdentifier)
    }

    @MainActor
    static func terminateCurrentIfDuplicateRunning(
        bundleIdentifier: String? = Bundle.main.bundleIdentifier,
        currentProcessIdentifier: pid_t = ProcessInfo.processInfo.processIdentifier) -> Bool
    {
        guard let bundleIdentifier, !bundleIdentifier.isEmpty else { return false }

        let runningApplications = NSRunningApplication
            .runningApplications(withBundleIdentifier: bundleIdentifier)
        let snapshots = runningApplications.map {
            RunningApplicationSnapshot(
                processIdentifier: $0.processIdentifier,
                bundleURL: $0.bundleURL,
                isTerminated: $0.isTerminated)
        }

        switch self.launchDecision(
            currentProcessIdentifier: currentProcessIdentifier,
            runningApplications: snapshots)
        {
        case .continueLaunch:
            return false

        case let .terminateCurrent(existingProcessIdentifier):
            CodexBarLog.logger(LogCategories.app).warning(
                "Terminating duplicate CodexBar instance",
                metadata: [
                    "existingPID": "\(existingProcessIdentifier)",
                    "currentPID": "\(currentProcessIdentifier)",
                ])
            NSApp.terminate(nil)
            return true
        }
    }
}
