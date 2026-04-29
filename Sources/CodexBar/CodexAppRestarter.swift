import AppKit
import Foundation

@MainActor
protocol CodexAppRestarting: Sendable {
    func stopRunningCodexAppsForAccountSwitch() async throws -> [URL]
    func relaunchCodexApps(at appURLs: [URL]) async
}

enum CodexAppRestartError: Error, Equatable {
    case couldNotTerminateRunningApp
}

@MainActor
struct DefaultCodexAppRestarter: CodexAppRestarting {
    func stopRunningCodexAppsForAccountSwitch() async throws -> [URL] {
        let applications = NSWorkspace.shared.runningApplications.filter(Self.isCodexDesktopApplication)
        guard !applications.isEmpty else { return [] }

        let appURLs = self.uniqueBundleURLs(from: applications)
        applications.forEach { $0.terminate() }

        if await self.waitUntilTerminated(applications) {
            return appURLs
        }

        applications
            .filter { !$0.isTerminated }
            .forEach { $0.forceTerminate() }

        guard await self.waitUntilTerminated(applications) else {
            throw CodexAppRestartError.couldNotTerminateRunningApp
        }

        return appURLs
    }

    func relaunchCodexApps(at appURLs: [URL]) async {
        for appURL in appURLs {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            do {
                try await NSWorkspace.shared.openApplication(at: appURL, configuration: configuration)
            } catch {
                _ = NSWorkspace.shared.open(appURL)
            }
        }
    }

    private func uniqueBundleURLs(from applications: [NSRunningApplication]) -> [URL] {
        var seen: Set<String> = []
        var urls: [URL] = []

        for application in applications {
            guard let bundleURL = application.bundleURL else { continue }
            let standardizedPath = bundleURL.standardizedFileURL.path
            guard seen.insert(standardizedPath).inserted else { continue }
            urls.append(bundleURL)
        }

        return urls
    }

    private func waitUntilTerminated(
        _ applications: [NSRunningApplication],
        timeout: TimeInterval = 5,
        pollInterval: TimeInterval = 0.1) async -> Bool
    {
        let deadline = Date().addingTimeInterval(timeout)

        while Date() < deadline {
            if applications.allSatisfy(\.isTerminated) {
                return true
            }

            try? await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
        }

        return applications.allSatisfy(\.isTerminated)
    }

    private static func isCodexDesktopApplication(_ application: NSRunningApplication) -> Bool {
        let localizedName = application.localizedName?.lowercased() ?? ""
        let bundleIdentifier = application.bundleIdentifier?.lowercased() ?? ""
        let bundleName = application.bundleURL?.lastPathComponent.lowercased() ?? ""

        if localizedName == "codexbar" ||
            bundleName == "codexbar.app" ||
            bundleIdentifier.contains("codexbar")
        {
            return false
        }

        return localizedName == "codex" ||
            bundleName == "codex.app" ||
            bundleIdentifier.hasSuffix(".codex") ||
            bundleIdentifier.contains(".codex.")
    }
}
