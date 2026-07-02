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
        self.isInstalled { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }
    }

    func isInstalled(applicationURL: (String) -> URL?) -> Bool {
        self == .terminal || applicationURL(self.bundleIdentifier) != nil
    }

    var appIcon: NSImage? {
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: self.bundleIdentifier) else {
            return nil
        }
        return NSWorkspace.shared.icon(forFile: appURL.path)
    }

    static var installed: [Self] {
        self.installed { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }
    }

    static func installed(applicationURL: (String) -> URL?) -> [Self] {
        self.allCases.filter { $0.isInstalled(applicationURL: applicationURL) }
    }

    static func pickerOptions(selected: Self) -> [Self] {
        self.pickerOptions(selected: selected) { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }
    }

    static func pickerOptions(selected: Self, applicationURL: (String) -> URL?) -> [Self] {
        self.allCases.filter { $0 == selected || $0.isInstalled(applicationURL: applicationURL) }
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
