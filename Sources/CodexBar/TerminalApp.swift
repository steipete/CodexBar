import AppKit

enum TerminalApp: String, CaseIterable, Identifiable {
    static let pickerIconSize = NSSize(width: 16, height: 16)

    case terminal
    case iTerm
    case ghostty
    /// Provider-specific by design: "warp" is a terminal app here, not the Warp usage provider.
    case warp

    var id: String {
        self.rawValue
    }

    var label: String {
        switch self {
        case .terminal: "Terminal"
        case .iTerm: "iTerm"
        case .ghostty: "Ghostty"
        case .warp: "Warp"
        }
    }

    var bundleIdentifier: String {
        switch self {
        case .terminal: "com.apple.Terminal"
        case .iTerm: "com.googlecode.iterm2"
        case .ghostty: "com.mitchellh.ghostty"
        case .warp: "dev.warp.Warp-Stable"
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

    func appleScript(command: String) -> String? {
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
        case .ghostty:
            // Requires Ghostty 1.3.0+ (first release with AppleScript support). `initial input`
            // runs the command in the user's shell and keeps the window open afterward, matching
            // the Terminal and iTerm behavior; older Ghostty fails here and falls back to Terminal.
            """
            tell application "Ghostty"
                activate
                new window with configuration {initial input:"\(escaped)" & linefeed}
            end tell
            """
        // Provider-specific by design: Warp's terminal app has no AppleScript launcher.
        case .warp:
            nil
        }
    }

    static func escapeForAppleScript(_ command: String) -> String {
        command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    static func warpTabConfig(name: String, command: String, directory: String) -> String {
        """
        name = "\(name)"

        [[panes]]
        id = "main"
        type = "terminal"
        directory = "\(self.escapeForTOML(directory))"
        commands = ["\(self.escapeForTOML(command))"]
        """
    }

    @MainActor
    static func launchWarp(command: String) async throws {
        let workspace = NSWorkspace.shared
        guard let schemeURL = URL(string: "warp://"),
              let applicationURL = workspace.urlForApplication(toOpen: schemeURL)
        else {
            throw NSError(
                domain: "TerminalApp",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Warp is not installed"])
        }

        let resolvedApplicationURL = applicationURL.resolvingSymlinksInPath().standardizedFileURL
        let isRunning = workspace.runningApplications.contains {
            $0.bundleURL?.resolvingSymlinksInPath().standardizedFileURL == resolvedApplicationURL
        }
        try await self.launchWarp(
            command: command,
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser,
            applicationURL: applicationURL,
            isRunning: isRunning,
            launchApplication: {
                let configuration = NSWorkspace.OpenConfiguration()
                configuration.activates = true
                _ = try await workspace.openApplication(at: $0, configuration: configuration)
            },
            openURL: { workspace.open($0) },
            sleep: { try await Task.sleep(for: $0) })
    }

    @MainActor
    // swiftlint:disable:next function_parameter_count
    static func launchWarp(
        command: String,
        homeDirectory: URL,
        applicationURL: URL,
        isRunning: Bool,
        launchApplication: (URL) async throws -> Void,
        openURL: (URL) -> Bool,
        sleep: (Duration) async throws -> Void) async throws
    {
        let name = "codexbar-\(UUID().uuidString.lowercased())"
        guard let deepLink = URL(string: "warp://tab_config/\(name)") else {
            throw NSError(domain: "TerminalApp", code: 2)
        }
        let configFile = homeDirectory
            .appendingPathComponent(".warp/tab_configs")
            .appendingPathComponent("\(name).toml")
        try FileManager.default.createDirectory(
            at: configFile.deletingLastPathComponent(),
            withIntermediateDirectories: true)

        do {
            try self.warpTabConfig(name: name, command: command, directory: homeDirectory.path)
                .write(to: configFile, atomically: true, encoding: .utf8)
            if !isRunning {
                try await launchApplication(applicationURL)
                try await sleep(.seconds(3))
            }
            guard openURL(deepLink) else {
                throw NSError(
                    domain: "TerminalApp",
                    code: 3,
                    userInfo: [NSLocalizedDescriptionKey: "Warp refused the tab config URL"])
            }
        } catch {
            try? FileManager.default.removeItem(at: configFile)
            throw error
        }

        Task.detached {
            try? await Task.sleep(for: .seconds(30))
            try? FileManager.default.removeItem(at: configFile)
        }
    }

    private static func escapeForTOML(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\t", with: "\\t")
    }
}
