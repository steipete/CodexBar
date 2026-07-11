import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

extension UsageStorePlanUtilizationTests {
    @MainActor
    @Test
    func `issue 2054 live behavior proof from fixture`() async throws {
        let fixturePath = try #require(ProcessInfo.processInfo.environment["CODEXBAR_VERIFY_2054_LIVE_FIXTURE"])
        let fixtureURL = URL(fileURLWithPath: fixturePath)
        let fixtureData = try Data(contentsOf: fixtureURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let payloads = try decoder.decode([LiveCodexUsagePayload].self, from: fixtureData)
        let payload = try #require(payloads.first)
        let liveSnapshot = try #require(payload.usage)
        let accountLabel = liveSnapshot.identity?.accountEmail ?? payload.account ?? "<redacted-email>"
        let weeklyReset = try #require(liveSnapshot.secondary?.resetsAt)
        let sessionReset = liveSnapshot.primary?.resetsAt
            ?? weeklyReset.addingTimeInterval(-3 * 24 * 3600)
        let loginMethod = liveSnapshot.identity?.loginMethod ?? "live"

        print(
            "[verify-2054-proof] PROOF_LIVE_FETCH " +
                "weeklyUsed=\(liveSnapshot.secondary?.usedPercent ?? -1) " +
                "weeklyResetsAt=\(Self.proofTimestamp(weeklyReset)) " +
                "loginMethod=\(loginMethod) " +
                "account=<redacted-email>")

        try await Self.runSuppressedTransientZeroProof(
            accountLabel: accountLabel,
            sessionReset: sessionReset,
            weeklyReset: weeklyReset,
            loginMethod: loginMethod)

        try await Self.runSuppressedNilBoundaryProof(
            accountLabel: accountLabel,
            sessionReset: sessionReset,
            loginMethod: loginMethod)

        try await Self.runRealResetProof(
            accountLabel: accountLabel,
            sessionReset: sessionReset,
            weeklyReset: weeklyReset,
            loginMethod: loginMethod)
    }

    @MainActor
    private static func runSuppressedTransientZeroProof(
        accountLabel: String,
        sessionReset: Date,
        weeklyReset: Date,
        loginMethod: String) async throws
    {
        let store = Self.makeStore()
        let recorder = WeeklyLimitResetEventRecorder(provider: .codex, accountLabel: accountLabel)
        defer { recorder.invalidate() }

        let firstDate = weeklyReset.addingTimeInterval(-6 * 24 * 3600)
        let before = Self.liveProofSnapshot(
            LiveProofSnapshotInput(
                accountLabel: accountLabel,
                loginMethod: loginMethod,
                sessionReset: sessionReset,
                weeklyReset: weeklyReset,
                weeklyUsed: 86,
                updatedAt: firstDate))
        let transientZero = Self.liveProofSnapshot(
            LiveProofSnapshotInput(
                accountLabel: accountLabel,
                loginMethod: loginMethod,
                sessionReset: sessionReset,
                weeklyReset: weeklyReset,
                weeklyUsed: 0,
                updatedAt: firstDate.addingTimeInterval(120)))

        await store.recordPlanUtilizationHistorySample(provider: .codex, snapshot: before, now: before.updatedAt)
        await store.recordPlanUtilizationHistorySample(
            provider: .codex,
            snapshot: transientZero,
            now: transientZero.updatedAt)

        #expect(recorder.events.isEmpty)
        print(
            "[verify-2054-proof] PROOF_SUPPRESSED_TRANSIENT_ZERO " +
                "events=\(recorder.events.count) " +
                "weeklyResetsAt=\(Self.proofTimestamp(weeklyReset))")
    }

    @MainActor
    private static func runSuppressedNilBoundaryProof(
        accountLabel: String,
        sessionReset: Date,
        loginMethod: String) async throws
    {
        let store = Self.makeStore()
        let recorder = WeeklyLimitResetEventRecorder(provider: .codex, accountLabel: accountLabel)
        defer { recorder.invalidate() }

        let firstDate = Date(timeIntervalSince1970: 1_700_800_000)
        let before = Self.liveProofSnapshot(
            LiveProofSnapshotInput(
                accountLabel: accountLabel,
                loginMethod: loginMethod,
                sessionReset: sessionReset,
                weeklyReset: nil,
                weeklyUsed: 86,
                updatedAt: firstDate))
        let transientZero = Self.liveProofSnapshot(
            LiveProofSnapshotInput(
                accountLabel: accountLabel,
                loginMethod: loginMethod,
                sessionReset: sessionReset,
                weeklyReset: nil,
                weeklyUsed: 0,
                updatedAt: firstDate.addingTimeInterval(120)))

        await store.recordPlanUtilizationHistorySample(provider: .codex, snapshot: before, now: before.updatedAt)
        await store.recordPlanUtilizationHistorySample(
            provider: .codex,
            snapshot: transientZero,
            now: transientZero.updatedAt)

        #expect(recorder.events.isEmpty)
        print("[verify-2054-proof] PROOF_SUPPRESSED_NIL_BOUNDARY events=\(recorder.events.count)")
    }

    @MainActor
    private static func runRealResetProof(
        accountLabel: String,
        sessionReset: Date,
        weeklyReset: Date,
        loginMethod: String) async throws
    {
        let store = Self.makeStore()
        let recorder = WeeklyLimitResetEventRecorder(provider: .codex, accountLabel: accountLabel)
        defer { recorder.invalidate() }

        let firstDate = weeklyReset.addingTimeInterval(-6 * 24 * 3600)
        let advancedWeeklyReset = weeklyReset.addingTimeInterval(7 * 24 * 3600)
        let before = Self.liveProofSnapshot(
            LiveProofSnapshotInput(
                accountLabel: accountLabel,
                loginMethod: loginMethod,
                sessionReset: sessionReset,
                weeklyReset: weeklyReset,
                weeklyUsed: 86,
                updatedAt: firstDate))
        let transientZero = Self.liveProofSnapshot(
            LiveProofSnapshotInput(
                accountLabel: accountLabel,
                loginMethod: loginMethod,
                sessionReset: sessionReset,
                weeklyReset: weeklyReset,
                weeklyUsed: 0,
                updatedAt: firstDate.addingTimeInterval(120)))
        let realReset = Self.liveProofSnapshot(
            LiveProofSnapshotInput(
                accountLabel: accountLabel,
                loginMethod: loginMethod,
                sessionReset: sessionReset,
                weeklyReset: advancedWeeklyReset,
                weeklyUsed: 0,
                updatedAt: firstDate.addingTimeInterval(180)))

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
        print(
            "[verify-2054-proof] PROOF_CELEBRATED_REAL_RESET " +
                "events=\(recorder.events.count) " +
                "previousWeeklyResetsAt=\(Self.proofTimestamp(weeklyReset)) " +
                "advancedWeeklyResetsAt=\(Self.proofTimestamp(advancedWeeklyReset))")
    }

    private struct LiveProofSnapshotInput {
        let accountLabel: String
        let loginMethod: String
        let sessionReset: Date
        let weeklyReset: Date?
        let weeklyUsed: Double
        let updatedAt: Date
    }

    private static func liveProofSnapshot(_ input: LiveProofSnapshotInput) -> UsageSnapshot {
        UsageSnapshot(
            primary: RateWindow(
                usedPercent: 14,
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
        if let token {
            NotificationCenter.default.removeObserver(token)
        }
        self.token = nil
    }

    deinit {
        self.invalidate()
    }
}
