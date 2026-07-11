import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

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

        let workspaceA = Self.makeCodexVisibleAccount(
            id: "workspace-a",
            email: sharedEmail,
            workspaceAccountID: "acct-workspace-alpha",
            workspaceLabel: "Workspace Alpha")
        let workspaceB = Self.makeCodexVisibleAccount(
            id: "workspace-b",
            email: sharedEmail,
            workspaceAccountID: "acct-workspace-beta",
            workspaceLabel: "Workspace Beta")

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
                    accountEmail: sharedEmail,
                    accountOrganization: "Shared Org",
                    loginMethod: "plus"))
        }

        let workspaceAHigh = snapshot(weeklyUsed: 86, updatedAt: firstDate)
        let workspaceBZero = snapshot(weeklyUsed: 0, updatedAt: firstDate.addingTimeInterval(120))

        await store.recordPlanUtilizationHistorySample(
            provider: .codex,
            snapshot: workspaceAHigh,
            codexVisibleAccount: workspaceA,
            now: workspaceAHigh.updatedAt)
        await store.recordPlanUtilizationHistorySample(
            provider: .codex,
            snapshot: workspaceBZero,
            codexVisibleAccount: workspaceB,
            now: workspaceBZero.updatedAt)

        #expect(recorder.events.isEmpty)
        #expect(store.weeklyLimitResetDetectorStates.count == 2)
    }

    @MainActor
    @Test
    func `issue 2054 distinct token account UUIDs keep detector isolated`() async throws {
        let store = Self.makeStore()
        let accountAUUID = try #require(UUID(uuidString: "11111111-1111-1111-1111-111111111111"))
        let accountBUUID = try #require(UUID(uuidString: "22222222-2222-2222-2222-222222222222"))
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
    func `issue 2054 weekly confetti ignores nil reset boundaries`() async {
        let store = Self.makeStore()
        let accountLabel = "issue-2054-weekly-nil-boundary@example.com"
        let recorder = WeeklyLimitResetEventRecorder(provider: .codex, accountLabel: accountLabel)
        defer { recorder.invalidate() }

        let firstDate = Date(timeIntervalSince1970: 1_700_700_000)

        func snapshot(weeklyUsed: Double, updatedAt: Date) -> UsageSnapshot {
            UsageSnapshot(
                primary: RateWindow(
                    usedPercent: 14,
                    windowMinutes: 300,
                    resetsAt: nil,
                    resetDescription: nil),
                secondary: RateWindow(
                    usedPercent: weeklyUsed,
                    windowMinutes: 10080,
                    resetsAt: nil,
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
    func `issue 2054 propagated workspace account ids isolate detector keys`() async throws {
        let sharedEmail = "issue-2054-workspace-label@example.com"
        let workspaceA = Self.makeCodexVisibleAccount(
            id: "workspace-alpha",
            email: sharedEmail,
            workspaceAccountID: "acct-alpha",
            workspaceLabel: "Workspace Alpha")
        let workspaceB = Self.makeCodexVisibleAccount(
            id: "workspace-beta",
            email: sharedEmail,
            workspaceAccountID: "acct-beta",
            workspaceLabel: "Workspace Beta")

        let snapshotA = UsageSnapshot(
            primary: RateWindow(usedPercent: 10, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
            secondary: RateWindow(usedPercent: 20, windowMinutes: 10080, resetsAt: nil, resetDescription: nil),
            updatedAt: Date(),
            identity: ProviderIdentitySnapshot(
                providerID: .codex,
                accountEmail: sharedEmail,
                accountOrganization: "Shared Org",
                loginMethod: "plus"))
        let snapshotB = UsageSnapshot(
            primary: RateWindow(usedPercent: 10, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
            secondary: RateWindow(usedPercent: 20, windowMinutes: 10080, resetsAt: nil, resetDescription: nil),
            updatedAt: Date(),
            identity: ProviderIdentitySnapshot(
                providerID: .codex,
                accountEmail: sharedEmail,
                accountOrganization: "Shared Org",
                loginMethod: "plus"))

        let keyA = try #require(UsageStore._planUtilizationAccountKeyForTesting(provider: .codex, snapshot: snapshotA))
        let keyB = try #require(UsageStore._planUtilizationAccountKeyForTesting(provider: .codex, snapshot: snapshotB))
        #expect(keyA == keyB)

        let store = Self.makeStore()
        await store.recordPlanUtilizationHistorySample(
            provider: .codex,
            snapshot: snapshotA,
            codexVisibleAccount: workspaceA,
            now: snapshotA.updatedAt)
        await store.recordPlanUtilizationHistorySample(
            provider: .codex,
            snapshot: snapshotB,
            codexVisibleAccount: workspaceB,
            now: snapshotB.updatedAt)

        #expect(store.weeklyLimitResetDetectorStates.count == 2)
    }

    @MainActor
    @Test
    func `issue 2054 plan change keeps stable workspace detector key`() async {
        let store = Self.makeStore()
        let sharedEmail = "issue-2054-plan-change@example.com"
        let workspace = Self.makeCodexVisibleAccount(
            id: "workspace-stable",
            email: sharedEmail,
            workspaceAccountID: "acct-stable-plan-change",
            workspaceLabel: "Stable Workspace")

        let firstDate = Date(timeIntervalSince1970: 1_700_900_000)
        let weeklyReset = firstDate.addingTimeInterval(3 * 24 * 3600)

        func snapshot(plan: String, weeklyUsed: Double, updatedAt: Date) -> UsageSnapshot {
            UsageSnapshot(
                primary: RateWindow(usedPercent: 10, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
                secondary: RateWindow(
                    usedPercent: weeklyUsed,
                    windowMinutes: 10080,
                    resetsAt: weeklyReset,
                    resetDescription: nil),
                updatedAt: updatedAt,
                identity: ProviderIdentitySnapshot(
                    providerID: .codex,
                    accountEmail: sharedEmail,
                    accountOrganization: nil,
                    loginMethod: plan))
        }

        await store.recordPlanUtilizationHistorySample(
            provider: .codex,
            snapshot: snapshot(plan: "plus", weeklyUsed: 86, updatedAt: firstDate),
            codexVisibleAccount: workspace,
            now: firstDate)
        await store.recordPlanUtilizationHistorySample(
            provider: .codex,
            snapshot: snapshot(plan: "pro", weeklyUsed: 84, updatedAt: firstDate.addingTimeInterval(120)),
            codexVisibleAccount: workspace,
            now: firstDate.addingTimeInterval(120))

        #expect(store.weeklyLimitResetDetectorStates.count == 1)
    }

    @MainActor
    @Test
    func `issue 2054 preserves baseline when boundary first appears then celebrates`() async {
        let store = Self.makeStore()
        let accountLabel = "issue-2054-first-boundary@example.com"
        let recorder = WeeklyLimitResetEventRecorder(provider: .codex, accountLabel: accountLabel)
        defer { recorder.invalidate() }

        let firstDate = Date(timeIntervalSince1970: 1_700_600_000)
        let sessionReset = firstDate.addingTimeInterval(5 * 3600)
        let weeklyReset = firstDate.addingTimeInterval(3 * 24 * 3600)

        func snapshot(weeklyUsed: Double, weeklyReset: Date?, updatedAt: Date) -> UsageSnapshot {
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
                    loginMethod: "plus"))
        }

        let before = snapshot(weeklyUsed: 86, weeklyReset: nil, updatedAt: firstDate)
        let introducedBoundary = snapshot(
            weeklyUsed: 0,
            weeklyReset: weeklyReset,
            updatedAt: firstDate.addingTimeInterval(120))
        let realReset = snapshot(
            weeklyUsed: 0,
            weeklyReset: weeklyReset.addingTimeInterval(7 * 24 * 3600),
            updatedAt: firstDate.addingTimeInterval(240))

        await store.recordPlanUtilizationHistorySample(provider: .codex, snapshot: before, now: before.updatedAt)
        await store.recordPlanUtilizationHistorySample(
            provider: .codex,
            snapshot: introducedBoundary,
            now: introducedBoundary.updatedAt)
        #expect(recorder.events.isEmpty)

        await store.recordPlanUtilizationHistorySample(
            provider: .codex,
            snapshot: realReset,
            now: realReset.updatedAt)

        #expect(recorder.events.count == 1)
        #expect(recorder.events.first?.usedPercent == 0)
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

    static func makeCodexVisibleAccount(
        id: String,
        email: String,
        workspaceAccountID: String,
        workspaceLabel: String? = nil) -> CodexVisibleAccount
    {
        CodexVisibleAccount(
            id: id,
            email: email,
            workspaceLabel: workspaceLabel,
            workspaceAccountID: workspaceAccountID,
            authFingerprint: nil,
            storedAccountID: nil,
            selectionSource: .liveSystem,
            isActive: false,
            isLive: true,
            canReauthenticate: false,
            canRemove: false)
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
