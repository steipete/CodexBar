import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

/// Reproduces the Codex session false-restore OS notification bug.
///
/// Background (issue #2054):
/// Codex OAuth/CLI can briefly report `usedPercent = 0` while `resetsAt` is unchanged.
/// The celebration/confetti path (`postLimitResetCelebrationsIfNeeded`) already suppresses
/// this transient sample. Session OS notifications (`handleSessionQuotaTransition`) do not.
///
/// User-visible symptom:
/// - Correct: "Codex 会话额度已用尽" / "剩余 0%。可用时会通知你。" when quota is truly depleted.
/// - Bug:    "Codex 会话已恢复" / "会话额度已重新可用。" while quota has NOT actually reset yet.
///
/// This suite uses the same fixture shape as `UsageStorePlanUtilizationIssue2054ReproTests`.
@MainActor
@Suite("Codex session false-restore repro")
struct CodexSessionQuotaFalseRestoreReproTests {
    // MARK: - Shared fixture (mirrors issue #2054)

    private struct CodexSessionFixture {
        let accountLabel: String
        let firstDate: Date
        let sessionReset: Date
        let weeklyReset: Date

        init(labelSuffix: String) {
            self.accountLabel = "codex-false-restore-\(labelSuffix)@example.com"
            self.firstDate = Date(timeIntervalSince1970: 1_700_000_000)
            self.sessionReset = self.firstDate.addingTimeInterval(5 * 3600)
            self.weeklyReset = self.firstDate.addingTimeInterval(3 * 24 * 3600)
        }

        func snapshot(
            sessionUsed: Double,
            weeklyUsed: Double = 100,
            sessionReset: Date? = nil,
            omitSessionReset: Bool = false,
            updatedAt: Date? = nil) -> UsageSnapshot
        {
            let reset: Date? = omitSessionReset ? nil : (sessionReset ?? self.sessionReset)
            return UsageSnapshot(
                primary: RateWindow(
                    usedPercent: sessionUsed,
                    windowMinutes: 300,
                    resetsAt: reset,
                    resetDescription: nil),
                secondary: RateWindow(
                    usedPercent: weeklyUsed,
                    windowMinutes: 10080,
                    resetsAt: self.weeklyReset,
                    resetDescription: nil),
                updatedAt: updatedAt ?? self.firstDate,
                identity: ProviderIdentitySnapshot(
                    providerID: .codex,
                    accountEmail: self.accountLabel,
                    accountOrganization: nil,
                    loginMethod: "pro"))
        }
    }

    private static func makeSessionNotificationStore(notifier: SessionQuotaNotifierSpy) -> UsageStore {
        let suiteName = "CodexSessionQuotaFalseRestoreReproTests-\(UUID().uuidString)"
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

    // MARK: - A. Control: celebration path already fixed (#2054)

    @Test
    func `control celebration path suppresses codex session transient zero`() async {
        let fixture = CodexSessionFixture(labelSuffix: "celebration-control")
        let store = UsageStorePlanUtilizationTests.makeStore()
        let recorder = SessionLimitResetEventRecorder(provider: .codex, accountLabel: fixture.accountLabel)
        defer { recorder.invalidate() }

        let before = fixture.snapshot(sessionUsed: 67, updatedAt: fixture.firstDate)
        let transientZero = fixture.snapshot(
            sessionUsed: 0,
            updatedAt: fixture.firstDate.addingTimeInterval(120))

        #expect(before.primary?.resetsAt == transientZero.primary?.resetsAt)
        #expect(before.primary?.usedPercent == 67)
        #expect(transientZero.primary?.usedPercent == 0)

        await store.recordPlanUtilizationHistorySample(provider: .codex, snapshot: before, now: before.updatedAt)
        await store.recordPlanUtilizationHistorySample(
            provider: .codex,
            snapshot: transientZero,
            now: transientZero.updatedAt)

        #expect(recorder.events.isEmpty, "Celebration path must not fire when resetsAt is unchanged")
    }

    // MARK: - B. Fixed behavior: transient zero must not restore

    @Test
    func `session notification suppresses restored on codex transient zero`() {
        let fixture = CodexSessionFixture(labelSuffix: "session-fix")
        let notifier = SessionQuotaNotifierSpy()
        let store = Self.makeSessionNotificationStore(notifier: notifier)

        let baseline = fixture.snapshot(sessionUsed: 20)
        let depleted = fixture.snapshot(sessionUsed: 100, updatedAt: fixture.firstDate.addingTimeInterval(60))
        let transientZero = fixture.snapshot(sessionUsed: 0, updatedAt: fixture.firstDate.addingTimeInterval(120))

        #expect(depleted.primary?.resetsAt == transientZero.primary?.resetsAt)

        store.handleSessionQuotaTransition(provider: .codex, snapshot: baseline)
        store.handleSessionQuotaTransition(provider: .codex, snapshot: depleted)
        store.handleSessionQuotaTransition(provider: .codex, snapshot: transientZero)

        #expect(notifier.posts.map(\.transition) == [.depleted])
    }

    @Test
    func `api flicker depleted transient zero then depleted again posts once`() {
        let fixture = CodexSessionFixture(labelSuffix: "api-flicker")
        let notifier = SessionQuotaNotifierSpy()
        let store = Self.makeSessionNotificationStore(notifier: notifier)

        store.handleSessionQuotaTransition(provider: .codex, snapshot: fixture.snapshot(sessionUsed: 20))
        store.handleSessionQuotaTransition(
            provider: .codex,
            snapshot: fixture.snapshot(sessionUsed: 100, updatedAt: fixture.firstDate.addingTimeInterval(60)))
        store.handleSessionQuotaTransition(
            provider: .codex,
            snapshot: fixture.snapshot(sessionUsed: 0, updatedAt: fixture.firstDate.addingTimeInterval(120)))
        store.handleSessionQuotaTransition(
            provider: .codex,
            snapshot: fixture.snapshot(sessionUsed: 100, updatedAt: fixture.firstDate.addingTimeInterval(180)))

        // Transient restore is suppressed, so the later depleted sample does not re-notify.
        #expect(notifier.posts.map(\.transition) == [.depleted])
    }

    @Test
    func `depleted notification copy is the expected user facing message`() {
        CodexBarLocalizationOverride.$appLanguage.withValue("zh-Hans") {
            let depleted = SessionQuotaNotificationLogic.notificationCopy(
                transition: .depleted,
                providerName: "Codex")
            let restored = SessionQuotaNotificationLogic.notificationCopy(
                transition: .restored,
                providerName: "Codex")

            #expect(depleted.title == "Codex 会话额度已用尽")
            #expect(depleted.body == "剩余 0%。可用时会通知你。")
            #expect(restored.title == "Codex 会话已恢复")
            #expect(restored.body == "会话额度已重新可用。")
        }
    }

    // MARK: - C. Contract: correct behavior

    @Test
    func `contract session notification must not post restored on codex transient zero`() {
        let fixture = CodexSessionFixture(labelSuffix: "session-contract")
        let notifier = SessionQuotaNotifierSpy()
        let store = Self.makeSessionNotificationStore(notifier: notifier)

        store.handleSessionQuotaTransition(provider: .codex, snapshot: fixture.snapshot(sessionUsed: 20))
        store.handleSessionQuotaTransition(
            provider: .codex,
            snapshot: fixture.snapshot(sessionUsed: 100, updatedAt: fixture.firstDate.addingTimeInterval(60)))
        store.handleSessionQuotaTransition(
            provider: .codex,
            snapshot: fixture.snapshot(sessionUsed: 0, updatedAt: fixture.firstDate.addingTimeInterval(120)))

        #expect(notifier.posts.map(\.transition) == [.depleted])
        #expect(notifier.posts.filter { $0.transition == .restored }.isEmpty)
    }

    @Test
    func `contract real session reset with advanced resetsAt should still notify restored`() {
        let fixture = CodexSessionFixture(labelSuffix: "real-reset")
        let notifier = SessionQuotaNotifierSpy()
        let store = Self.makeSessionNotificationStore(notifier: notifier)

        let advancedSessionReset = fixture.sessionReset.addingTimeInterval(5 * 3600)

        store.handleSessionQuotaTransition(provider: .codex, snapshot: fixture.snapshot(sessionUsed: 20))
        store.handleSessionQuotaTransition(
            provider: .codex,
            snapshot: fixture.snapshot(sessionUsed: 100, updatedAt: fixture.firstDate.addingTimeInterval(60)))

        let realReset = UsageSnapshot(
            primary: RateWindow(
                usedPercent: 0,
                windowMinutes: 300,
                resetsAt: advancedSessionReset,
                resetDescription: nil),
            secondary: RateWindow(
                usedPercent: 100,
                windowMinutes: 10080,
                resetsAt: fixture.weeklyReset,
                resetDescription: nil),
            updatedAt: fixture.firstDate.addingTimeInterval(180),
            identity: ProviderIdentitySnapshot(
                providerID: .codex,
                accountEmail: fixture.accountLabel,
                accountOrganization: nil,
                loginMethod: "pro"))

        store.handleSessionQuotaTransition(provider: .codex, snapshot: realReset)

        #expect(notifier.posts.map(\.transition) == [.depleted, .restored])
    }

    @Test
    func `contract fallback without resetsAt restores after known boundary elapsed`() {
        let fixture = CodexSessionFixture(labelSuffix: "fallback-nil-boundary")
        let notifier = SessionQuotaNotifierSpy()
        let store = Self.makeSessionNotificationStore(notifier: notifier)

        store.handleSessionQuotaTransition(provider: .codex, snapshot: fixture.snapshot(sessionUsed: 20))
        store.handleSessionQuotaTransition(
            provider: .codex,
            snapshot: fixture.snapshot(sessionUsed: 100, updatedAt: fixture.firstDate.addingTimeInterval(60)))

        let beforeBoundary = fixture.snapshot(
            sessionUsed: 20,
            omitSessionReset: true,
            updatedAt: fixture.sessionReset.addingTimeInterval(-60))
        store.handleSessionQuotaTransition(provider: .codex, snapshot: beforeBoundary)
        #expect(notifier.posts.map(\.transition) == [.depleted])

        let afterBoundary = fixture.snapshot(
            sessionUsed: 20,
            omitSessionReset: true,
            updatedAt: fixture.sessionReset.addingTimeInterval(60))
        store.handleSessionQuotaTransition(provider: .codex, snapshot: afterBoundary)
        store.handleSessionQuotaTransition(
            provider: .codex,
            snapshot: fixture.snapshot(
                sessionUsed: 30,
                omitSessionReset: true,
                updatedAt: fixture.sessionReset.addingTimeInterval(120)))

        #expect(notifier.posts.map(\.transition) == [.depleted, .restored])
    }

    @Test
    func `contract true depletion while working still posts depleted once`() {
        let fixture = CodexSessionFixture(labelSuffix: "true-depletion")
        let notifier = SessionQuotaNotifierSpy()
        let store = Self.makeSessionNotificationStore(notifier: notifier)

        store.handleSessionQuotaTransition(provider: .codex, snapshot: fixture.snapshot(sessionUsed: 20))
        store.handleSessionQuotaTransition(
            provider: .codex,
            snapshot: fixture.snapshot(sessionUsed: 50, updatedAt: fixture.firstDate.addingTimeInterval(30)))
        store.handleSessionQuotaTransition(
            provider: .codex,
            snapshot: fixture.snapshot(sessionUsed: 100, updatedAt: fixture.firstDate.addingTimeInterval(60)))

        #expect(notifier.posts.map(\.transition) == [.depleted])
    }

    // MARK: - D. Live proof (real Codex sessionResetsAt from CodexBarCLI)

    @Test(.enabled(if: ProcessInfo.processInfo
            .environment["CODEXBAR_VERIFY_SESSION_FALSE_RESTORE_LIVE_FIXTURE"] != nil))
    func `live proof session notification false restores with real codex session resetsAt`() async throws {
        let fixturePath = try #require(
            ProcessInfo.processInfo.environment["CODEXBAR_VERIFY_SESSION_FALSE_RESTORE_LIVE_FIXTURE"])
        let fixtureURL = URL(fileURLWithPath: fixturePath)
        let fixtureData = try Data(contentsOf: fixtureURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let payloads = try decoder.decode([LiveCodexUsagePayload].self, from: fixtureData)
        let payload = try #require(payloads.first)
        let liveSnapshot = try #require(payload.usage)
        let sessionReset = try #require(liveSnapshot.primary?.resetsAt)
        let weeklyReset = liveSnapshot.secondary?.resetsAt
            ?? sessionReset.addingTimeInterval(7 * 24 * 3600)
        let liveSessionUsed = liveSnapshot.primary?.usedPercent ?? -1
        let liveWeeklyUsed = liveSnapshot.secondary?.usedPercent ?? -1
        let loginMethod = liveSnapshot.identity?.loginMethod ?? "live"

        print(
            "[verify-session-false-restore] PROOF_LIVE_FETCH " +
                "sessionUsed=\(liveSessionUsed) " +
                "sessionResetsAt=\(Self.proofTimestamp(sessionReset)) " +
                "weeklyUsed=\(liveWeeklyUsed) " +
                "weeklyResetsAt=\(Self.proofTimestamp(weeklyReset)) " +
                "loginMethod=\(loginMethod) " +
                "account=<redacted-email>")

        try await Self.runLiveCelebrationControlProof(
            sessionReset: sessionReset,
            weeklyReset: weeklyReset,
            loginMethod: loginMethod)

        try Self.runLiveSessionNotificationFalseRestoreProof(
            sessionReset: sessionReset,
            weeklyReset: weeklyReset,
            liveSessionUsed: liveSessionUsed,
            loginMethod: loginMethod)
    }

    private static func runLiveCelebrationControlProof(
        sessionReset: Date,
        weeklyReset: Date,
        loginMethod: String) async throws
    {
        let store = UsageStorePlanUtilizationTests.makeStore()
        let accountLabel = "live-session-false-restore@example.com"
        let recorder = SessionLimitResetEventRecorder(provider: .codex, accountLabel: accountLabel)
        defer { recorder.invalidate() }

        let firstDate = sessionReset.addingTimeInterval(-2 * 3600)
        let before = Self.liveProofSnapshot(
            LiveSessionProofInput(
                accountLabel: accountLabel,
                loginMethod: loginMethod,
                sessionUsed: 67,
                sessionReset: sessionReset,
                weeklyUsed: 100,
                weeklyReset: weeklyReset,
                updatedAt: firstDate))
        let transientZero = Self.liveProofSnapshot(
            LiveSessionProofInput(
                accountLabel: accountLabel,
                loginMethod: loginMethod,
                sessionUsed: 0,
                sessionReset: sessionReset,
                weeklyUsed: 100,
                weeklyReset: weeklyReset,
                updatedAt: firstDate.addingTimeInterval(120)))

        #expect(before.primary?.resetsAt == transientZero.primary?.resetsAt)

        await store.recordPlanUtilizationHistorySample(provider: .codex, snapshot: before, now: before.updatedAt)
        await store.recordPlanUtilizationHistorySample(
            provider: .codex,
            snapshot: transientZero,
            now: transientZero.updatedAt)

        #expect(recorder.events.isEmpty)
        print(
            "[verify-session-false-restore] PROOF_CELEBRATION_SUPPRESSED_TRANSIENT_ZERO " +
                "events=\(recorder.events.count) " +
                "sessionResetsAt=\(Self.proofTimestamp(sessionReset))")
    }

    private static func runLiveSessionNotificationFalseRestoreProof(
        sessionReset: Date,
        weeklyReset: Date,
        liveSessionUsed: Double,
        loginMethod: String) throws
    {
        let accountLabel = "live-session-false-restore@example.com"
        let weeklyUsed = liveSessionUsed > 0 ? min(liveSessionUsed, 100) : 22
        let notifier = SessionQuotaNotifierSpy()
        let store = Self.makeSessionNotificationStore(notifier: notifier)

        let firstDate = sessionReset.addingTimeInterval(-2 * 3600)
        let baseline = Self.liveProofSnapshot(
            LiveSessionProofInput(
                accountLabel: accountLabel,
                loginMethod: loginMethod,
                sessionUsed: 20,
                sessionReset: sessionReset,
                weeklyUsed: weeklyUsed,
                weeklyReset: weeklyReset,
                updatedAt: firstDate))
        let depleted = Self.liveProofSnapshot(
            LiveSessionProofInput(
                accountLabel: accountLabel,
                loginMethod: loginMethod,
                sessionUsed: 100,
                sessionReset: sessionReset,
                weeklyUsed: weeklyUsed,
                weeklyReset: weeklyReset,
                updatedAt: firstDate.addingTimeInterval(60)))
        let transientZero = Self.liveProofSnapshot(
            LiveSessionProofInput(
                accountLabel: accountLabel,
                loginMethod: loginMethod,
                sessionUsed: 0,
                sessionReset: sessionReset,
                weeklyUsed: weeklyUsed,
                weeklyReset: weeklyReset,
                updatedAt: firstDate.addingTimeInterval(120)))

        #expect(depleted.primary?.resetsAt == transientZero.primary?.resetsAt)
        #expect(depleted.primary?.resetsAt == sessionReset)

        store.handleSessionQuotaTransition(provider: .codex, snapshot: baseline)
        store.handleSessionQuotaTransition(provider: .codex, snapshot: depleted)
        store.handleSessionQuotaTransition(provider: .codex, snapshot: transientZero)

        let transitions = notifier.posts.map(\.transition)
        #expect(transitions == [.depleted])
        print(
            "[verify-session-false-restore] PROOF_SESSION_NOTIFICATION_SUPPRESSED_TRANSIENT_ZERO " +
                "transitions=\(transitions.map { String(describing: $0) }.joined(separator: ",")) " +
                "sessionResetsAt=\(Self.proofTimestamp(sessionReset)) " +
                "liveSessionUsedAtFetch=\(liveSessionUsed)")

        let notifierFlicker = SessionQuotaNotifierSpy()
        let flickerStore = Self.makeSessionNotificationStore(notifier: notifierFlicker)
        flickerStore.handleSessionQuotaTransition(provider: .codex, snapshot: baseline)
        flickerStore.handleSessionQuotaTransition(provider: .codex, snapshot: depleted)
        flickerStore.handleSessionQuotaTransition(provider: .codex, snapshot: transientZero)
        flickerStore.handleSessionQuotaTransition(
            provider: .codex,
            snapshot: Self.liveProofSnapshot(
                LiveSessionProofInput(
                    accountLabel: accountLabel,
                    loginMethod: loginMethod,
                    sessionUsed: 100,
                    sessionReset: sessionReset,
                    weeklyUsed: weeklyUsed,
                    weeklyReset: weeklyReset,
                    updatedAt: firstDate.addingTimeInterval(180))))

        let flickerTransitions = notifierFlicker.posts.map(\.transition)
        #expect(flickerTransitions == [.depleted])
        print(
            "[verify-session-false-restore] PROOF_API_FLICKER_SUPPRESSED " +
                "transitions=\(flickerTransitions.map { String(describing: $0) }.joined(separator: ","))")
    }

    private struct LiveSessionProofInput {
        let accountLabel: String
        let loginMethod: String
        let sessionUsed: Double
        let sessionReset: Date
        let weeklyUsed: Double
        let weeklyReset: Date
        let updatedAt: Date
    }

    private static func liveProofSnapshot(_ input: LiveSessionProofInput) -> UsageSnapshot {
        UsageSnapshot(
            primary: RateWindow(
                usedPercent: input.sessionUsed,
                windowMinutes: 300,
                resetsAt: input.sessionReset,
                resetDescription: nil),
            secondary: RateWindow(
                usedPercent: input.weeklyUsed,
                windowMinutes: 10080,
                resetsAt: input.weeklyReset,
                resetDescription: nil),
            updatedAt: input.updatedAt,
            identity: ProviderIdentitySnapshot(
                providerID: .codex,
                accountEmail: input.accountLabel,
                accountOrganization: nil,
                loginMethod: input.loginMethod))
    }

    private static func proofTimestamp(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }
}

private struct LiveCodexUsagePayload: Decodable {
    let provider: String?
    let account: String?
    let source: String?
    let usage: UsageSnapshot?
}

@MainActor
private final class SessionQuotaNotifierSpy: SessionQuotaNotifying {
    private(set) var posts: [(transition: SessionQuotaTransition, provider: UsageProvider)] = []

    func post(transition: SessionQuotaTransition, provider: UsageProvider, badge _: NSNumber?) {
        self.posts.append((transition: transition, provider: provider))
    }

    func postQuotaWarning(
        event _: QuotaWarningEvent,
        provider _: UsageProvider,
        soundEnabled _: Bool,
        onScreenAlertEnabled _: Bool)
    {}
}

private final class SessionLimitResetEventRecorder: @unchecked Sendable {
    struct Event {
        let provider: UsageProvider
        let accountLabel: String?
        let usedPercent: Double
    }

    private let provider: UsageProvider
    private let accountLabel: String?
    private let lock = NSLock()
    private var observedEvents: [Event] = []
    private var token: NSObjectProtocol?

    init(provider: UsageProvider, accountLabel: String?) {
        self.provider = provider
        self.accountLabel = accountLabel
        self.token = NotificationCenter.default.addObserver(
            forName: .codexbarSessionLimitReset,
            object: nil,
            queue: nil)
        { [weak self] notification in
            guard let self,
                  let event = notification.object as? SessionLimitResetEvent
            else {
                return
            }

            let recorded = MainActor.assumeIsolated { () -> Event? in
                guard event.provider == self.provider,
                      event.accountLabel == self.accountLabel
                else {
                    return nil
                }
                return Event(
                    provider: event.provider,
                    accountLabel: event.accountLabel,
                    usedPercent: event.usedPercent)
            }
            guard let recorded else { return }

            self.lock.lock()
            self.observedEvents.append(recorded)
            self.lock.unlock()
        }
    }

    var events: [Event] {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.observedEvents
    }

    func invalidate() {
        guard let token else { return }
        NotificationCenter.default.removeObserver(token)
        self.token = nil
    }

    deinit {
        self.invalidate()
    }
}
