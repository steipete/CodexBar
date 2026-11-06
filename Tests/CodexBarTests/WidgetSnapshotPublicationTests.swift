import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
struct WidgetSnapshotPublicationTests {
    @Test
    func `identical publications preserve the original empty snapshot age without another reload`() async throws {
        let url = Self.temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var publication: UsageStore.WidgetSnapshotPublication?
        var reloads = 0
        var firstFileID: NSNumber?
        for generation in [now, now.addingTimeInterval(3 * 86400)] {
            publication = await UsageStore.saveWidgetSnapshot(
                WidgetSnapshot(
                    entries: [],
                    accounts: [.init(id: "fixture", provider: .codex, label: "Account 1", usage: nil)],
                    generatedAt: generation),
                to: url,
                previousPublication: publication,
                isRunningTests: false,
                reloadTimelines: { reloads += 1 })
            let fileID = try FileManager.default.attributesOfItem(atPath: url.path)[.systemFileNumber] as? NSNumber
            if let firstFileID { #expect(fileID == firstFileID) } else { firstFileID = fileID }
        }
        #expect(reloads == 1)
        #expect(WidgetSnapshotStore.load(from: url)?.generatedAt == now)
    }

    @Test
    func `measurement quota token account and setting changes each publish`() async {
        let url = Self.temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var publication: UsageStore.WidgetSnapshotPublication?
        var reloads = 0
        for step in 0...5 {
            let usage = WidgetSnapshot.ProviderEntry(
                provider: .codex,
                updatedAt: step >= 1 ? now.addingTimeInterval(300) : now,
                primary: RateWindow(
                    usedPercent: step >= 2 ? 50 : 25,
                    windowMinutes: 300,
                    resetsAt: nil,
                    resetDescription: nil),
                secondary: nil,
                tokenUsage: .init(
                    sessionCostUSD: 1,
                    sessionTokens: 10,
                    last30DaysCostUSD: 30,
                    last30DaysTokens: 300,
                    updatedAt: step >= 3 ? now.addingTimeInterval(300) : now))
            let snapshot = WidgetSnapshot(
                entries: [usage],
                accounts: [.init(
                    id: "fixture",
                    provider: .codex,
                    label: step >= 4 ? "Account 2" : "Account 1",
                    usage: nil)],
                usageBarsShowUsed: step >= 5,
                generatedAt: now)
            publication = await UsageStore.saveWidgetSnapshot(
                snapshot,
                to: url,
                previousPublication: publication,
                isRunningTests: false,
                reloadTimelines: {
                    reloads += 1
                    #expect(WidgetSnapshotStore.load(from: url)?.usageBarsShowUsed == snapshot.usageBarsShowUsed)
                })
            #expect(reloads == step + 1)
        }
    }

    @Test
    func `restart removal external rewrite and failed save cannot suppress the next publication`() async throws {
        let url = Self.temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let snapshot = WidgetSnapshot(entries: [], generatedAt: Date(timeIntervalSince1970: 1_800_000_000))
        var publication: UsageStore.WidgetSnapshotPublication?
        var reloads = 0
        func publish() async {
            publication = await UsageStore.saveWidgetSnapshot(
                snapshot,
                to: url,
                previousPublication: publication,
                isRunningTests: false,
                reloadTimelines: { reloads += 1 })
        }
        await publish()
        publication = nil // A new app process has no publication fingerprint, including after schema upgrades.
        await publish()
        #expect(reloads == 2)

        try FileManager.default.removeItem(at: url)
        await publish()
        #expect(reloads == 3)

        // Even a valid external rewrite changing only generatedAt must be repaired.
        var external = snapshot
        external.generatedAt = snapshot.generatedAt.addingTimeInterval(60)
        WidgetSnapshotStore.save(external, to: url)
        await publish()
        #expect(reloads == 4)
        #expect(WidgetSnapshotStore.load(from: url)?.generatedAt == snapshot.generatedAt)

        try FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        await publish()
        #expect(publication == nil)
        #expect(reloads == 5)
        try FileManager.default.removeItem(at: url)
        await publish()
        #expect(publication != nil)
        #expect(reloads == 6)
    }

    @Test
    func `queued publications compare against the last successful write`() async throws {
        let url = Self.temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let settings = testSettingsStore(
            suiteName: "WidgetSnapshotPublicationTests", config: testConfigWithAllProvidersDisabled())
        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing,
            environmentBase: [:],
            widgetSnapshotURL: url)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        store._setSnapshotForTesting(UsageSnapshot(
            primary: RateWindow(usedPercent: 25, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
            secondary: nil,
            updatedAt: now), provider: .gemini)
        store.persistWidgetSnapshot(reason: "refresh")
        await store.widgetSnapshotPersistTask?.value
        let first = try Data(contentsOf: url)
        let fileID = try FileManager.default.attributesOfItem(atPath: url.path)[.systemFileNumber] as? NSNumber
        store.persistWidgetSnapshot(reason: "token-usage")
        await store.widgetSnapshotPersistTask?.value
        #expect(try FileManager.default.attributesOfItem(atPath: url.path)[.systemFileNumber] as? NSNumber == fileID)
        for _ in 0..<3 {
            store.persistWidgetSnapshot(reason: "token-usage")
        }
        await store.widgetSnapshotPersistTask?.value
        #expect(try Data(contentsOf: url) == first)
        #expect(try FileManager.default.attributesOfItem(atPath: url.path)[.systemFileNumber] as? NSNumber == fileID)
    }

    private static func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("WidgetPublication-\(UUID().uuidString).json")
    }
}
