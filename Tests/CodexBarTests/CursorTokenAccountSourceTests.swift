import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

@MainActor
struct CursorTokenAccountSourceTests {
    @Test
    func `app token usage source deactivates saved cursor token accounts`() {
        let settings = testSettingsStore(suiteName: "CursorTokenAccountSourceTests")
        settings.addTokenAccount(
            provider: .cursor,
            label: "Saved",
            token: "WorkosCursorSessionToken=saved")
        settings.setActiveTokenAccountIndex(0, for: .cursor)

        #expect(settings.cursorCookieSource == .manual)
        #expect(settings.effectiveSelectedTokenAccount(for: .cursor) != nil)

        // App-token usage bypasses cookie auth; the saved account must not
        // own snapshots fetched with the Cursor app's credential.
        settings.cursorUsageDataSource = .app
        #expect(settings.effectiveSelectedTokenAccount(for: .cursor) == nil)

        settings.cursorUsageDataSource = .auto
        #expect(settings.effectiveSelectedTokenAccount(for: .cursor) != nil)
    }

    @Test
    func `selecting a token account leaves app token mode`() {
        let settings = testSettingsStore(suiteName: "CursorTokenAccountSourceTests")
        settings.cursorUsageDataSource = .app
        settings.addTokenAccount(
            provider: .cursor,
            label: "Saved",
            token: "WorkosCursorSessionToken=saved")
        settings.setActiveTokenAccountIndex(0, for: .cursor)

        #expect(settings.cursorUsageDataSource == .auto)
        #expect(settings.cursorCookieSource == .manual)
        #expect(settings.effectiveSelectedTokenAccount(for: .cursor) != nil)
    }
}
