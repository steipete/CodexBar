import AppKit

enum TerminalApp: String, CaseIterable, Identifiable {
    static let pickerIconSize = NSSize(width: 16, height: 16)

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

    var pickerIcon: NSImage? {
        self.appIcon.map(Self.pickerIcon(from:))
    }

    static func pickerIcon(from icon: NSImage) -> NSImage {
        let sourceSize = icon.size
        let targetSize = self.pickerIconSize

        guard sourceSize.width.isFinite, sourceSize.width > 0,
              sourceSize.height.isFinite, sourceSize.height > 0
        else {
            let empty = NSImage(size: targetSize)
            empty.isTemplate = icon.isTemplate
            return empty
        }

        // MenuPickerStyle sizes selected images from their intrinsic NSImage dimensions.
        let resized = NSImage(size: targetSize, flipped: false) { _ in
            let scale = min(targetSize.width / sourceSize.width, targetSize.height / sourceSize.height)
            let scaledSize = NSSize(width: sourceSize.width * scale, height: sourceSize.height * scale)
            let drawingRect = NSRect(
                x: (targetSize.width - scaledSize.width) / 2,
                y: (targetSize.height - scaledSize.height) / 2,
                width: scaledSize.width,
                height: scaledSize.height)
            NSGraphicsContext.current?.imageInterpolation = .high
            icon.draw(
                in: drawingRect,
                from: NSRect(origin: .zero, size: sourceSize),
                operation: .copy,
                fraction: 1)
            return true
        }
        resized.isTemplate = icon.isTemplate
        return resized
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
