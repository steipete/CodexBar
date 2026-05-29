import AppKit
import CodexBarCore
import Foundation

enum PreferredTerminalApp: String, CaseIterable, Identifiable, Sendable {
    case terminal
    case iTerm2 = "iterm2"

    var id: String {
        self.rawValue
    }

    var label: String {
        switch self {
        case .terminal: "Terminal"
        case .iTerm2: "iTerm2"
        }
    }

    var bundleIdentifier: String {
        switch self {
        case .terminal: "com.apple.Terminal"
        case .iTerm2: "com.googlecode.iterm2"
        }
    }

    @MainActor
    static func availableApps() -> [PreferredTerminalApp] {
        self.availableApps {
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0)
        }
    }

    static func availableApps(applicationURL: (String) -> URL?) -> [PreferredTerminalApp] {
        let installed = Self.allCases.filter { applicationURL($0.bundleIdentifier) != nil }
        return installed.isEmpty ? [.terminal] : installed
    }

    @MainActor
    static func resolved(_ preferred: PreferredTerminalApp) -> PreferredTerminalApp {
        self.resolved(preferred) {
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0)
        }
    }

    static func resolved(
        _ preferred: PreferredTerminalApp,
        applicationURL: (String) -> URL?)
        -> PreferredTerminalApp
    {
        applicationURL(preferred.bundleIdentifier) == nil ? .terminal : preferred
    }
}

@MainActor
enum TerminalCommandLauncher {
    static func open(command: String, preferredApp: PreferredTerminalApp) {
        self.open(
            command: command,
            preferredApp: preferredApp,
            applicationURL: {
                NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0)
            },
            runAppleScript: self.runAppleScript)
    }

    static func open(
        command: String,
        preferredApp: PreferredTerminalApp,
        applicationURL: (String) -> URL?,
        runAppleScript: (String) -> NSDictionary?)
    {
        let app = PreferredTerminalApp.resolved(preferredApp, applicationURL: applicationURL)
        let script = self.appleScript(command: command, app: app)
        if let error = runAppleScript(script) {
            CodexBarLog.logger(LogCategories.terminal).error(
                "Failed to open terminal",
                metadata: ["app": app.rawValue, "error": String(describing: error)])
        }
    }

    static func appleScript(command: String, app: PreferredTerminalApp) -> String {
        let escaped = self.escapeForAppleScript(command)
        switch app {
        case .terminal:
            """
            tell application "Terminal"
                activate
                do script "\(escaped)"
            end tell
            """
        case .iTerm2:
            """
            tell application "iTerm2"
                activate
                create window with default profile
                tell current session of current window
                    write text "\(escaped)"
                end tell
            end tell
            """
        }
    }

    nonisolated static func escapeForAppleScript(_ command: String) -> String {
        command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private static func runAppleScript(_ script: String) -> NSDictionary? {
        guard let appleScript = NSAppleScript(source: script) else { return nil }
        var error: NSDictionary?
        appleScript.executeAndReturnError(&error)
        return error
    }
}
