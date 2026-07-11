import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
@Suite("Codex session restore notifications")
struct CodexSessionQuotaFalseRestoreTests {
    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    @Test
    func `unchanged reset boundary suppresses restore and duplicate depletion`() {
        let boundary = self.start.addingTimeInterval(5 * 3600)
        let notifier = SessionQuotaNotifierSpy()
        let store = Self.makeStore(notifier: notifier)

        store.handleSessionQuotaTransition(
            provider: .codex,
            snapshot: self.snapshot(used: 20, resetBoundary: boundary, secondsAfterStart: 0))
        store.handleSessionQuotaTransition(
            provider: .codex,
            snapshot: self.snapshot(used: 100, resetBoundary: boundary, secondsAfterStart: 60))
        store.handleSessionQuotaTransition(
            provider: .codex,
            snapshot: self.snapshot(used: 0, resetBoundary: boundary, secondsAfterStart: 120))
        store.handleSessionQuotaTransition(
            provider: .codex,
            snapshot: self.snapshot(used: 100, resetBoundary: boundary, secondsAfterStart: 180))

        #expect(notifier.transitions == [.depleted])
    }

    @Test
    func `advanced reset boundary posts one restore`() {
        let boundary = self.start.addingTimeInterval(5 * 3600)
        let notifier = SessionQuotaNotifierSpy()
        let store = Self.makeStore(notifier: notifier)

        store.handleSessionQuotaTransition(
            provider: .codex,
            snapshot: self.snapshot(used: 20, resetBoundary: boundary, secondsAfterStart: 0))
        store.handleSessionQuotaTransition(
            provider: .codex,
            snapshot: self.snapshot(used: 100, resetBoundary: boundary, secondsAfterStart: 60))
        let reset = self.snapshot(
            used: 0,
            resetBoundary: boundary.addingTimeInterval(5 * 3600),
            secondsAfterStart: 180)
        store.handleSessionQuotaTransition(provider: .codex, snapshot: reset)
        store.handleSessionQuotaTransition(provider: .codex, snapshot: reset)

        #expect(notifier.transitions == [.depleted, .restored])
    }

    @Test
    func `missing reset boundary restores only after known boundary passes`() {
        let boundary = self.start.addingTimeInterval(5 * 3600)
        let notifier = SessionQuotaNotifierSpy()
        let store = Self.makeStore(notifier: notifier)

        store.handleSessionQuotaTransition(
            provider: .codex,
            snapshot: self.snapshot(used: 20, resetBoundary: boundary, secondsAfterStart: 0))
        store.handleSessionQuotaTransition(
            provider: .codex,
            snapshot: self.snapshot(used: 100, resetBoundary: boundary, secondsAfterStart: 60))
        store.handleSessionQuotaTransition(
            provider: .codex,
            snapshot: self.snapshot(used: 100, resetBoundary: nil, updatedAt: boundary.addingTimeInterval(-120)))
        store.handleSessionQuotaTransition(
            provider: .codex,
            snapshot: self.snapshot(used: 20, resetBoundary: nil, updatedAt: boundary.addingTimeInterval(-60)))
        #expect(notifier.transitions == [.depleted])

        store.handleSessionQuotaTransition(
            provider: .codex,
            snapshot: self.snapshot(used: 20, resetBoundary: nil, updatedAt: boundary.addingTimeInterval(60)))
        store.handleSessionQuotaTransition(
            provider: .codex,
            snapshot: self.snapshot(used: 30, resetBoundary: nil, updatedAt: boundary.addingTimeInterval(120)))

        #expect(notifier.transitions == [.depleted, .restored])
    }

    @Test
    func `unchanged stale reset boundary restores after known boundary passes`() {
        let boundary = self.start.addingTimeInterval(5 * 3600)
        let notifier = SessionQuotaNotifierSpy()
        let store = Self.makeStore(notifier: notifier)

        store.handleSessionQuotaTransition(
            provider: .codex,
            snapshot: self.snapshot(used: 20, resetBoundary: boundary, secondsAfterStart: 0))
        store.handleSessionQuotaTransition(
            provider: .codex,
            snapshot: self.snapshot(used: 100, resetBoundary: boundary, secondsAfterStart: 60))
        store.handleSessionQuotaTransition(
            provider: .codex,
            snapshot: self.snapshot(used: 20, resetBoundary: boundary, updatedAt: boundary.addingTimeInterval(60)))

        #expect(notifier.transitions == [.depleted, .restored])
    }

    @Test
    func `advanced boundary while depleted remains reset evidence`() {
        let boundary = self.start.addingTimeInterval(5 * 3600)
        let advancedBoundary = boundary.addingTimeInterval(5 * 3600)
        let notifier = SessionQuotaNotifierSpy()
        let store = Self.makeStore(notifier: notifier)

        store.handleSessionQuotaTransition(
            provider: .codex,
            snapshot: self.snapshot(used: 20, resetBoundary: boundary, secondsAfterStart: 0))
        store.handleSessionQuotaTransition(
            provider: .codex,
            snapshot: self.snapshot(used: 100, resetBoundary: boundary, secondsAfterStart: 60))
        store.handleSessionQuotaTransition(
            provider: .codex,
            snapshot: self.snapshot(used: 100, resetBoundary: advancedBoundary, secondsAfterStart: 120))
        #expect(store.lastKnownSessionResetBoundary[.codex] == boundary)
        store.handleSessionQuotaTransition(
            provider: .codex,
            snapshot: self.snapshot(used: 20, resetBoundary: advancedBoundary, secondsAfterStart: 180))

        #expect(notifier.transitions == [.depleted, .restored])
    }

    @Test
    func `regressed boundary while depleted does not create reset evidence`() {
        let boundary = self.start.addingTimeInterval(5 * 3600)
        let regressedBoundary = self.start
        let notifier = SessionQuotaNotifierSpy()
        let store = Self.makeStore(notifier: notifier)

        store.handleSessionQuotaTransition(
            provider: .codex,
            snapshot: self.snapshot(used: 20, resetBoundary: boundary, secondsAfterStart: 0))
        store.handleSessionQuotaTransition(
            provider: .codex,
            snapshot: self.snapshot(used: 100, resetBoundary: boundary, secondsAfterStart: 60))
        store.handleSessionQuotaTransition(
            provider: .codex,
            snapshot: self.snapshot(used: 100, resetBoundary: regressedBoundary, secondsAfterStart: 120))
        #expect(store.lastKnownSessionResetBoundary[.codex] == boundary)
        store.handleSessionQuotaTransition(
            provider: .codex,
            snapshot: self.snapshot(used: 20, resetBoundary: regressedBoundary, secondsAfterStart: 180))

        #expect(notifier.transitions == [.depleted])
    }

    @Test
    func `regressed boundary before depletion does not erase the trusted boundary`() {
        let boundary = self.start.addingTimeInterval(5 * 3600)
        let regressedBoundary = self.start.addingTimeInterval(10 * 60)
        let notifier = SessionQuotaNotifierSpy()
        let store = Self.makeStore(notifier: notifier)

        store.handleSessionQuotaTransition(
            provider: .codex,
            snapshot: self.snapshot(used: 20, resetBoundary: boundary, secondsAfterStart: 0))
        store.handleSessionQuotaTransition(
            provider: .codex,
            snapshot: self.snapshot(used: 30, resetBoundary: regressedBoundary, secondsAfterStart: 60))
        store.handleSessionQuotaTransition(
            provider: .codex,
            snapshot: self.snapshot(used: 100, resetBoundary: regressedBoundary, secondsAfterStart: 120))
        #expect(store.lastKnownSessionResetBoundary[.codex] == boundary)
        store.handleSessionQuotaTransition(
            provider: .codex,
            snapshot: self.snapshot(used: 20, resetBoundary: regressedBoundary, secondsAfterStart: 180))

        #expect(notifier.transitions == [.depleted])
    }

    @Test
    func `missing boundary before depletion does not erase the trusted boundary`() {
        let boundary = self.start.addingTimeInterval(5 * 3600)
        let notifier = SessionQuotaNotifierSpy()
        let store = Self.makeStore(notifier: notifier)

        store.handleSessionQuotaTransition(
            provider: .codex,
            snapshot: self.snapshot(used: 20, resetBoundary: boundary, secondsAfterStart: 0))
        store.handleSessionQuotaTransition(
            provider: .codex,
            snapshot: self.snapshot(used: 30, resetBoundary: nil, secondsAfterStart: 60))
        store.handleSessionQuotaTransition(
            provider: .codex,
            snapshot: self.snapshot(used: 100, resetBoundary: nil, secondsAfterStart: 120))
        #expect(store.lastKnownSessionResetBoundary[.codex] == boundary)
        store.handleSessionQuotaTransition(
            provider: .codex,
            snapshot: self.snapshot(used: 20, resetBoundary: nil, secondsAfterStart: 180))

        #expect(notifier.transitions == [.depleted])
    }

    @Test
    func `clearing published Codex usage clears the notification boundary`() {
        let boundary = self.start.addingTimeInterval(5 * 3600)
        let store = Self.makeStore(notifier: SessionQuotaNotifierSpy())

        store.handleSessionQuotaTransition(
            provider: .codex,
            snapshot: self.snapshot(used: 20, resetBoundary: boundary, secondsAfterStart: 0))
        #expect(store.lastKnownSessionResetBoundary[.codex] == boundary)

        store.clearCodexPublishedUsageState()

        #expect(store.lastKnownSessionRemaining[.codex] == nil)
        #expect(store.lastKnownSessionWindowSource[.codex] == nil)
        #expect(store.lastKnownSessionResetBoundary[.codex] == nil)
    }

    private func snapshot(
        used: Double,
        resetBoundary: Date?,
        secondsAfterStart: TimeInterval = 0,
        updatedAt: Date? = nil) -> UsageSnapshot
    {
        UsageSnapshot(
            primary: RateWindow(
                usedPercent: used,
                windowMinutes: 300,
                resetsAt: resetBoundary,
                resetDescription: nil),
            secondary: nil,
            updatedAt: updatedAt ?? self.start.addingTimeInterval(secondsAfterStart),
            identity: ProviderIdentitySnapshot(
                providerID: .codex,
                accountEmail: "codex-session-restore@example.com",
                accountOrganization: nil,
                loginMethod: "test"))
    }

    private static func makeStore(notifier: SessionQuotaNotifierSpy) -> UsageStore {
        let suiteName = "CodexSessionQuotaFalseRestoreTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let settings = SettingsStore(
            userDefaults: defaults,
            configStore: testConfigStore(suiteName: suiteName),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
        settings.refreshFrequency = .manual
        settings.statusChecksEnabled = false
        settings.sessionQuotaNotificationsEnabled = true
        return UsageStore(
            fetcher: UsageFetcher(),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            sessionQuotaNotifier: notifier)
    }
}

@MainActor
private final class SessionQuotaNotifierSpy: SessionQuotaNotifying {
    private(set) var transitions: [SessionQuotaTransition] = []

    func post(transition: SessionQuotaTransition, provider _: UsageProvider, badge _: NSNumber?) {
        self.transitions.append(transition)
    }

    func postQuotaWarning(
        event _: QuotaWarningEvent,
        provider _: UsageProvider,
        soundEnabled _: Bool,
        onScreenAlertEnabled _: Bool)
    {}
}
