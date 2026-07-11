import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

// Regression coverage for https://github.com/steipete/CodexBar/issues/2054
extension UsageStorePlanUtilizationTests {
    @MainActor
    @Test
    func `issue 2054 weekly confetti ignores transient zero when resetsAt unchanged`() async {
        let store = Self.makeStore()
        let accountLabel = "issue-2054-weekly-transient-zero@example.com"
        let recorder = WeeklyLimitResetEventRecorder(provider: .codex, accountLabel: accountLabel)
        defer { recorder.invalidate() }

        let firstDate = Date(timeIntervalSince1970: 1_700_000_000)
        let sessionReset = firstDate.addingTimeInterval(5 * 3600)
        let weeklyReset = firstDate.addingTimeInterval(3 * 24 * 3600)

        func snapshot(weeklyUsed: Double, updatedAt: Date) -> UsageSnapshot {
            UsageSnapshot(
                primary: RateWindow(
                    usedPercent: 14,
                    windowMinutes: 300,
                    resetsAt: sessionReset,
                    resetDescription: nil),
                secondary: RateWindow(
                    usedPercent: weeklyUsed,
                    windowMinutes: 10080,
                    resetsAt: weeklyReset,
                    resetDescription: nil),
                updatedAt: updatedAt,
                identity: ProviderIdentitySnapshot(
                    providerID: .codex,
                    accountEmail: accountLabel,
                    accountOrganization: nil,
                    loginMethod: "pro"))
        }

        let before = snapshot(weeklyUsed: 86, updatedAt: firstDate)
        let transientZero = snapshot(weeklyUsed: 0, updatedAt: firstDate.addingTimeInterval(120))

        await store.recordPlanUtilizationHistorySample(provider: .codex, snapshot: before, now: before.updatedAt)
        await store.recordPlanUtilizationHistorySample(
            provider: .codex,
            snapshot: transientZero,
            now: transientZero.updatedAt)

        #expect(recorder.events.isEmpty)
    }

    @MainActor
    @Test
    func `issue 2054 session path suppresses same transient zero`() async {
        let store = Self.makeStore()
        let accountLabel = "issue-2054-session-transient-zero@example.com"
        let recorder = SessionLimitResetEventRecorder(provider: .codex, accountLabel: accountLabel)
        defer { recorder.invalidate() }

        let firstDate = Date(timeIntervalSince1970: 1_700_000_000)
        let sessionReset = firstDate.addingTimeInterval(5 * 3600)
        let weeklyReset = firstDate.addingTimeInterval(3 * 24 * 3600)

        func snapshot(sessionUsed: Double, updatedAt: Date) -> UsageSnapshot {
            UsageSnapshot(
                primary: RateWindow(
                    usedPercent: sessionUsed,
                    windowMinutes: 300,
                    resetsAt: sessionReset,
                    resetDescription: nil),
                secondary: RateWindow(
                    usedPercent: 100,
                    windowMinutes: 10080,
                    resetsAt: weeklyReset,
                    resetDescription: nil),
                updatedAt: updatedAt,
                identity: ProviderIdentitySnapshot(
                    providerID: .codex,
                    accountEmail: accountLabel,
                    accountOrganization: nil,
                    loginMethod: "pro"))
        }

        let before = snapshot(sessionUsed: 67, updatedAt: firstDate)
        let transientZero = snapshot(sessionUsed: 0, updatedAt: firstDate.addingTimeInterval(120))

        await store.recordPlanUtilizationHistorySample(provider: .codex, snapshot: before, now: before.updatedAt)
        await store.recordPlanUtilizationHistorySample(
            provider: .codex,
            snapshot: transientZero,
            now: transientZero.updatedAt)

        #expect(recorder.events.isEmpty)
    }

    @MainActor
    @Test
    func `issue 2054 live upstream weekly drop same boundary does not celebrate`() async {
        let store = Self.makeStore()
        let accountLabel = "issue-2054-live-upstream@example.com"
        let recorder = WeeklyLimitResetEventRecorder(provider: .codex, accountLabel: accountLabel)
        defer { recorder.invalidate() }

        let firstDate = Date(timeIntervalSince1970: 1_700_000_000)
        let sessionReset = firstDate.addingTimeInterval(5 * 3600)
        let weeklyReset = firstDate.addingTimeInterval(3 * 24 * 3600)

        func snapshot(weeklyUsed: Double, updatedAt: Date) -> UsageSnapshot {
            UsageSnapshot(
                primary: RateWindow(
                    usedPercent: 14,
                    windowMinutes: 300,
                    resetsAt: sessionReset,
                    resetDescription: nil),
                secondary: RateWindow(
                    usedPercent: weeklyUsed,
                    windowMinutes: 10080,
                    resetsAt: weeklyReset,
                    resetDescription: nil),
                updatedAt: updatedAt,
                identity: ProviderIdentitySnapshot(
                    providerID: .codex,
                    accountEmail: accountLabel,
                    accountOrganization: nil,
                    loginMethod: "pro"))
        }

        let before = snapshot(weeklyUsed: 5, updatedAt: firstDate)
        let after = snapshot(weeklyUsed: 1, updatedAt: firstDate.addingTimeInterval(120))

        await store.recordPlanUtilizationHistorySample(provider: .codex, snapshot: before, now: before.updatedAt)
        await store.recordPlanUtilizationHistorySample(provider: .codex, snapshot: after, now: after.updatedAt)

        #expect(recorder.events.isEmpty)
    }

    @MainActor
    @Test
    func `issue 2054 real weekly reset with advanced boundary still posts once`() async {
        let store = Self.makeStore()
        let accountLabel = "issue-2054-real-weekly-reset@example.com"
        let recorder = WeeklyLimitResetEventRecorder(provider: .codex, accountLabel: accountLabel)
        defer { recorder.invalidate() }

        let firstDate = Date(timeIntervalSince1970: 1_700_000_000)
        let sessionReset = firstDate.addingTimeInterval(5 * 3600)
        let weeklyReset = firstDate.addingTimeInterval(3 * 24 * 3600)

        func snapshot(weeklyUsed: Double, weeklyReset: Date, updatedAt: Date) -> UsageSnapshot {
            UsageSnapshot(
                primary: RateWindow(
                    usedPercent: 14,
                    windowMinutes: 300,
                    resetsAt: sessionReset,
                    resetDescription: nil),
                secondary: RateWindow(
                    usedPercent: weeklyUsed,
                    windowMinutes: 10080,
                    resetsAt: weeklyReset,
                    resetDescription: nil),
                updatedAt: updatedAt,
                identity: ProviderIdentitySnapshot(
                    providerID: .codex,
                    accountEmail: accountLabel,
                    accountOrganization: nil,
                    loginMethod: "pro"))
        }

        let before = snapshot(weeklyUsed: 86, weeklyReset: weeklyReset, updatedAt: firstDate)
        let transientZero = snapshot(
            weeklyUsed: 0,
            weeklyReset: weeklyReset,
            updatedAt: firstDate.addingTimeInterval(120))
        let realReset = snapshot(
            weeklyUsed: 0,
            weeklyReset: weeklyReset.addingTimeInterval(7 * 24 * 3600),
            updatedAt: firstDate.addingTimeInterval(180))

        await store.recordPlanUtilizationHistorySample(provider: .codex, snapshot: before, now: before.updatedAt)
        await store.recordPlanUtilizationHistorySample(
            provider: .codex,
            snapshot: transientZero,
            now: transientZero.updatedAt)
        await store.recordPlanUtilizationHistorySample(
            provider: .codex,
            snapshot: realReset,
            now: realReset.updatedAt)

        #expect(recorder.events.count == 1)
        #expect(recorder.events.first?.usedPercent == 0)
    }

    @MainActor
    @Test
    func `issue 2054 same email different workspaces do not cross celebrate without token account`() async {
        let store = Self.makeStore()
        let sharedEmail = "issue-2054-shared-email@example.com"
        let recorder = WeeklyLimitResetEventRecorder(provider: .codex, accountLabel: sharedEmail)
        defer { recorder.invalidate() }

        let firstDate = Date(timeIntervalSince1970: 1_700_000_000)
        let sessionReset = firstDate.addingTimeInterval(5 * 3600)
        let weeklyReset = firstDate.addingTimeInterval(3 * 24 * 3600)

        func snapshot(
            organization: String,
            weeklyUsed: Double,
            updatedAt: Date) -> UsageSnapshot
        {
            UsageSnapshot(
                primary: RateWindow(
                    usedPercent: 14,
                    windowMinutes: 300,
                    resetsAt: sessionReset,
                    resetDescription: nil),
                secondary: RateWindow(
                    usedPercent: weeklyUsed,
                    windowMinutes: 10080,
                    resetsAt: weeklyReset,
                    resetDescription: nil),
                updatedAt: updatedAt,
                identity: ProviderIdentitySnapshot(
                    providerID: .codex,
                    accountEmail: sharedEmail,
                    accountOrganization: organization,
                    loginMethod: "pro"))
        }

        let workspaceAHigh = snapshot(
            organization: "Workspace Alpha",
            weeklyUsed: 86,
            updatedAt: firstDate)
        let workspaceBZero = snapshot(
            organization: "Workspace Beta",
            weeklyUsed: 0,
            updatedAt: firstDate.addingTimeInterval(120))

        await store.recordPlanUtilizationHistorySample(
            provider: .codex,
            snapshot: workspaceAHigh,
            now: workspaceAHigh.updatedAt)
        await store.recordPlanUtilizationHistorySample(
            provider: .codex,
            snapshot: workspaceBZero,
            now: workspaceBZero.updatedAt)

        #expect(recorder.events.isEmpty)
        #expect(store.weeklyLimitResetDetectorStates.count == 2)
    }

    @MainActor
    @Test
    func `issue 2054 distinct token account UUIDs keep detector isolated`() async throws {
        let store = Self.makeStore()
        let accountAUUID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let accountBUUID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        let accountA = ProviderTokenAccount(
            id: accountAUUID,
            label: "issue-2054-token-a@example.com",
            token: "token-a",
            addedAt: 0,
            lastUsed: nil)
        let accountB = ProviderTokenAccount(
            id: accountBUUID,
            label: "issue-2054-token-b@example.com",
            token: "token-b",
            addedAt: 0,
            lastUsed: nil)
        store.settings.updateProviderConfig(provider: .claude) { entry in
            entry.tokenAccounts = ProviderTokenAccountData(
                version: 1,
                accounts: [accountA, accountB],
                activeIndex: 0)
        }

        let recorderB = WeeklyLimitResetEventRecorder(provider: .claude, accountLabel: accountB.label)
        defer { recorderB.invalidate() }

        let firstDate = Date(timeIntervalSince1970: 1_700_000_000)
        let weeklyReset = firstDate.addingTimeInterval(3 * 24 * 3600)

        func snapshot(
            email: String,
            weeklyUsed: Double,
            updatedAt: Date) -> UsageSnapshot
        {
            UsageSnapshot(
                primary: RateWindow(usedPercent: 10, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
                secondary: RateWindow(
                    usedPercent: weeklyUsed,
                    windowMinutes: 10080,
                    resetsAt: weeklyReset,
                    resetDescription: nil),
                updatedAt: updatedAt,
                identity: ProviderIdentitySnapshot(
                    providerID: .claude,
                    accountEmail: email,
                    accountOrganization: nil,
                    loginMethod: "max"))
        }

        let accountAHigh = snapshot(
            email: "shared-claude-email@example.com",
            weeklyUsed: 86,
            updatedAt: firstDate)
        let accountBZero = snapshot(
            email: "shared-claude-email@example.com",
            weeklyUsed: 0,
            updatedAt: firstDate.addingTimeInterval(120))

        await store.recordPlanUtilizationHistorySample(
            provider: .claude,
            snapshot: accountAHigh,
            account: accountA,
            now: accountAHigh.updatedAt)
        await store.recordPlanUtilizationHistorySample(
            provider: .claude,
            snapshot: accountBZero,
            account: accountB,
            now: accountBZero.updatedAt)

        #expect(recorderB.events.isEmpty)
    }

    @MainActor
    @Test
    func `issue 2054 weekly detector preserves baseline after transient zero`() async throws {
        let store = Self.makeStore()
        let accountLabel = "issue-2054-history-pollution@example.com"
        let recorder = WeeklyLimitResetEventRecorder(provider: .codex, accountLabel: accountLabel)
        defer { recorder.invalidate() }

        let firstDate = Date(timeIntervalSince1970: 1_700_000_000)
        let sessionReset = firstDate.addingTimeInterval(5 * 3600)
        let weeklyReset = firstDate.addingTimeInterval(3 * 24 * 3600)

        func snapshot(weeklyUsed: Double, updatedAt: Date) -> UsageSnapshot {
            UsageSnapshot(
                primary: RateWindow(
                    usedPercent: 14,
                    windowMinutes: 300,
                    resetsAt: sessionReset,
                    resetDescription: nil),
                secondary: RateWindow(
                    usedPercent: weeklyUsed,
                    windowMinutes: 10080,
                    resetsAt: weeklyReset,
                    resetDescription: nil),
                updatedAt: updatedAt,
                identity: ProviderIdentitySnapshot(
                    providerID: .codex,
                    accountEmail: accountLabel,
                    accountOrganization: nil,
                    loginMethod: "pro"))
        }

        let before = snapshot(weeklyUsed: 86, updatedAt: firstDate)
        // Use a later hour bucket so coalescing does not discard the transient zero sample.
        let transientZero = snapshot(weeklyUsed: 0, updatedAt: firstDate.addingTimeInterval(2 * 3600))

        await store.recordPlanUtilizationHistorySample(provider: .codex, snapshot: before, now: before.updatedAt)
        await store.recordPlanUtilizationHistorySample(
            provider: .codex,
            snapshot: transientZero,
            now: transientZero.updatedAt)

        #expect(recorder.events.isEmpty)
        let detectorKey = try #require(store.weeklyLimitResetDetectorStates.keys.first)
        #expect(store.weeklyLimitResetDetectorStates[detectorKey]?.wasAboveThreshold == true)
    }
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

private final class WeeklyLimitResetEventRecorder: @unchecked Sendable {
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
            forName: .codexbarWeeklyLimitReset,
            object: nil,
            queue: nil)
        { [weak self] notification in
            guard let self,
                  let event = notification.object as? WeeklyLimitResetEvent
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
