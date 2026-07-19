import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

extension UsageStorePlanUtilizationTests {
    @MainActor
    @Test
    func `session quota celebration posts when session usage resets to zero`() async {
        let store = Self.makeStore()
        let accountLabel = "session-reset-zero@example.com"
        let recorder = SessionLimitResetEventRecorder(provider: .claude, accountLabel: accountLabel)
        defer { recorder.invalidate() }

        let before = UsageSnapshot(
            primary: RateWindow(usedPercent: 65, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
            secondary: RateWindow(usedPercent: 20, windowMinutes: 10080, resetsAt: nil, resetDescription: nil),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            identity: ProviderIdentitySnapshot(
                providerID: .claude,
                accountEmail: accountLabel,
                accountOrganization: nil,
                loginMethod: "max"))
        let after = UsageSnapshot(
            primary: RateWindow(usedPercent: 0, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
            secondary: RateWindow(usedPercent: 20, windowMinutes: 10080, resetsAt: nil, resetDescription: nil),
            updatedAt: Date(timeIntervalSince1970: 1_700_003_600),
            identity: ProviderIdentitySnapshot(
                providerID: .claude,
                accountEmail: accountLabel,
                accountOrganization: nil,
                loginMethod: "max"))

        await store.recordPlanUtilizationHistorySample(provider: .claude, snapshot: before, now: before.updatedAt)
        await store.recordPlanUtilizationHistorySample(provider: .claude, snapshot: after, now: after.updatedAt)

        let events = recorder.events
        #expect(events.count == 1)
        #expect(events[0].provider == .claude)
        #expect(events[0].accountLabel == accountLabel)
        #expect(events[0].usedPercent == 0)
    }

    @MainActor
    @Test
    func `Claude placeholder does not post or consume a genuine session reset`() async {
        let store = Self.makeStore()
        let accountLabel = "synthetic-session-reset@example.com"
        let recorder = SessionLimitResetEventRecorder(provider: .claude, accountLabel: accountLabel)
        defer { recorder.invalidate() }

        func snapshot(usedPercent: Double, isPlaceholder: Bool, updatedAt: Date) -> UsageSnapshot {
            UsageSnapshot(
                primary: RateWindow(
                    usedPercent: usedPercent,
                    windowMinutes: 5 * 60,
                    resetsAt: nil,
                    resetDescription: nil,
                    isSyntheticPlaceholder: isPlaceholder),
                secondary: RateWindow(
                    usedPercent: 20,
                    windowMinutes: 7 * 24 * 60,
                    resetsAt: nil,
                    resetDescription: nil),
                updatedAt: updatedAt,
                identity: ProviderIdentitySnapshot(
                    providerID: .claude,
                    accountEmail: accountLabel,
                    accountOrganization: nil,
                    loginMethod: "web"))
        }

        let start = Date(timeIntervalSince1970: 1_780_000_000)
        let before = snapshot(usedPercent: 65, isPlaceholder: false, updatedAt: start)
        let placeholder = snapshot(
            usedPercent: 0,
            isPlaceholder: true,
            updatedAt: start.addingTimeInterval(60 * 60))
        let genuineReset = snapshot(
            usedPercent: 0,
            isPlaceholder: false,
            updatedAt: start.addingTimeInterval(2 * 60 * 60))

        await store.recordPlanUtilizationHistorySample(provider: .claude, snapshot: before, now: before.updatedAt)
        await store.recordPlanUtilizationHistorySample(
            provider: .claude,
            snapshot: placeholder,
            now: placeholder.updatedAt)
        #expect(recorder.events.isEmpty)

        await store.recordPlanUtilizationHistorySample(
            provider: .claude,
            snapshot: genuineReset,
            now: genuineReset.updatedAt)
        #expect(recorder.events.count == 1)
        #expect(recorder.events.first?.usedPercent == 0)
    }

    @MainActor
    @Test
    func `legacy session detector state preserves first reset after upgrade`() async throws {
        let store = Self.makeStore()
        let accountLabel = "session-reset-upgrade@example.com"
        let recorder = SessionLimitResetEventRecorder(provider: .claude, accountLabel: accountLabel)
        defer { recorder.invalidate() }

        let before = UsageSnapshot(
            primary: RateWindow(usedPercent: 65, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
            secondary: RateWindow(usedPercent: 20, windowMinutes: 10080, resetsAt: nil, resetDescription: nil),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            identity: ProviderIdentitySnapshot(
                providerID: .claude,
                accountEmail: accountLabel,
                accountOrganization: nil,
                loginMethod: "max"))
        let after = UsageSnapshot(
            primary: RateWindow(usedPercent: 0, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
            secondary: RateWindow(usedPercent: 20, windowMinutes: 10080, resetsAt: nil, resetDescription: nil),
            updatedAt: Date(timeIntervalSince1970: 1_700_003_600),
            identity: ProviderIdentitySnapshot(
                providerID: .claude,
                accountEmail: accountLabel,
                accountOrganization: nil,
                loginMethod: "max"))

        await store.recordPlanUtilizationHistorySample(provider: .claude, snapshot: before, now: before.updatedAt)
        let detectorKey = try #require(store.sessionLimitResetDetectorStates.keys.first)
        store.sessionLimitResetDetectorStates[detectorKey] = UsageStore.LimitResetDetectorState(
            wasAboveThreshold: true,
            lastObservedAt: before.updatedAt,
            sourceRawValue: nil)

        await store.recordPlanUtilizationHistorySample(provider: .claude, snapshot: after, now: after.updatedAt)

        #expect(recorder.events.count == 1)
    }

    @MainActor
    @Test
    func `codex session celebration follows semantic secondary session lane`() async throws {
        let store = Self.makeStore()
        let accountLabel = "codex-session-secondary@example.com"
        let ownerKey = try #require(CodexLimitResetOwnerKey(
            identity: .providerAccount(id: "fixture-codex-session-secondary"),
            accountEmail: accountLabel))
        let recorder = SessionLimitResetEventRecorder(provider: .codex, accountLabel: accountLabel)
        defer { recorder.invalidate() }

        let before = UsageSnapshot(
            primary: RateWindow(usedPercent: 20, windowMinutes: 10080, resetsAt: nil, resetDescription: nil),
            secondary: RateWindow(usedPercent: 65, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            identity: ProviderIdentitySnapshot(
                providerID: .codex,
                accountEmail: accountLabel,
                accountOrganization: nil,
                loginMethod: "plus"))
        let after = UsageSnapshot(
            primary: RateWindow(usedPercent: 20, windowMinutes: 10080, resetsAt: nil, resetDescription: nil),
            secondary: RateWindow(usedPercent: 0, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
            updatedAt: Date(timeIntervalSince1970: 1_700_003_600),
            identity: ProviderIdentitySnapshot(
                providerID: .codex,
                accountEmail: accountLabel,
                accountOrganization: nil,
                loginMethod: "plus"))

        await store.recordPlanUtilizationHistorySample(
            provider: .codex,
            snapshot: before,
            codexLimitResetOwnerKey: ownerKey,
            now: before.updatedAt)
        await store.recordPlanUtilizationHistorySample(
            provider: .codex,
            snapshot: after,
            codexLimitResetOwnerKey: ownerKey,
            now: after.updatedAt)

        #expect(recorder.events.count == 1)
        #expect(recorder.events.first?.usedPercent == 0)
    }

    @MainActor
    @Test
    func `codex session celebration ignores transient zero when reset boundary is unchanged`() async throws {
        let store = Self.makeStore()
        let accountLabel = "codex-session-transient-zero@example.com"
        let ownerKey = try #require(CodexLimitResetOwnerKey(
            identity: .providerAccount(id: "fixture-codex-session-transient-zero"),
            accountEmail: accountLabel))
        let recorder = SessionLimitResetEventRecorder(provider: .codex, accountLabel: accountLabel)
        defer { recorder.invalidate() }

        let firstDate = Date(timeIntervalSince1970: 1_700_000_000)
        let sessionReset = firstDate.addingTimeInterval(5 * 3600)
        let weeklyReset = firstDate.addingTimeInterval(3 * 24 * 3600)

        func snapshot(sessionUsed: Double, sessionReset: Date, updatedAt: Date) -> UsageSnapshot {
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

        let before = snapshot(
            sessionUsed: 67,
            sessionReset: sessionReset,
            updatedAt: firstDate)
        let regressedBoundaryHigh = snapshot(
            sessionUsed: 68,
            sessionReset: sessionReset.addingTimeInterval(-3600),
            updatedAt: firstDate.addingTimeInterval(60))
        let transientZero = snapshot(
            sessionUsed: 0,
            sessionReset: sessionReset,
            updatedAt: firstDate.addingTimeInterval(120))
        let realReset = snapshot(
            sessionUsed: 0,
            sessionReset: sessionReset.addingTimeInterval(5 * 3600),
            updatedAt: firstDate.addingTimeInterval(180))

        await store.recordPlanUtilizationHistorySample(
            provider: .codex,
            snapshot: before,
            codexLimitResetOwnerKey: ownerKey,
            now: before.updatedAt)
        await store.recordPlanUtilizationHistorySample(
            provider: .codex,
            snapshot: regressedBoundaryHigh,
            codexLimitResetOwnerKey: ownerKey,
            now: regressedBoundaryHigh.updatedAt)
        await store.recordPlanUtilizationHistorySample(
            provider: .codex,
            snapshot: transientZero,
            codexLimitResetOwnerKey: ownerKey,
            now: transientZero.updatedAt)
        #expect(recorder.events.isEmpty)

        await store.recordPlanUtilizationHistorySample(
            provider: .codex,
            snapshot: realReset,
            codexLimitResetOwnerKey: ownerKey,
            now: realReset.updatedAt)

        #expect(recorder.events.count == 1)
        #expect(recorder.events.first?.usedPercent == 0)
    }

    @MainActor
    @Test
    func `codex weekly celebration ignores transient zero when reset boundary is unchanged`() async throws {
        let store = Self.makeStore()
        let accountLabel = "codex-weekly-transient-zero@example.com"
        let ownerKey = try #require(CodexLimitResetOwnerKey(
            identity: .providerAccount(id: "fixture-codex-weekly-transient-zero"),
            accountEmail: accountLabel))
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

        let before = snapshot(
            weeklyUsed: 86,
            weeklyReset: weeklyReset,
            updatedAt: firstDate)
        let transientZero = snapshot(
            weeklyUsed: 0,
            weeklyReset: weeklyReset,
            updatedAt: firstDate.addingTimeInterval(120))
        let realReset = snapshot(
            weeklyUsed: 0,
            weeklyReset: weeklyReset.addingTimeInterval(7 * 24 * 3600),
            updatedAt: firstDate.addingTimeInterval(180))

        await store.recordPlanUtilizationHistorySample(
            provider: .codex,
            snapshot: before,
            codexLimitResetOwnerKey: ownerKey,
            now: before.updatedAt)
        await store.recordPlanUtilizationHistorySample(
            provider: .codex,
            snapshot: transientZero,
            codexLimitResetOwnerKey: ownerKey,
            now: transientZero.updatedAt)
        #expect(recorder.events.isEmpty)

        await store.recordPlanUtilizationHistorySample(
            provider: .codex,
            snapshot: realReset,
            codexLimitResetOwnerKey: ownerKey,
            now: realReset.updatedAt)

        #expect(recorder.events.count == 1)
        #expect(recorder.events.first?.usedPercent == 0)
    }

    @MainActor
    @Test
    func `codex weekly celebration ignores missing reset boundaries`() async throws {
        let store = Self.makeStore()
        let accountLabel = "codex-weekly-missing-boundary@example.com"
        let ownerKey = try #require(CodexLimitResetOwnerKey(
            identity: .providerAccount(id: "fixture-codex-weekly-missing-boundary"),
            accountEmail: accountLabel))
        let recorder = WeeklyLimitResetEventRecorder(provider: .codex, accountLabel: accountLabel)
        defer { recorder.invalidate() }

        let firstDate = Date(timeIntervalSince1970: 1_700_800_000)
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
                    loginMethod: "pro"))
        }

        let before = snapshot(weeklyUsed: 86, weeklyReset: nil, updatedAt: firstDate)
        let transientZero = snapshot(
            weeklyUsed: 0,
            weeklyReset: nil,
            updatedAt: firstDate.addingTimeInterval(120))

        await store.recordPlanUtilizationHistorySample(
            provider: .codex,
            snapshot: before,
            codexLimitResetOwnerKey: ownerKey,
            now: before.updatedAt)
        await store.recordPlanUtilizationHistorySample(
            provider: .codex,
            snapshot: transientZero,
            codexLimitResetOwnerKey: ownerKey,
            now: transientZero.updatedAt)
        #expect(recorder.events.isEmpty)

        let establishedBoundary = snapshot(
            weeklyUsed: 72,
            weeklyReset: weeklyReset,
            updatedAt: firstDate.addingTimeInterval(240))
        let realReset = snapshot(
            weeklyUsed: 0,
            weeklyReset: weeklyReset.addingTimeInterval(7 * 24 * 3600),
            updatedAt: firstDate.addingTimeInterval(360))

        await store.recordPlanUtilizationHistorySample(
            provider: .codex,
            snapshot: establishedBoundary,
            codexLimitResetOwnerKey: ownerKey,
            now: establishedBoundary.updatedAt)
        await store.recordPlanUtilizationHistorySample(
            provider: .codex,
            snapshot: realReset,
            codexLimitResetOwnerKey: ownerKey,
            now: realReset.updatedAt)

        #expect(recorder.events.count == 1)
        #expect(recorder.events.first?.usedPercent == 0)
    }

    @MainActor
    @Test
    func `codex weekly celebration preserves a known boundary across missing metadata`() async throws {
        let store = Self.makeStore()
        let accountLabel = "codex-weekly-intermittent-boundary@example.com"
        let ownerKey = try #require(CodexLimitResetOwnerKey(
            identity: .providerAccount(id: "fixture-codex-weekly-intermittent-boundary"),
            accountEmail: accountLabel))
        let recorder = WeeklyLimitResetEventRecorder(provider: .codex, accountLabel: accountLabel)
        defer { recorder.invalidate() }

        let firstDate = Date(timeIntervalSince1970: 1_700_900_000)
        let weeklyReset = firstDate.addingTimeInterval(3 * 24 * 3600)

        func snapshot(weeklyUsed: Double, weeklyReset: Date?, updatedAt: Date) -> UsageSnapshot {
            UsageSnapshot(
                primary: RateWindow(
                    usedPercent: 14,
                    windowMinutes: 300,
                    resetsAt: firstDate.addingTimeInterval(5 * 3600),
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
        let missingMetadata = snapshot(
            weeklyUsed: 84,
            weeklyReset: nil,
            updatedAt: firstDate.addingTimeInterval(60))
        let realReset = snapshot(
            weeklyUsed: 0,
            weeklyReset: weeklyReset.addingTimeInterval(7 * 24 * 3600),
            updatedAt: firstDate.addingTimeInterval(120))

        await store.recordPlanUtilizationHistorySample(
            provider: .codex,
            snapshot: before,
            codexLimitResetOwnerKey: ownerKey,
            now: before.updatedAt)
        await store.recordPlanUtilizationHistorySample(
            provider: .codex,
            snapshot: missingMetadata,
            codexLimitResetOwnerKey: ownerKey,
            now: missingMetadata.updatedAt)
        await store.recordPlanUtilizationHistorySample(
            provider: .codex,
            snapshot: realReset,
            codexLimitResetOwnerKey: ownerKey,
            now: realReset.updatedAt)

        #expect(recorder.events.count == 1)
        #expect(recorder.events.first?.usedPercent == 0)
    }

    @MainActor
    @Test
    func `codex session celebration ignores missing reset boundary after a known boundary`() async throws {
        let store = Self.makeStore()
        let accountLabel = "codex-session-missing-boundary@example.com"
        let ownerKey = try #require(CodexLimitResetOwnerKey(
            identity: .providerAccount(id: "fixture-codex-session-missing-boundary"),
            accountEmail: accountLabel))
        let recorder = SessionLimitResetEventRecorder(provider: .codex, accountLabel: accountLabel)
        defer { recorder.invalidate() }

        let firstDate = Date(timeIntervalSince1970: 1_700_000_000)
        let sessionReset = firstDate.addingTimeInterval(5 * 3600)
        let weeklyReset = firstDate.addingTimeInterval(3 * 24 * 3600)

        func snapshot(sessionUsed: Double, sessionReset: Date?, updatedAt: Date) -> UsageSnapshot {
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

        let before = snapshot(
            sessionUsed: 67,
            sessionReset: sessionReset,
            updatedAt: firstDate)
        let missingBoundaryHigh = snapshot(
            sessionUsed: 68,
            sessionReset: nil,
            updatedAt: firstDate.addingTimeInterval(60))
        let missingBoundary = snapshot(
            sessionUsed: 0,
            sessionReset: nil,
            updatedAt: firstDate.addingTimeInterval(120))
        let realReset = snapshot(
            sessionUsed: 0,
            sessionReset: sessionReset.addingTimeInterval(5 * 3600),
            updatedAt: firstDate.addingTimeInterval(180))

        await store.recordPlanUtilizationHistorySample(
            provider: .codex,
            snapshot: before,
            codexLimitResetOwnerKey: ownerKey,
            now: before.updatedAt)
        await store.recordPlanUtilizationHistorySample(
            provider: .codex,
            snapshot: missingBoundaryHigh,
            codexLimitResetOwnerKey: ownerKey,
            now: missingBoundaryHigh.updatedAt)
        await store.recordPlanUtilizationHistorySample(
            provider: .codex,
            snapshot: missingBoundary,
            codexLimitResetOwnerKey: ownerKey,
            now: missingBoundary.updatedAt)
        #expect(recorder.events.isEmpty)

        await store.recordPlanUtilizationHistorySample(
            provider: .codex,
            snapshot: realReset,
            codexLimitResetOwnerKey: ownerKey,
            now: realReset.updatedAt)

        #expect(recorder.events.count == 1)
        #expect(recorder.events.first?.usedPercent == 0)
    }

    @MainActor
    @Test
    func `codex weekly celebration ignores low usage with an unchanged boundary`() async throws {
        let store = Self.makeStore()
        let accountLabel = "codex-weekly-unchanged-boundary@example.com"
        let ownerKey = try #require(CodexLimitResetOwnerKey(
            identity: .providerAccount(id: "fixture-codex-weekly-unchanged-boundary"),
            accountEmail: accountLabel))
        let recorder = WeeklyLimitResetEventRecorder(provider: .codex, accountLabel: accountLabel)
        defer { recorder.invalidate() }

        let firstDate = Date(timeIntervalSince1970: 1_701_000_000)
        let weeklyReset = firstDate.addingTimeInterval(3 * 24 * 3600)
        let before = codexWeeklySnapshot(
            accountLabel: accountLabel,
            usedPercent: 86,
            resetsAt: weeklyReset,
            updatedAt: firstDate)
        let transientLow = codexWeeklySnapshot(
            accountLabel: accountLabel,
            usedPercent: 0,
            resetsAt: weeklyReset,
            updatedAt: firstDate.addingTimeInterval(60))

        await store.recordPlanUtilizationHistorySample(
            provider: .codex,
            snapshot: before,
            codexLimitResetOwnerKey: ownerKey,
            now: before.updatedAt)
        await store.recordPlanUtilizationHistorySample(
            provider: .codex,
            snapshot: transientLow,
            codexLimitResetOwnerKey: ownerKey,
            now: transientLow.updatedAt)

        #expect(recorder.events.isEmpty)
    }

    @MainActor
    @Test
    func `codex weekly celebration requires both reset boundaries`() async throws {
        let store = Self.makeStore()
        let accountLabel = "codex-weekly-requires-boundaries@example.com"
        let recorder = WeeklyLimitResetEventRecorder(provider: .codex, accountLabel: accountLabel)
        defer { recorder.invalidate() }

        let firstDate = Date(timeIntervalSince1970: 1_702_000_000)
        let weeklyReset = firstDate.addingTimeInterval(3 * 24 * 3600)
        let missingPreviousOwner = try #require(CodexLimitResetOwnerKey(
            identity: .providerAccount(id: "fixture-codex-weekly-missing-previous"),
            accountEmail: accountLabel))
        let missingCurrentOwner = try #require(CodexLimitResetOwnerKey(
            identity: .providerAccount(id: "fixture-codex-weekly-missing-current"),
            accountEmail: accountLabel))
        let missingPreviousHigh = codexWeeklySnapshot(
            accountLabel: accountLabel,
            usedPercent: 86,
            resetsAt: nil,
            updatedAt: firstDate)
        let boundaryAppearedLow = codexWeeklySnapshot(
            accountLabel: accountLabel,
            usedPercent: 0,
            resetsAt: weeklyReset,
            updatedAt: firstDate.addingTimeInterval(60))
        let knownBoundaryHigh = codexWeeklySnapshot(
            accountLabel: accountLabel,
            usedPercent: 86,
            resetsAt: weeklyReset,
            updatedAt: firstDate.addingTimeInterval(120))
        let missingCurrentLow = codexWeeklySnapshot(
            accountLabel: accountLabel,
            usedPercent: 0,
            resetsAt: nil,
            updatedAt: firstDate.addingTimeInterval(180))

        await store.recordPlanUtilizationHistorySample(
            provider: .codex,
            snapshot: missingPreviousHigh,
            codexLimitResetOwnerKey: missingPreviousOwner,
            now: missingPreviousHigh.updatedAt)
        await store.recordPlanUtilizationHistorySample(
            provider: .codex,
            snapshot: boundaryAppearedLow,
            codexLimitResetOwnerKey: missingPreviousOwner,
            now: boundaryAppearedLow.updatedAt)
        await store.recordPlanUtilizationHistorySample(
            provider: .codex,
            snapshot: knownBoundaryHigh,
            codexLimitResetOwnerKey: missingCurrentOwner,
            now: knownBoundaryHigh.updatedAt)
        await store.recordPlanUtilizationHistorySample(
            provider: .codex,
            snapshot: missingCurrentLow,
            codexLimitResetOwnerKey: missingCurrentOwner,
            now: missingCurrentLow.updatedAt)

        #expect(recorder.events.isEmpty)
    }

    @MainActor
    @Test
    func `codex weekly celebration posts once for an advanced boundary`() async throws {
        let store = Self.makeStore()
        let accountLabel = "codex-weekly-advanced-boundary@example.com"
        let ownerKey = try #require(CodexLimitResetOwnerKey(
            identity: .providerAccount(id: "fixture-codex-weekly-advanced-boundary"),
            accountEmail: accountLabel))
        let recorder = WeeklyLimitResetEventRecorder(provider: .codex, accountLabel: accountLabel)
        defer { recorder.invalidate() }

        let firstDate = Date(timeIntervalSince1970: 1_703_000_000)
        let weeklyReset = firstDate.addingTimeInterval(3 * 24 * 3600)
        let nextWeeklyReset = weeklyReset.addingTimeInterval(7 * 24 * 3600)
        let before = codexWeeklySnapshot(
            accountLabel: accountLabel,
            usedPercent: 86,
            resetsAt: weeklyReset,
            updatedAt: firstDate)
        let reset = codexWeeklySnapshot(
            accountLabel: accountLabel,
            usedPercent: 0,
            resetsAt: nextWeeklyReset,
            updatedAt: firstDate.addingTimeInterval(60))
        let repeatedLow = codexWeeklySnapshot(
            accountLabel: accountLabel,
            usedPercent: 0,
            resetsAt: nextWeeklyReset,
            updatedAt: firstDate.addingTimeInterval(120))

        for snapshot in [before, reset, repeatedLow] {
            await store.recordPlanUtilizationHistorySample(
                provider: .codex,
                snapshot: snapshot,
                codexLimitResetOwnerKey: ownerKey,
                now: snapshot.updatedAt)
        }

        #expect(recorder.events.count == 1)
        #expect(recorder.events.first?.usedPercent == 0)
    }

    @MainActor
    @Test
    func `codex weekly detector isolates same email workspaces`() async throws {
        let store = Self.makeStore()
        let accountLabel = "codex-shared-email@example.com"
        let ownerA = try #require(CodexLimitResetOwnerKey(
            identity: .providerAccount(id: "fixture-codex-workspace-a"),
            accountEmail: accountLabel))
        let ownerB = try #require(CodexLimitResetOwnerKey(
            identity: .providerAccount(id: "fixture-codex-workspace-b"),
            accountEmail: accountLabel))
        let recorder = WeeklyLimitResetEventRecorder(provider: .codex, accountLabel: accountLabel)
        defer { recorder.invalidate() }

        let firstDate = Date(timeIntervalSince1970: 1_703_500_000)
        let weeklyReset = firstDate.addingTimeInterval(3 * 24 * 3600)
        let nextWeeklyReset = weeklyReset.addingTimeInterval(7 * 24 * 3600)
        let workspaceAHigh = codexWeeklySnapshot(
            accountLabel: accountLabel,
            usedPercent: 86,
            resetsAt: weeklyReset,
            updatedAt: firstDate)
        let workspaceBLow = codexWeeklySnapshot(
            accountLabel: accountLabel,
            usedPercent: 0,
            resetsAt: nextWeeklyReset,
            updatedAt: firstDate.addingTimeInterval(60))
        let workspaceAReset = codexWeeklySnapshot(
            accountLabel: accountLabel,
            usedPercent: 0,
            resetsAt: nextWeeklyReset,
            updatedAt: firstDate.addingTimeInterval(120))

        await store.recordPlanUtilizationHistorySample(
            provider: .codex,
            snapshot: workspaceAHigh,
            codexLimitResetOwnerKey: ownerA,
            now: workspaceAHigh.updatedAt)
        await store.recordPlanUtilizationHistorySample(
            provider: .codex,
            snapshot: workspaceBLow,
            codexLimitResetOwnerKey: ownerB,
            now: workspaceBLow.updatedAt)

        #expect(recorder.events.isEmpty)
        #expect(store.weeklyLimitResetDetectorStates.count == 2)

        await store.recordPlanUtilizationHistorySample(
            provider: .codex,
            snapshot: workspaceAReset,
            codexLimitResetOwnerKey: ownerA,
            now: workspaceAReset.updatedAt)

        #expect(recorder.events.count == 1)
        #expect(recorder.events.first?.usedPercent == 0)
    }

    @MainActor
    @Test
    func `codex weekly detector isolates members of the same workspace`() async throws {
        let store = Self.makeStore()
        let firstEmail = "first-workspace-member@example.com"
        let secondEmail = "second-workspace-member@example.com"
        let ownerA = try #require(CodexLimitResetOwnerKey(
            identity: .providerAccount(id: "fixture-codex-shared-workspace"),
            accountEmail: firstEmail))
        let ownerB = try #require(CodexLimitResetOwnerKey(
            identity: .providerAccount(id: "fixture-codex-shared-workspace"),
            accountEmail: secondEmail))
        let recorder = WeeklyLimitResetEventRecorder(provider: .codex, accountLabel: secondEmail)
        defer { recorder.invalidate() }

        let firstDate = Date(timeIntervalSince1970: 1_703_700_000)
        let weeklyReset = firstDate.addingTimeInterval(3 * 24 * 3600)
        let nextWeeklyReset = weeklyReset.addingTimeInterval(7 * 24 * 3600)
        let firstMemberHigh = codexWeeklySnapshot(
            accountLabel: firstEmail,
            usedPercent: 86,
            resetsAt: weeklyReset,
            updatedAt: firstDate)
        let secondMemberLow = codexWeeklySnapshot(
            accountLabel: secondEmail,
            usedPercent: 0,
            resetsAt: nextWeeklyReset,
            updatedAt: firstDate.addingTimeInterval(60))

        await store.recordPlanUtilizationHistorySample(
            provider: .codex,
            snapshot: firstMemberHigh,
            codexLimitResetOwnerKey: ownerA,
            now: firstMemberHigh.updatedAt)
        await store.recordPlanUtilizationHistorySample(
            provider: .codex,
            snapshot: secondMemberLow,
            codexLimitResetOwnerKey: ownerB,
            now: secondMemberLow.updatedAt)

        #expect(ownerA != ownerB)
        #expect(store.weeklyLimitResetDetectorStates.count == 2)
        #expect(recorder.events.isEmpty)
    }

    @MainActor
    @Test
    func `codex weekly celebration preserves baseline across a regressed boundary`() async throws {
        let store = Self.makeStore()
        let accountLabel = "codex-weekly-regressed-boundary@example.com"
        let ownerKey = try #require(CodexLimitResetOwnerKey(
            identity: .providerAccount(id: "fixture-codex-weekly-regressed-boundary"),
            accountEmail: accountLabel))
        let recorder = WeeklyLimitResetEventRecorder(provider: .codex, accountLabel: accountLabel)
        defer { recorder.invalidate() }

        let firstDate = Date(timeIntervalSince1970: 1_704_000_000)
        let weeklyReset = firstDate.addingTimeInterval(3 * 24 * 3600)
        let before = codexWeeklySnapshot(
            accountLabel: accountLabel,
            usedPercent: 86,
            resetsAt: weeklyReset,
            updatedAt: firstDate)
        let regressedHigh = codexWeeklySnapshot(
            accountLabel: accountLabel,
            usedPercent: 87,
            resetsAt: weeklyReset.addingTimeInterval(-24 * 3600),
            updatedAt: firstDate.addingTimeInterval(60))
        let transientLow = codexWeeklySnapshot(
            accountLabel: accountLabel,
            usedPercent: 0,
            resetsAt: weeklyReset,
            updatedAt: firstDate.addingTimeInterval(120))
        let realReset = codexWeeklySnapshot(
            accountLabel: accountLabel,
            usedPercent: 0,
            resetsAt: weeklyReset.addingTimeInterval(7 * 24 * 3600),
            updatedAt: firstDate.addingTimeInterval(180))

        for snapshot in [before, regressedHigh, transientLow] {
            await store.recordPlanUtilizationHistorySample(
                provider: .codex,
                snapshot: snapshot,
                codexLimitResetOwnerKey: ownerKey,
                now: snapshot.updatedAt)
        }
        #expect(recorder.events.isEmpty)

        await store.recordPlanUtilizationHistorySample(
            provider: .codex,
            snapshot: realReset,
            codexLimitResetOwnerKey: ownerKey,
            now: realReset.updatedAt)

        #expect(recorder.events.count == 1)
        #expect(recorder.events.first?.usedPercent == 0)
    }

    @MainActor
    @Test
    func `weekly quota celebration posts when weekly usage resets to zero`() async {
        let store = Self.makeStore()
        let accountLabel = "reset-zero@example.com"
        let recorder = WeeklyLimitResetEventRecorder(provider: .claude, accountLabel: accountLabel)
        defer { recorder.invalidate() }

        let before = UsageSnapshot(
            primary: RateWindow(usedPercent: 10, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
            secondary: RateWindow(usedPercent: 99, windowMinutes: 10080, resetsAt: nil, resetDescription: nil),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            identity: ProviderIdentitySnapshot(
                providerID: .claude,
                accountEmail: accountLabel,
                accountOrganization: nil,
                loginMethod: "max"))
        let after = UsageSnapshot(
            primary: RateWindow(usedPercent: 10, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
            secondary: RateWindow(usedPercent: 0, windowMinutes: 10080, resetsAt: nil, resetDescription: nil),
            updatedAt: Date(timeIntervalSince1970: 1_700_003_600),
            identity: ProviderIdentitySnapshot(
                providerID: .claude,
                accountEmail: accountLabel,
                accountOrganization: nil,
                loginMethod: "max"))

        await store.recordPlanUtilizationHistorySample(provider: .claude, snapshot: before, now: before.updatedAt)
        await store.recordPlanUtilizationHistorySample(provider: .claude, snapshot: after, now: after.updatedAt)

        let events = recorder.events
        #expect(events.count == 1)
        #expect(events[0].provider == .claude)
        #expect(events[0].accountLabel == accountLabel)
        #expect(events[0].usedPercent == 0)
    }

    @MainActor
    @Test
    func `weekly quota celebration posts when reset lands mid hour without history split`() async {
        let store = Self.makeStore()
        let accountLabel = "mid-hour-reset@example.com"
        let recorder = WeeklyLimitResetEventRecorder(provider: .claude, accountLabel: accountLabel)
        defer { recorder.invalidate() }

        let before = UsageSnapshot(
            primary: RateWindow(usedPercent: 10, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
            secondary: RateWindow(
                usedPercent: 40,
                windowMinutes: 10080,
                resetsAt: Date(timeIntervalSince1970: 1_700_100_000),
                resetDescription: nil),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            identity: ProviderIdentitySnapshot(
                providerID: .claude,
                accountEmail: accountLabel,
                accountOrganization: nil,
                loginMethod: "max"))
        let after = UsageSnapshot(
            primary: RateWindow(usedPercent: 10, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
            secondary: RateWindow(
                usedPercent: 0,
                windowMinutes: 10080,
                resetsAt: Date(timeIntervalSince1970: 1_700_100_030),
                resetDescription: nil),
            updatedAt: Date(timeIntervalSince1970: 1_700_001_800),
            identity: ProviderIdentitySnapshot(
                providerID: .claude,
                accountEmail: accountLabel,
                accountOrganization: nil,
                loginMethod: "max"))

        await store.recordPlanUtilizationHistorySample(provider: .claude, snapshot: before, now: before.updatedAt)
        await store.recordPlanUtilizationHistorySample(provider: .claude, snapshot: after, now: after.updatedAt)

        let histories = store.planUtilizationHistory(for: .claude)
        #expect(findSeries(histories, name: .weekly, windowMinutes: 10080)?.entries.count == 1)
        #expect(findSeries(histories, name: .weekly, windowMinutes: 10080)?.entries.last?.usedPercent == 40)
        let events = recorder.events
        #expect(events.count == 1)
        #expect(events[0].usedPercent == 0)
    }

    @MainActor
    @Test
    func `weekly quota celebration ignores first seen reset sample`() async {
        let store = Self.makeStore()
        let accountLabel = "first-seen-reset@example.com"
        let recorder = WeeklyLimitResetEventRecorder(provider: .claude, accountLabel: accountLabel)
        defer { recorder.invalidate() }

        let snapshot = UsageSnapshot(
            primary: RateWindow(usedPercent: 10, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
            secondary: RateWindow(usedPercent: 0, windowMinutes: 10080, resetsAt: nil, resetDescription: nil),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            identity: ProviderIdentitySnapshot(
                providerID: .claude,
                accountEmail: accountLabel,
                accountOrganization: nil,
                loginMethod: "max"))

        await store.recordPlanUtilizationHistorySample(provider: .claude, snapshot: snapshot, now: snapshot.updatedAt)

        #expect(recorder.events.isEmpty)
    }

    @MainActor
    @Test
    func `antigravity weekly celebration samples stable named bucket maximum`() async {
        let store = Self.makeStore()
        let recorder = WeeklyLimitResetEventRecorder(provider: .antigravity, accountLabel: nil)
        defer { recorder.invalidate() }

        func snapshot(
            primary: RateWindow,
            secondary: RateWindow,
            geminiWeeklyUsed: Double,
            thirdPartyWeeklyUsed: Double,
            updatedAt: Date) -> UsageSnapshot
        {
            UsageSnapshot(
                primary: primary,
                secondary: secondary,
                tertiary: nil,
                extraRateWindows: [
                    NamedRateWindow(
                        id: "antigravity-quota-summary-gemini-weekly",
                        title: "Gemini Models Weekly Limit",
                        window: RateWindow(
                            usedPercent: geminiWeeklyUsed,
                            windowMinutes: 10080,
                            resetsAt: nil,
                            resetDescription: nil)),
                    NamedRateWindow(
                        id: "antigravity-quota-summary-3p-weekly",
                        title: "Claude and GPT models Weekly Limit",
                        window: RateWindow(
                            usedPercent: thirdPartyWeeklyUsed,
                            windowMinutes: 10080,
                            resetsAt: nil,
                            resetDescription: nil)),
                ],
                updatedAt: updatedAt)
        }

        let firstDate = Date(timeIntervalSince1970: 1_700_000_000)
        let before = snapshot(
            primary: RateWindow(
                usedPercent: 80,
                windowMinutes: 10080,
                resetsAt: nil,
                resetDescription: nil),
            secondary: RateWindow(
                usedPercent: 20,
                windowMinutes: 300,
                resetsAt: nil,
                resetDescription: nil),
            geminiWeeklyUsed: 80,
            thirdPartyWeeklyUsed: 0,
            updatedAt: firstDate)
        let representativeChanged = snapshot(
            primary: RateWindow(
                usedPercent: 20,
                windowMinutes: 300,
                resetsAt: nil,
                resetDescription: nil),
            secondary: RateWindow(
                usedPercent: 0,
                windowMinutes: 10080,
                resetsAt: nil,
                resetDescription: nil),
            geminiWeeklyUsed: 0,
            thirdPartyWeeklyUsed: 80,
            updatedAt: firstDate.addingTimeInterval(3600))
        let reset = snapshot(
            primary: RateWindow(
                usedPercent: 20,
                windowMinutes: 300,
                resetsAt: nil,
                resetDescription: nil),
            secondary: RateWindow(
                usedPercent: 0,
                windowMinutes: 10080,
                resetsAt: nil,
                resetDescription: nil),
            geminiWeeklyUsed: 0,
            thirdPartyWeeklyUsed: 0,
            updatedAt: firstDate.addingTimeInterval(7200))

        await store.recordPlanUtilizationHistorySample(
            provider: .antigravity,
            snapshot: before,
            now: before.updatedAt)
        await store.recordPlanUtilizationHistorySample(
            provider: .antigravity,
            snapshot: representativeChanged,
            now: representativeChanged.updatedAt)
        #expect(recorder.events.isEmpty)

        await store.recordPlanUtilizationHistorySample(
            provider: .antigravity,
            snapshot: reset,
            now: reset.updatedAt)
        #expect(recorder.events.count == 1)
        #expect(recorder.events.first?.usedPercent == 0)
    }

    @MainActor
    @Test
    func `antigravity session celebration follows stable quota summary source`() async {
        let store = Self.makeStore()
        let recorder = SessionLimitResetEventRecorder(provider: .antigravity, accountLabel: nil)
        defer { recorder.invalidate() }

        func summarySnapshot(geminiUsed: Double, thirdPartyUsed: Double, updatedAt: Date) -> UsageSnapshot {
            UsageSnapshot(
                primary: RateWindow(
                    usedPercent: 0,
                    windowMinutes: 300,
                    resetsAt: nil,
                    resetDescription: nil),
                secondary: nil,
                extraRateWindows: [
                    NamedRateWindow(
                        id: "antigravity-quota-summary-gemini-session",
                        title: "Gemini Models",
                        window: RateWindow(
                            usedPercent: geminiUsed,
                            windowMinutes: 300,
                            resetsAt: nil,
                            resetDescription: nil)),
                    NamedRateWindow(
                        id: "antigravity-quota-summary-3p-session",
                        title: "Claude and GPT models",
                        window: RateWindow(
                            usedPercent: thirdPartyUsed,
                            windowMinutes: 300,
                            resetsAt: nil,
                            resetDescription: nil)),
                ],
                updatedAt: updatedAt)
        }

        let firstDate = Date(timeIntervalSince1970: 1_700_000_000)
        let legacy = UsageSnapshot(
            primary: RateWindow(usedPercent: 90, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
            secondary: nil,
            updatedAt: firstDate)
        let sourceChanged = summarySnapshot(
            geminiUsed: 0,
            thirdPartyUsed: 0,
            updatedAt: firstDate.addingTimeInterval(3600))
        let representativeChanged = summarySnapshot(
            geminiUsed: 80,
            thirdPartyUsed: 20,
            updatedAt: firstDate.addingTimeInterval(7200))
        let reset = summarySnapshot(
            geminiUsed: 0,
            thirdPartyUsed: 0,
            updatedAt: firstDate.addingTimeInterval(10800))

        await store.recordPlanUtilizationHistorySample(
            provider: .antigravity,
            snapshot: legacy,
            now: legacy.updatedAt)
        await store.recordPlanUtilizationHistorySample(
            provider: .antigravity,
            snapshot: sourceChanged,
            now: sourceChanged.updatedAt)
        #expect(recorder.events.isEmpty)

        await store.recordPlanUtilizationHistorySample(
            provider: .antigravity,
            snapshot: representativeChanged,
            now: representativeChanged.updatedAt)
        await store.recordPlanUtilizationHistorySample(
            provider: .antigravity,
            snapshot: reset,
            now: reset.updatedAt)
        #expect(recorder.events.count == 1)
        #expect(recorder.events.first?.usedPercent == 0)
    }

    @MainActor
    @Test
    func `weekly quota celebration fires once across repeated low samples`() async {
        let store = Self.makeStore()
        let accountLabel = "repeated-low@example.com"
        let recorder = WeeklyLimitResetEventRecorder(provider: .claude, accountLabel: accountLabel)
        defer { recorder.invalidate() }

        let before = UsageSnapshot(
            primary: RateWindow(usedPercent: 10, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
            secondary: RateWindow(usedPercent: 60, windowMinutes: 10080, resetsAt: nil, resetDescription: nil),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            identity: ProviderIdentitySnapshot(
                providerID: .claude,
                accountEmail: accountLabel,
                accountOrganization: nil,
                loginMethod: "max"))
        let firstLow = UsageSnapshot(
            primary: RateWindow(usedPercent: 10, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
            secondary: RateWindow(usedPercent: 1, windowMinutes: 10080, resetsAt: nil, resetDescription: nil),
            updatedAt: Date(timeIntervalSince1970: 1_700_001_800),
            identity: ProviderIdentitySnapshot(
                providerID: .claude,
                accountEmail: accountLabel,
                accountOrganization: nil,
                loginMethod: "max"))
        let secondLow = UsageSnapshot(
            primary: RateWindow(usedPercent: 10, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
            secondary: RateWindow(usedPercent: 0, windowMinutes: 10080, resetsAt: nil, resetDescription: nil),
            updatedAt: Date(timeIntervalSince1970: 1_700_002_100),
            identity: ProviderIdentitySnapshot(
                providerID: .claude,
                accountEmail: accountLabel,
                accountOrganization: nil,
                loginMethod: "max"))

        await store.recordPlanUtilizationHistorySample(provider: .claude, snapshot: before, now: before.updatedAt)
        await store.recordPlanUtilizationHistorySample(provider: .claude, snapshot: firstLow, now: firstLow.updatedAt)
        await store.recordPlanUtilizationHistorySample(provider: .claude, snapshot: secondLow, now: secondLow.updatedAt)

        let events = recorder.events
        #expect(events.count == 1)
        #expect(events[0].usedPercent == 1)
    }

    @MainActor
    @Test
    func `weekly quota celebration posts for generic provider weekly lane`() async {
        let store = Self.makeStore()
        let accountLabel = "zai-reset-org"
        let recorder = WeeklyLimitResetEventRecorder(provider: .zai, accountLabel: accountLabel)
        defer { recorder.invalidate() }

        let before = UsageSnapshot(
            primary: RateWindow(usedPercent: 92, windowMinutes: 10080, resetsAt: nil, resetDescription: nil),
            secondary: RateWindow(usedPercent: 15, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            identity: ProviderIdentitySnapshot(
                providerID: .zai,
                accountEmail: nil,
                accountOrganization: accountLabel,
                loginMethod: "pro"))
        let after = UsageSnapshot(
            primary: RateWindow(usedPercent: 0, windowMinutes: 10080, resetsAt: nil, resetDescription: nil),
            secondary: RateWindow(usedPercent: 15, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
            updatedAt: Date(timeIntervalSince1970: 1_700_003_600),
            identity: ProviderIdentitySnapshot(
                providerID: .zai,
                accountEmail: nil,
                accountOrganization: accountLabel,
                loginMethod: "pro"))

        await store.recordPlanUtilizationHistorySample(provider: .zai, snapshot: before, now: before.updatedAt)
        await store.recordPlanUtilizationHistorySample(provider: .zai, snapshot: after, now: after.updatedAt)

        let events = recorder.events
        #expect(events.count == 1)
        #expect(events[0].provider == .zai)
        #expect(events[0].accountLabel == accountLabel)
        #expect(events[0].usedPercent == 0)
    }

    @MainActor
    @Test
    func `session quota celebration uses copilot secondary fallback without history sample`() async {
        let store = Self.makeStore()
        let accountLabel = "copilot-session-reset@example.com"
        let recorder = SessionLimitResetEventRecorder(provider: .copilot, accountLabel: accountLabel)
        defer { recorder.invalidate() }

        let before = UsageSnapshot(
            primary: nil,
            secondary: RateWindow(usedPercent: 88, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            identity: ProviderIdentitySnapshot(
                providerID: .copilot,
                accountEmail: accountLabel,
                accountOrganization: nil,
                loginMethod: "github"))
        let after = UsageSnapshot(
            primary: nil,
            secondary: RateWindow(usedPercent: 0, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
            updatedAt: Date(timeIntervalSince1970: 1_700_003_600),
            identity: ProviderIdentitySnapshot(
                providerID: .copilot,
                accountEmail: accountLabel,
                accountOrganization: nil,
                loginMethod: "github"))

        await store.recordPlanUtilizationHistorySample(provider: .copilot, snapshot: before, now: before.updatedAt)
        await store.recordPlanUtilizationHistorySample(provider: .copilot, snapshot: after, now: after.updatedAt)

        let events = recorder.events
        #expect(events.count == 1)
        #expect(events[0].provider == .copilot)
        #expect(events[0].accountLabel == accountLabel)
        #expect(events[0].usedPercent == 0)
        #expect(store.planUtilizationHistory(for: .copilot).isEmpty)
    }

    @MainActor
    @Test
    func `session quota celebration uses generic provider canonical primary without history sample`() async {
        let store = Self.makeStore()
        let accountLabel = "zai-session-reset-org"
        let recorder = SessionLimitResetEventRecorder(provider: .zai, accountLabel: accountLabel)
        defer { recorder.invalidate() }

        func snapshot(usedPercent: Double, updatedAt: Date) -> UsageSnapshot {
            UsageSnapshot(
                primary: RateWindow(
                    usedPercent: usedPercent,
                    windowMinutes: 300,
                    resetsAt: nil,
                    resetDescription: nil),
                secondary: nil,
                updatedAt: updatedAt,
                identity: ProviderIdentitySnapshot(
                    providerID: .zai,
                    accountEmail: nil,
                    accountOrganization: accountLabel,
                    loginMethod: "pro"))
        }

        let before = snapshot(usedPercent: 88, updatedAt: Date(timeIntervalSince1970: 1_700_000_000))
        let after = snapshot(usedPercent: 0, updatedAt: Date(timeIntervalSince1970: 1_700_003_600))

        await store.recordPlanUtilizationHistorySample(provider: .zai, snapshot: before, now: before.updatedAt)
        await store.recordPlanUtilizationHistorySample(provider: .zai, snapshot: after, now: after.updatedAt)

        #expect(recorder.events.count == 1)
        #expect(recorder.events.first?.usedPercent == 0)
        #expect(store.planUtilizationHistory(for: .zai).isEmpty)
    }

    @MainActor
    @Test
    func `session quota celebration ignores unknown duration credit pool`() async {
        let store = Self.makeStore()
        let accountLabel = "elevenlabs-monthly-reset@example.com"
        let recorder = SessionLimitResetEventRecorder(provider: .elevenlabs, accountLabel: accountLabel)
        defer { recorder.invalidate() }

        func snapshot(usedPercent: Double, updatedAt: Date) -> UsageSnapshot {
            UsageSnapshot(
                primary: RateWindow(
                    usedPercent: usedPercent,
                    windowMinutes: nil,
                    resetsAt: nil,
                    resetDescription: "Monthly credits"),
                secondary: nil,
                updatedAt: updatedAt,
                identity: ProviderIdentitySnapshot(
                    providerID: .elevenlabs,
                    accountEmail: accountLabel,
                    accountOrganization: nil,
                    loginMethod: "api-key"))
        }

        let before = snapshot(usedPercent: 88, updatedAt: Date(timeIntervalSince1970: 1_700_000_000))
        let after = snapshot(usedPercent: 0, updatedAt: Date(timeIntervalSince1970: 1_700_003_600))

        await store.recordPlanUtilizationHistorySample(provider: .elevenlabs, snapshot: before, now: before.updatedAt)
        await store.recordPlanUtilizationHistorySample(provider: .elevenlabs, snapshot: after, now: after.updatedAt)

        #expect(recorder.events.isEmpty)
        #expect(store.sessionLimitResetDetectorStates.isEmpty)
    }

    @MainActor
    @Test
    func `session quota celebration uses zai semantic tertiary session lane`() async {
        let store = Self.makeStore()
        let accountLabel = "zai-semantic-session-org"
        let recorder = SessionLimitResetEventRecorder(provider: .zai, accountLabel: accountLabel)
        defer { recorder.invalidate() }

        func snapshot(sessionUsed: Double, updatedAt: Date) -> UsageSnapshot {
            UsageSnapshot(
                primary: RateWindow(
                    usedPercent: 30,
                    windowMinutes: 10080,
                    resetsAt: nil,
                    resetDescription: nil),
                secondary: RateWindow(
                    usedPercent: 40,
                    windowMinutes: 43200,
                    resetsAt: nil,
                    resetDescription: "Monthly"),
                tertiary: RateWindow(
                    usedPercent: sessionUsed,
                    windowMinutes: 300,
                    resetsAt: nil,
                    resetDescription: nil),
                updatedAt: updatedAt,
                identity: ProviderIdentitySnapshot(
                    providerID: .zai,
                    accountEmail: nil,
                    accountOrganization: accountLabel,
                    loginMethod: "pro"))
        }

        let before = snapshot(sessionUsed: 88, updatedAt: Date(timeIntervalSince1970: 1_700_000_000))
        let after = snapshot(sessionUsed: 0, updatedAt: Date(timeIntervalSince1970: 1_700_003_600))

        await store.recordPlanUtilizationHistorySample(provider: .zai, snapshot: before, now: before.updatedAt)
        await store.recordPlanUtilizationHistorySample(provider: .zai, snapshot: after, now: after.updatedAt)

        #expect(recorder.events.count == 1)
        #expect(recorder.events.first?.usedPercent == 0)
        #expect(store.sessionLimitResetDetectorStates.values.first?.sourceRawValue == "zaiTertiary")
    }

    @MainActor
    @Test
    func `session quota celebration keeps account baselines isolated`() async {
        let store = Self.makeStore()
        let accountLabel = "session-reset-b@example.com"
        let recorder = SessionLimitResetEventRecorder(provider: .claude, accountLabel: accountLabel)
        defer { recorder.invalidate() }

        func snapshot(account: String, usedPercent: Double, updatedAt: Date) -> UsageSnapshot {
            UsageSnapshot(
                primary: RateWindow(
                    usedPercent: usedPercent,
                    windowMinutes: 300,
                    resetsAt: nil,
                    resetDescription: nil),
                secondary: RateWindow(
                    usedPercent: 20,
                    windowMinutes: 10080,
                    resetsAt: nil,
                    resetDescription: nil),
                updatedAt: updatedAt,
                identity: ProviderIdentitySnapshot(
                    providerID: .claude,
                    accountEmail: account,
                    accountOrganization: nil,
                    loginMethod: "max"))
        }

        let firstDate = Date(timeIntervalSince1970: 1_700_000_000)
        let accountAHigh = snapshot(account: "session-reset-a@example.com", usedPercent: 80, updatedAt: firstDate)
        let accountBLow = snapshot(account: accountLabel, usedPercent: 0, updatedAt: firstDate.addingTimeInterval(3600))
        let accountBHigh = snapshot(
            account: accountLabel,
            usedPercent: 80,
            updatedAt: firstDate.addingTimeInterval(7200))
        let accountBReset = snapshot(
            account: accountLabel,
            usedPercent: 0,
            updatedAt: firstDate.addingTimeInterval(10800))

        await store.recordPlanUtilizationHistorySample(
            provider: .claude,
            snapshot: accountAHigh,
            now: accountAHigh.updatedAt)
        await store.recordPlanUtilizationHistorySample(
            provider: .claude,
            snapshot: accountBLow,
            now: accountBLow.updatedAt)
        #expect(recorder.events.isEmpty)

        await store.recordPlanUtilizationHistorySample(
            provider: .claude,
            snapshot: accountBHigh,
            now: accountBHigh.updatedAt)
        await store.recordPlanUtilizationHistorySample(
            provider: .claude,
            snapshot: accountBReset,
            now: accountBReset.updatedAt)
        #expect(recorder.events.count == 1)
    }

    @MainActor
    @Test
    func `session quota celebration ignores command code subscription enrichment failure`() async {
        let store = Self.makeStore()
        let recorder = SessionLimitResetEventRecorder(provider: .commandcode, accountLabel: nil)
        defer { recorder.invalidate() }

        func snapshot(usedPercent: Double, enrichmentUnavailable: Bool, updatedAt: Date) -> UsageSnapshot {
            UsageSnapshot(
                primary: RateWindow(
                    usedPercent: usedPercent,
                    windowMinutes: 300,
                    resetsAt: nil,
                    resetDescription: nil),
                secondary: nil,
                commandCodeSubscriptionEnrichmentUnavailable: enrichmentUnavailable,
                updatedAt: updatedAt)
        }

        let firstDate = Date(timeIntervalSince1970: 1_700_000_000)
        let before = snapshot(usedPercent: 80, enrichmentUnavailable: false, updatedAt: firstDate)
        let failedEnrichment = snapshot(
            usedPercent: 0,
            enrichmentUnavailable: true,
            updatedAt: firstDate.addingTimeInterval(3600))
        let validReset = snapshot(
            usedPercent: 0,
            enrichmentUnavailable: false,
            updatedAt: firstDate.addingTimeInterval(7200))

        await store.recordPlanUtilizationHistorySample(provider: .commandcode, snapshot: before, now: before.updatedAt)
        await store.recordPlanUtilizationHistorySample(
            provider: .commandcode,
            snapshot: failedEnrichment,
            now: failedEnrichment.updatedAt)
        #expect(recorder.events.isEmpty)

        await store.recordPlanUtilizationHistorySample(
            provider: .commandcode,
            snapshot: validReset,
            now: validReset.updatedAt)
        #expect(recorder.events.count == 1)
    }

    @MainActor
    @Test
    func `session quota celebration does not infer arbitrary secondary session lane`() async {
        let store = Self.makeStore()
        let recorder = SessionLimitResetEventRecorder(provider: .zai, accountLabel: nil)
        defer { recorder.invalidate() }

        let before = UsageSnapshot(
            primary: RateWindow(usedPercent: 30, windowMinutes: 10080, resetsAt: nil, resetDescription: nil),
            secondary: RateWindow(usedPercent: 88, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000))
        let after = UsageSnapshot(
            primary: RateWindow(usedPercent: 30, windowMinutes: 10080, resetsAt: nil, resetDescription: nil),
            secondary: RateWindow(usedPercent: 0, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
            updatedAt: Date(timeIntervalSince1970: 1_700_003_600))

        await store.recordPlanUtilizationHistorySample(provider: .zai, snapshot: before, now: before.updatedAt)
        await store.recordPlanUtilizationHistorySample(provider: .zai, snapshot: after, now: after.updatedAt)

        #expect(recorder.events.isEmpty)
    }
}

private func codexWeeklySnapshot(
    accountLabel: String,
    usedPercent: Double,
    resetsAt: Date?,
    updatedAt: Date) -> UsageSnapshot
{
    UsageSnapshot(
        primary: RateWindow(
            usedPercent: usedPercent,
            windowMinutes: 10080,
            resetsAt: resetsAt,
            resetDescription: nil),
        secondary: RateWindow(
            usedPercent: 14,
            windowMinutes: 300,
            resetsAt: nil,
            resetDescription: nil),
        updatedAt: updatedAt,
        identity: ProviderIdentitySnapshot(
            providerID: .codex,
            accountEmail: accountLabel,
            accountOrganization: nil,
            loginMethod: "test"))
}

final class SessionLimitResetEventRecorder: @unchecked Sendable {
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

final class WeeklyLimitResetEventRecorder: @unchecked Sendable {
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

    var count: Int {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.observedEvents.count
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
