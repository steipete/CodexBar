import AppKit
import CodexBarCore
import Foundation

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
        // Provider-specific by design: Warp's terminal app uses its URI scheme instead of AppleScript.
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
        WarpTerminalConfig.marker + """
        name = "\(self.escapeForTOML(name))"

        [[panes]]
        id = "main"
        type = "terminal"
        directory = "\(self.escapeForTOML(directory))"
        commands = ["\(self.escapeForTOML(command))"]
        """
    }

    static func escapeForTOML(_ value: String) -> String {
        var escaped = ""
        escaped.reserveCapacity(value.utf8.count)
        for scalar in value.unicodeScalars {
            switch scalar.value {
            case 0x08: escaped += "\\b"
            case 0x09: escaped += "\\t"
            case 0x0A: escaped += "\\n"
            case 0x0C: escaped += "\\f"
            case 0x0D: escaped += "\\r"
            case 0x22: escaped += "\\\""
            case 0x5C: escaped += "\\\\"
            case 0x00...0x1F, 0x7F:
                escaped += String(format: "\\u%04X", scalar.value)
            default:
                escaped.append(contentsOf: String(scalar))
            }
        }
        return escaped
    }
}

@MainActor
struct TerminalLauncher {
    enum Result: Equatable {
        case selected
        case fallback
        case failed
    }

    struct Dependencies {
        typealias ApplicationResolver = @MainActor (String) -> URL?
        typealias IdentifierGenerator = @MainActor () -> UUID
        typealias AppleScriptExecutor = @MainActor (String) -> Bool
        typealias URLOpener = @MainActor ([URL], URL, NSWorkspace.OpenConfiguration) async throws -> Void
        typealias CleanupAction = @MainActor () -> Void
        typealias CleanupScheduler = @MainActor (Duration, @escaping CleanupAction) -> Void

        let homeDirectory: URL
        let applicationURL: ApplicationResolver
        let identifier: IdentifierGenerator
        let executeAppleScript: AppleScriptExecutor
        let open: URLOpener
        let scheduleCleanup: CleanupScheduler

        static var live: Self {
            Self(
                homeDirectory: FileManager.default.homeDirectoryForCurrentUser,
                applicationURL: { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) },
                identifier: UUID.init,
                executeAppleScript: TerminalLauncher.executeAppleScript,
                open: { urls, applicationURL, configuration in
                    _ = try await NSWorkspace.shared.open(
                        urls,
                        withApplicationAt: applicationURL,
                        configuration: configuration)
                },
                scheduleCleanup: { delay, action in
                    Task { @MainActor in
                        try? await Task.sleep(for: delay)
                        action()
                    }
                })
        }
    }

    private let dependencies: Dependencies

    init(dependencies: Dependencies = .live) {
        self.dependencies = dependencies
    }

    func launch(_ selected: TerminalApp, command: String) async -> Result {
        if await self.launchOnce(selected, command: command) {
            return .selected
        }
        guard selected != .terminal else { return .failed }
        return await self.launchOnce(.terminal, command: command) ? .fallback : .failed
    }

    func cleanUpAbandonedConfigs(now: Date = Date(), includeRecent: Bool = true) {
        let directory = self.dependencies.homeDirectory.appendingPathComponent(".warp/tab_configs")
        for candidate in WarpTerminalConfig.candidates(in: directory) {
            let remaining = WarpTerminalConfig.lifetime - max(0, now.timeIntervalSince(candidate.modifiedAt))
            if remaining <= 0 {
                WarpTerminalConfig.remove(candidate)
            } else if includeRecent {
                // A quick restart must still give the receiving app time to read a fresh config.
                self.dependencies.scheduleCleanup(.seconds(remaining)) {
                    WarpTerminalConfig.remove(candidate)
                }
            }
        }
    }

    private func launchOnce(_ terminal: TerminalApp, command: String) async -> Bool {
        // Provider-specific by design: Warp terminal launches require app-targeted URI routing.
        if terminal == .warp {
            self.cleanUpAbandonedConfigs(includeRecent: false)
            guard let applicationURL = dependencies.applicationURL(terminal.bundleIdentifier) else {
                return false
            }
            return await self.launchWarp(command: command, applicationURL: applicationURL)
        }

        guard terminal == .terminal || self.dependencies.applicationURL(terminal.bundleIdentifier) != nil,
              let source = terminal.appleScript(command: command)
        else { return false }
        return self.dependencies.executeAppleScript(source)
    }

    private func launchWarp(command: String, applicationURL: URL) async -> Bool {
        // Provider-specific by design: this method owns Warp's external tab-config contract.
        let terminal = TerminalApp.warp
        let identifier = self.dependencies.identifier().uuidString
            .replacingOccurrences(of: "-", with: "")
            .lowercased()
        let stem = "codexbar_\(identifier)"
        let directoryURL = self.dependencies.homeDirectory.appendingPathComponent(
            ".warp/tab_configs",
            isDirectory: true)
        let configURL = directoryURL.appendingPathComponent("\(stem).toml")
        guard let launchURL = URL(string: "warp://tab_config/\(stem)") else { return false }

        let temporaryURL = directoryURL.appendingPathComponent(".\(stem).toml.tmp")
        do {
            try FileManager.default.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: NSNumber(value: 0o700)])
            let config = TerminalApp.warpTabConfig(
                name: stem,
                command: command,
                directory: self.dependencies.homeDirectory.path)
            try WarpTerminalConfig.write(Data(config.utf8), temporaryURL: temporaryURL, configURL: configURL)
        } catch {
            Self.logLaunchError(error, terminal: terminal)
            return false
        }

        guard let candidate = WarpTerminalConfig.candidate(at: configURL) else { return false }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.createsNewApplicationInstance = false
        configuration.allowsRunningApplicationSubstitution = false
        configuration.addsToRecentItems = false

        do {
            try await self.dependencies.open([launchURL], applicationURL, configuration)
            self.dependencies.scheduleCleanup(.seconds(WarpTerminalConfig.lifetime)) {
                WarpTerminalConfig.remove(candidate)
            }
            return true
        } catch {
            WarpTerminalConfig.remove(candidate)
            Self.logLaunchError(error, terminal: terminal)
            return false
        }
    }

    private static func executeAppleScript(_ source: String) -> Bool {
        guard let appleScript = NSAppleScript(source: source) else {
            CodexBarLog.logger(LogCategories.terminal).error("Failed to compile AppleScript")
            return false
        }
        var error: NSDictionary?
        appleScript.executeAndReturnError(&error)
        if let error {
            CodexBarLog.logger(LogCategories.terminal).error(
                "Failed to execute AppleScript",
                metadata: ["error": String(describing: error)])
            return false
        }
        return true
    }

    private static func logLaunchError(_ error: Error, terminal: TerminalApp) {
        CodexBarLog.logger(LogCategories.terminal).error(
            "Failed to launch terminal",
            metadata: [
                "terminal": terminal.rawValue,
                "error": String(describing: error),
            ])
    }
}
