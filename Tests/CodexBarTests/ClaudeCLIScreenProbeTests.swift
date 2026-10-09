import Foundation
import Testing
@testable import CodexBarCore

struct ClaudeCLIScreenProbeTests {
    static func capture(_ name: String) throws -> String {
        let url = try #require(Bundle.module.url(
            forResource: name,
            withExtension: "ansi",
            subdirectory: "Fixtures/Providers/Claude"))
        return try String(contentsOf: url, encoding: .utf8)
    }

    @Test
    func `differential redraw preserves the scoped weekly quota and reset spacing`() throws {
        let text = try Self.capture("usage-pty-differential-redraw")
        #expect(TextParsing.stripANSICodes(text).contains("51%usd"))
        let snapshot = try ClaudeStatusProbe.parse(text: text)
        #expect(snapshot.sessionPercentLeft == 97)
        #expect(snapshot.weeklyPercentLeft == 73)
        #expect(snapshot.secondaryResetDescription == "Resets Sep 23 at 3pm (Europe/Stockholm)")
        let fable = try #require(snapshot.extraRateWindows.first { $0.id == "claude-weekly-scoped-fable" })
        #expect(fable.title == "Fable only")
        #expect(fable.window.usedPercent == 51)
    }

    @Test
    func `panel taller than fifty rows keeps the session quota on screen`() throws {
        let text = try Self.capture("usage-pty-2.1.294-tall-panel")
        let snapshot = try ClaudeStatusProbe.parse(text: text)
        #expect(snapshot.sessionPercentLeft == 93)
        #expect(snapshot.primaryResetDescription == "Resets 2:30pm (Europe/Malta)")
        #expect(snapshot.weeklyPercentLeft == 80)
        #expect(snapshot.secondaryResetDescription == "Resets Oct 14, 10pm (Europe/Malta)")
        let fable = try #require(snapshot.extraRateWindows.first { $0.id == "claude-weekly-scoped-fable" })
        #expect(fable.window.usedPercent == 2)
    }

    @Test
    func `identity uses the final status frame with cursor positioned spaces`() throws {
        let status = try Self.capture("status-pty-differential-redraw")
        let identity = ClaudeStatusProbe.parseIdentity(usageText: nil, statusText: status)
        #expect(identity.accountEmail == "fixture@example.com")
        #expect(identity.accountOrganization == "Example Org")
        #expect(identity.loginMethod == "Max")
        let usage = "Current session\n3% used"
        let snapshot = try ClaudeStatusProbe.parse(text: usage, statusText: status)
        #expect(snapshot.accountEmail == identity.accountEmail)
        #expect(snapshot.accountOrganization == identity.accountOrganization)
        #expect(snapshot.loginMethod == identity.loginMethod)
        #expect(snapshot.rawText == usage + status)
    }

    @Test
    func `styled plain reports preserve CR delimiters and ignore OSC contents`() throws {
        let title = "\u{1b}]0;\u{1b}[HCurrent session 99% used\u{7}"
        let text = title + "\u{1b}[35mCurrent session\u{1b}[0m\r3% used\r"
        let snapshot = try ClaudeStatusProbe.parse(text: text)
        #expect(snapshot.sessionPercentLeft == 97)
    }

    @Test
    func `styled plain reports are not clipped or wrapped to PTY geometry`() throws {
        let padding = String(repeating: "report detail\n", count: ClaudeCLIScreen.rows + 5)
        let organization = String(repeating: "Example", count: 30)
        let text = "\u{1b}[32mCurrent session\n3% used\n" + padding
            + "Org: \(organization)\nEmail: fixture@example.com\u{1b}[0m"
        let snapshot = try ClaudeStatusProbe.parse(text: text)
        #expect(snapshot.sessionPercentLeft == 97)
        #expect(snapshot.accountOrganization == organization)
        #expect(snapshot.accountEmail == "fixture@example.com")
    }
}
