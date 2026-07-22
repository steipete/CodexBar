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

    @Test
    func `auto mode cost defers to a selected token account`() {
        let settings = testSettingsStore(suiteName: "CursorTokenAccountSourceTests")
        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing,
            environmentBase: [:])
        settings.addTokenAccount(
            provider: .cursor,
            label: "Saved",
            token: "WorkosCursorSessionToken=saved")
        settings.setActiveTokenAccountIndex(0, for: .cursor)
        // The selected account carries the credential; the global manual
        // header stays empty, so only account-aware resolution can defer.
        #expect(settings.cursorCookieHeader.isEmpty)

        guard case let .proceed(header) = store.prepareCursorCostCookie(for: .cursor) else {
            Issue.record("expected cost to proceed with the selected account header")
            return
        }
        #expect(header == "WorkosCursorSessionToken=saved")
    }

    @Test
    func `cost stays off with the cookie ladder disabled and no app token path`() {
        let settings = testSettingsStore(suiteName: "CursorTokenAccountSourceTests")
        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing,
            environmentBase: [:])
        // Browser Cookies mode never consults the app token, so Off leaves no
        // session to fetch cost with regardless of the machine's Cursor app.
        settings.cursorUsageDataSource = .web
        settings.cursorCookieSource = .off

        guard case .skip = store.prepareCursorCostCookie(for: .cursor) else {
            Issue.record("expected cost to skip while the cookie source is Off")
            return
        }
    }
}
