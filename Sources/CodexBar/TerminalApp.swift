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
}
