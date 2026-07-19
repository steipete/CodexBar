#if os(macOS)
import AppKit
import ApplicationServices
import Foundation

public enum SessionFocusResult: Equatable, Sendable {
    case focused
    case activatedApplicationOnly
    case failed
}

@MainActor
public enum SessionWindowFocuser {
    private static let knownBundleIdentifiers: Set<String> = [
        "com.mitchellh.ghostty",
        "com.googlecode.iterm2",
        "com.apple.Terminal",
        "dev.warp.Warp-Stable",
        "com.github.wez.wezterm",
        "net.kovidgoyal.kitty",
        "org.alacritty",
        "com.microsoft.VSCode",
        "com.todesktop.230313mzl4w4u92",
        "dev.zed.Zed",
        "com.anthropic.claudefordesktop",
    ]

    @discardableResult
    public static func focus(_ session: AgentSession, promptForAccessibility: Bool = true) -> SessionFocusResult {
        guard let application = self.application(for: session) else { return .failed }
        guard application.activate() else { return .failed }

        let trusted = AXIsProcessTrustedWithOptions(
            ["AXTrustedCheckOptionPrompt": promptForAccessibility] as CFDictionary)
        guard trusted else { return .activatedApplicationOnly }

        let appElement = AXUIElementCreateApplication(application.processIdentifier)
        var windowsValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsValue) == .success,
              let windows = windowsValue as? [AXUIElement],
              let window = self.preferredWindow(windows, session: session) ?? windows.first
        else { return .activatedApplicationOnly }
        AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        return .focused
    }

    private static func application(for session: AgentSession) -> NSRunningApplication? {
        if let pid = session.pid {
            var currentPID = pid
            var fallback: NSRunningApplication?
            var visited = Set<Int32>()
            while currentPID > 0, visited.insert(currentPID).inserted {
                if let application = NSRunningApplication(processIdentifier: currentPID) {
                    fallback = fallback ?? application
                    if let bundleIdentifier = application.bundleIdentifier,
                       self.knownBundleIdentifiers.contains(bundleIdentifier)
                    {
                        return application
                    }
                }
                guard let parent = self.parentPID(of: currentPID), parent != currentPID else { break }
                currentPID = parent
            }
            if let fallback {
                return fallback
            }
        }

        let bundleIdentifier: String? = switch (session.provider, session.source) {
        case (.claude, .desktopApp): "com.anthropic.claudefordesktop"
        case (.codex, .desktopApp): "com.openai.codex"
        default: nil
        }
        guard let bundleIdentifier else { return nil }
        return NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).first
    }

    private static func preferredWindow(_ windows: [AXUIElement], session: AgentSession) -> AXUIElement? {
        let candidates = [session.projectName, session.cwd.map { URL(fileURLWithPath: $0).lastPathComponent }]
            .compactMap { $0?.lowercased() }
            .filter { !$0.isEmpty }
        guard !candidates.isEmpty else { return nil }
        return windows.first { window in
            var titleValue: CFTypeRef?
            guard AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleValue) == .success,
                  let title = titleValue as? String
            else { return false }
            let lowercasedTitle = title.lowercased()
            return candidates.contains { lowercasedTitle.contains($0) }
        }
    }

    private static func parentPID(of pid: Int32) -> Int32? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-o", "ppid=", "-p", String(pid)]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8) else { return nil }
        return Int32(output.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
#endif
