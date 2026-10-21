import CodexBarCore
import CryptoKit
import Foundation
import Testing
@testable import CodexBar

@MainActor
struct KiroPlanUtilizationHistoryTests {
    @Test
    func `record plan history stores kiro monthly credits series`() async {
        let store = Self.makeStore()
        store.settings.historicalTrackingEnabled = true
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let snapshot = KiroUsageSnapshot(
            planName: "KIRO POWER",
            creditsUsed: 1666.37,
            creditsTotal: 10000,
            creditsPercent: 16.6637,
            bonusCreditsUsed: 5,
            bonusCreditsTotal: 20,
            bonusExpiryDays: 14,
            resetsAt: now.addingTimeInterval(20 * 24 * 60 * 60),
            updatedAt: now).toUsageSnapshot()

        await store.recordPlanUtilizationHistorySample(provider: .kiro, snapshot: snapshot, now: now)

        let histories = store.planUtilizationHistory(for: .kiro)
        #expect(histories.count == 1)
        #expect(findSeries(histories, name: .monthly, windowMinutes: 43200)?.entries.last?.usedPercent == 16.6637)
    }

    @Test
    func `kiro history requires tracking and a known reset`() async {
        let store = Self.makeStore()
        await store.recordPlanUtilizationHistorySample(provider: .kiro, snapshot: Self.snapshot(), now: Self.now)
        #expect(store.planUtilizationHistory(for: .kiro).isEmpty)
        store.settings.historicalTrackingEnabled = true
        await store.recordPlanUtilizationHistorySample(
            provider: .kiro, snapshot: Self.snapshot(reset: nil), now: Self.now)
        #expect(store.planUtilizationHistory(for: .kiro).isEmpty)
    }

    @Test
    func `kiro history coalesces hourly peaks and persists separate account keys`() async throws {
        let store = Self.makeStore()
        store.settings.historicalTrackingEnabled = true
        let alice = Self.snapshot(email: " Alice@Example.com ")
        let key = try #require(UsageStore.planUtilizationIdentityAccountKey(provider: .kiro, snapshot: alice))
        let expectedKey = SHA256.hash(data: Data("kiro:email:alice@example.com".utf8))
            .map { String(format: "%02x", $0) }.joined()
        #expect(key == expectedKey)
        for (offset, used) in [(0.0, 10.0), (1200, 20), (2400, 15), (3600, 30)] {
            await store.recordPlanUtilizationHistorySample(
                provider: .kiro,
                snapshot: Self.snapshot(email: "alice@example.com", used: used),
                now: Self.now.addingTimeInterval(offset))
        }
        await store.recordPlanUtilizationHistorySample(
            provider: .kiro, snapshot: Self.snapshot(email: "bob@example.com", used: 5), now: Self.now)
        let buckets = try #require(store.planUtilizationHistory[.kiro])
        #expect(buckets.accounts.count == 2)
        #expect(buckets.accounts[key]?.first?.entries.map(\.usedPercent) == [20, 30])
        #expect(buckets.unscoped.isEmpty)

        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let disk = PlanUtilizationHistoryStore(directoryURL: root)
        disk.save([.kiro: buckets])
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["kiro.json"])
        #expect(disk.load()[.kiro] == buckets)
    }

    @Test
    func `kiro monthly history retains the shared sample cap`() throws {
        let cap = UsageStore._planUtilizationMaxSamplesForTesting
        #expect(cap == 17520)
        let history = planSeries(name: .monthly, windowMinutes: 43200, entries: (0..<cap).map {
            planEntry(at: Self.now.addingTimeInterval(Double($0) * 3600), usedPercent: 10)
        })
        let newest = planEntry(at: Self.now.addingTimeInterval(Double(cap) * 3600), usedPercent: 20)
        let updated = try #require(UsageStore._updatedPlanUtilizationHistoriesForTesting(
            existingHistories: [history],
            samples: [planSeries(name: .monthly, windowMinutes: 43200, entries: [newest])]))
        #expect(updated.count == 1)
        #expect(updated[0].entries.count == cap)
        #expect(updated[0].entries.first?.capturedAt == Self.now.addingTimeInterval(3600))
        #expect(updated[0].entries.last == newest)
    }

    @Test(arguments: [
        ("2026-02-01T00:00:00Z", "2026-03-01T00:00:00Z"),
        ("2028-02-01T00:00:00Z", "2028-03-01T00:00:00Z"),
        ("2026-09-01T00:00:00Z", "2026-10-01T00:00:00Z"),
        ("2026-10-01T00:00:00Z", "2026-11-01T00:00:00Z"),
    ])
    func `kiro pace uses the actual cycle and expires at reset`(start: String, reset: String) throws {
        let start = try #require(ISO8601DateFormatter().date(from: start))
        let reset = try #require(ISO8601DateFormatter().date(from: reset))
        let store = Self.makeStore()
        let window = try #require(Self.snapshot(used: 60, reset: reset).primary)
        let halfway = start.addingTimeInterval(reset.timeIntervalSince(start) / 2)
        let pace = try #require(store.weeklyPace(
            provider: .kiro, window: window, dataConfidence: .exact, now: halfway))
        #expect(abs(pace.expectedUsedPercent - 50) < 0.0001)
        #expect(abs(pace.deltaPercent - 10) < 0.0001)
        for boundary in [start.addingTimeInterval(-1), start, reset, reset.addingTimeInterval(1)] {
            #expect(store.weeklyPace(
                provider: .kiro, window: window, dataConfidence: .exact, now: boundary) == nil)
        }
    }

    @Test
    func `kiro widget keeps credits and bonus rows with the monthly reset`() async throws {
        let store = Self.makeStore()
        let snapshot = Self.snapshot()
        store._setSnapshotForTesting(snapshot, provider: .kiro)
        var saved: WidgetSnapshot?
        store._test_widgetSnapshotSaveOverride = { saved = $0 }
        defer { store._test_widgetSnapshotSaveOverride = nil }
        store.persistWidgetSnapshot(reason: "kiro-monthly-test")
        await store.widgetSnapshotPersistTask?.value
        let entry = try #require(saved?.entries.first { $0.provider == .kiro })
        #expect(entry.usageRows?.map(\.title) == ["Credits", "Bonus"])
        #expect(entry.usageRows?.compactMap(\.percentLeft) == [40, 75])
        #expect(entry.primary == snapshot.primary)
        #expect(entry.secondary?.windowMinutes == nil)
    }

    static let now = Date(timeIntervalSince1970: 1_792_022_400)
    static let reset = Date(timeIntervalSince1970: 1_793_491_200)

    static func snapshot(email: String? = nil, used: Double = 60, reset: Date? = Self.reset) -> UsageSnapshot {
        KiroUsageSnapshot(
            planName: "KIRO POWER",
            accountEmail: email,
            creditsUsed: used * 100,
            creditsTotal: 10000,
            creditsPercent: used,
            bonusCreditsUsed: 5,
            bonusCreditsTotal: 20,
            bonusExpiryDays: nil,
            resetsAt: reset,
            updatedAt: self.now).toUsageSnapshot()
    }

    static func makeStore() -> UsageStore {
        let suite = "KiroHistory-\(UUID().uuidString)"
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        let settings = testSettingsStore(
            suiteName: suite, userDefaults: InMemoryUserDefaults(), config: testConfigWithAllProvidersDisabled())
        settings.historicalTrackingEnabled = false
        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(homeDirectory: root.path, fileExists: { _ in false }),
            settings: settings,
            planUtilizationHistoryStore: testPlanUtilizationHistoryStore(suiteName: suite),
            startupBehavior: .testing,
            environmentBase: [:],
            widgetSnapshotURL: root.appendingPathComponent("widget.json"))
        store._cancelPlanUtilizationHistoryLoadForTesting()
        store.planUtilizationHistory = [:]
        return store
    }
}
