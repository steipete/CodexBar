import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
struct WidgetDetailSnapshotTests {
    @Test
    func `widget JSON carries account owned cloud credits without changing quota rows`() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let settings = testSettingsStore(
            suiteName: "WidgetDetailSnapshotTests",
            config: testConfigWithAllProvidersDisabled())
        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(homeDirectory: root.path, fileExists: { _ in false }),
            settings: settings,
            startupBehavior: .testing,
            environmentBase: [:],
            widgetSnapshotURL: root.appendingPathComponent("widget.json"))
        let details = try [ProviderDetailSection(title: "Cloud credits", rows: [
            ProviderDetailSection.Row(
                id: "claude-cloud-credits",
                label: "Cloud credits",
                value: "$249.27 of $250.00 remaining",
                secondaryValue: "Expires 2026-11-05T07:59:00Z",
                progress: .init(used: 0.73, total: 250),
                usageValue: 249.27),
        ])]
        let now = Date(timeIntervalSince1970: 1_789_473_600)
        let quota = RateWindow(usedPercent: 25, windowMinutes: 300, resetsAt: nil, resetDescription: nil)
        store._setSnapshotForTesting(
            UsageSnapshot(primary: quota, secondary: quota, details: details, updatedAt: now),
            provider: .claude)
        store._setSnapshotForTesting(
            UsageSnapshot(primary: quota, secondary: nil, updatedAt: now), provider: .codex)
        var saved: WidgetSnapshot?
        store._test_widgetSnapshotSaveOverride = { saved = $0 }
        defer { store._test_widgetSnapshotSaveOverride = nil }
        store.persistWidgetSnapshot(reason: "cloud-credits-regression")
        await store.widgetSnapshotPersistTask?.value

        let snapshot = try #require(saved)
        let encoder = JSONEncoder()
        let data = try encoder.encode(snapshot)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let entries = try #require(json["entries"] as? [[String: Any]])
        let claude = try #require(entries.first { $0["provider"] as? String == "claude" })
        let exported = try #require(claude["details"])
        let decoded = try JSONDecoder().decode(
            [ProviderDetailSection].self,
            from: JSONSerialization.data(withJSONObject: exported))
        #expect(decoded == details)
        #expect(snapshot.entries.first { $0.provider == .claude }?.usageRows?.map(\.id)
            == ["primary", "secondary"])
        let codex = try #require(entries.first { $0["provider"] as? String == "codex" })
        #expect(codex["details"] == nil)
    }
}
