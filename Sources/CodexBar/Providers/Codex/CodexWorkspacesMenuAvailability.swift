import Foundation

enum CodexWorkspacesMenuAvailability {
    static let environmentKey = "CODEXBAR_ENABLE_WORKSPACES_MENU"

    static var isEnabledForCurrentProcess: Bool {
        self.isEnabled(environment: ProcessInfo.processInfo.environment)
    }

    static func isEnabled(environment: [String: String]) -> Bool {
        #if DEBUG
        return environment[self.environmentKey] == "1"
        #else
        _ = environment
        return false
        #endif
    }
}
