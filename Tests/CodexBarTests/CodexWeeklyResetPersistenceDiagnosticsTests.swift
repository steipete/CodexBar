import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
extension CodexAccountScopedRefreshTests {
    @Test
    func `candidate persistence reasons distinguish guard rejection from storage requests`() throws {
        let suite = "CodexWeeklyResetPersistenceDiagnosticsTests"
        let settings = self.makeSettingsStore(suite: suite)
        settings.refreshFrequency = .manual
        settings.codexCookieSource = .off
        settings._test_liveSystemCodexAccount = self.liveAccount(
            email: "persistence-diagnostic@example.com",
            identity: .providerAccount(id: "acct-persistence-diagnostic"))
        defer { settings._test_liveSystemCodexAccount = nil }
        let now = Date()
        let previous = self.codexWeeklySnapshot(
            email: "persistence-diagnostic@example.com",
            weeklyUsedPercent: 80,
            weeklyReset: now.addingTimeInterval(500_000),
            updatedAt: now)
        let candidate = CodexWeeklyResetPublicationCandidate(firstObservedAt: now, snapshot: previous)
        let recordingStore = RecordingCodexAccountUsageSnapshotStore(initialSnapshots: [])
        let store = self.makeCodexWeeklyPublicationStore(
            settings: settings, suite: suite, snapshotStore: recordingStore)
        let expected = store.freshCodexAccountScopedRefreshGuard()
        let wrongAccount = CodexAccountScopedRefreshGuard(
            source: expected.source,
            identity: .providerAccount(id: "different-account"),
            accountKey: expected.accountKey,
            authFingerprint: expected.authFingerprint)

        #expect(store.persistCodexWeeklyResetPublicationCandidate(
            candidate, expectedGuard: nil, previousSnapshot: previous) == .missingExpectedGuard)
        #expect(store.persistCodexWeeklyResetPublicationCandidate(
            candidate, expectedGuard: wrongAccount, previousSnapshot: previous) == .accountChanged)
        #expect(store.persistCodexWeeklyResetPublicationCandidate(
            nil, expectedGuard: expected, previousSnapshot: previous) == .missingCandidateOrBaseline)
        #expect(store.codexAccountSnapshots.isEmpty)
        #expect(recordingStore.storedSnapshots.isEmpty)

        #expect(store.persistCodexWeeklyResetPublicationCandidate(
            candidate, expectedGuard: expected, previousSnapshot: previous) == .storeRequested)
        #expect(recordingStore.storedSnapshots.first?.weeklyResetCandidate?.createdAt == candidate.createdAt)
        #expect(store.persistCodexWeeklyResetPublicationCandidate(
            nil, expectedGuard: expected, previousSnapshot: previous) == .storeRequested)
        #expect(recordingStore.storedSnapshots.first?.weeklyResetCandidate == nil)
        #expect(store.persistCodexWeeklyResetPublicationCandidate(
            nil, expectedGuard: expected, previousSnapshot: previous) == .noCandidateChange)

        let memoryOnly = self.makeCodexWeeklyPublicationStore(settings: settings, suite: suite + "-memory")
        #expect(memoryOnly.codexAccountUsageSnapshotStore == nil)
        #expect(memoryOnly.persistCodexWeeklyResetPublicationCandidate(
            candidate, expectedGuard: expected, previousSnapshot: previous) == .storeUnavailable)
        #expect(memoryOnly.codexAccountSnapshots.first?.weeklyResetCandidate?.createdAt == candidate.createdAt)

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-reset-diagnostic-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let blockingFile = root.appendingPathComponent("not-a-directory")
        let sentinel = Data("synthetic storage blocker".utf8)
        try sentinel.write(to: blockingFile)
        let snapshotURL = blockingFile.appendingPathComponent("snapshots.json")
        let diskFailure = self.makeCodexWeeklyPublicationStore(
            settings: settings,
            suite: suite + "-disk-failure",
            snapshotStore: FileCodexAccountUsageSnapshotStore(fileURL: snapshotURL))
        #expect(diskFailure.persistCodexWeeklyResetPublicationCandidate(
            candidate, expectedGuard: expected, previousSnapshot: previous) == .storeRequested)
        #expect(!FileManager.default.fileExists(atPath: snapshotURL.path))
        #expect(try Data(contentsOf: blockingFile) == sentinel)
        #expect(diskFailure.codexAccountSnapshots.first?.weeklyResetCandidate?.createdAt == candidate.createdAt)
        #expect(UsageStore.CodexWeeklyResetPersistenceDecision.storeRequested.diagnosticMetadata == [
            "stage": "candidatePersistence", "decision": "storeRequested",
        ])
    }
}
