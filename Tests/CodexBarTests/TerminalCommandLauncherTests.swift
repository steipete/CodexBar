import Foundation
import Testing
@testable import CodexBar

@MainActor
@Suite(.serialized)
struct TerminalCommandLauncherTests {
    @Test
    func `escapes commands for AppleScript strings`() {
        let escaped = TerminalCommandLauncher.escapeForAppleScript(#"echo "hi" && cd C:\tmp"#)

        #expect(escaped == #"echo \"hi\" && cd C:\\tmp"#)
    }

    @Test
    func `builds Terminal AppleScript`() {
        let script = TerminalCommandLauncher.appleScript(command: #"claude "hello""#, app: .terminal)

        #expect(script.contains(#"tell application "Terminal""#))
        #expect(script.contains(#"do script "claude \"hello\"""#))
    }

    @Test
    func `builds iTerm2 AppleScript`() {
        let script = TerminalCommandLauncher.appleScript(command: "claude", app: .iTerm2)

        #expect(script.contains(#"tell application "iTerm2""#))
        #expect(script.contains("create window with default profile"))
        #expect(script.contains(#"write text "claude""#))
    }

    @Test
    func `falls back to Terminal when preferred app is unavailable`() {
        var receivedScript: String?

        TerminalCommandLauncher.open(
            command: "claude",
            preferredApp: .iTerm2,
            applicationURL: { _ in nil },
            runAppleScript: { script in
                receivedScript = script
                return nil
            })

        #expect(receivedScript?.contains(#"tell application "Terminal""#) == true)
    }

    @Test
    func `lists only installed terminal apps`() {
        let apps = PreferredTerminalApp.availableApps { bundleID in
            bundleID == PreferredTerminalApp.iTerm2.bundleIdentifier
                ? URL(fileURLWithPath: "/Applications/iTerm.app")
                : nil
        }

        #expect(apps == [.iTerm2])
    }
}
