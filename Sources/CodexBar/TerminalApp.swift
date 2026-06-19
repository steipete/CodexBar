import AppKit

enum TerminalApp: String, CaseIterable, Identifiable {
    case terminal
    case iTerm

    var id: String {
        self.rawValue
    }

    var label: String {
        switch self {
        case .terminal: "Terminal"
        case .iTerm: "iTerm"
        }
    }

    var bundleIdentifier: String {
        switch self {
        case .terminal: "com.apple.Terminal"
        case .iTerm: "com.googlecode.iterm2"
        }
    }

    var isInstalled: Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: self.bundleIdentifier) != nil
    }

    func appleScript(command: String) -> String {
        let escaped = Self.escapeForAppleScript(command)
        return switch self {
        case .terminal:
            """
            tell application "Terminal"
                activate
                do script "\(escaped)"
            end tell
            """
        case .iTerm:
            """
            tell application "iTerm"
                activate
                set newWindow to (create window with default profile)
                tell current session of newWindow
                    write text "\(escaped)"
                end tell
            end tell
            """
        }
    }

    static func escapeForAppleScript(_ command: String) -> String {
        command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
