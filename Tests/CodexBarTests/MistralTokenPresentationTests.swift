import AppKit
import SwiftUI
import Testing
@testable import CodexBar
@testable import CodexBarCore

@MainActor
@Suite(.serialized)
struct MistralTokenPresentationTests {
    private static let now = Date(timeIntervalSince1970: 1_789_200_000)

    @Test
    func `normal billing totals and model rankings retain their display`() throws {
        try CodexBarLocalizationOverride.$appLanguage.withValue("en") {
            let snapshot = Self.normalSnapshot()
            #expect(Self.summary(snapshot) == [
                "Latest: $9.25 · 26 tokens",
                "Month: $12.50 · 38 tokens",
                "Top model: fixture-beta",
            ])
            let dashboard = try #require(UsageMenuCardView.Model.inlineUsageDashboard(input: Self.input(snapshot)))
            #expect(dashboard.detailLines.contains("Top model: fixture-beta"))
            #expect(dashboard.kpis.contains { $0.value == "$9.25" })
            try Self.capture("normal", snapshot: snapshot, dashboard: dashboard)
        }
    }

    @Test(arguments: [false, true])
    func `public snapshots retain costs when combined counts overflow`(roundTrip: Bool) throws {
        try CodexBarLocalizationOverride.$appLanguage.withValue("en") {
            var snapshot = Self.snapshot(input: Int.max, cached: 1, daily: [
                .init(
                    day: "2026-09-02",
                    cost: 9.25,
                    inputTokens: Int.max,
                    cachedTokens: 1,
                    outputTokens: 0,
                    models: [.init(
                        name: "fixture-overflow",
                        cost: 9.25,
                        inputTokens: Int.max,
                        cachedTokens: 1,
                        outputTokens: 0)]),
            ])
            if roundTrip {
                snapshot = try JSONDecoder().decode(
                    MistralUsageSnapshot.self, from: JSONEncoder().encode(snapshot))
            }
            #expect(Self.summary(snapshot) == ["Latest: $9.25", "Month: $9.25"])
            let dashboard = try #require(UsageMenuCardView.Model.inlineUsageDashboard(input: Self.input(snapshot)))
            #expect(dashboard.kpis.contains { $0.value == "$9.25" })
            #expect(snapshot.toCostUsageTokenSnapshot().daily.first?.modelBreakdowns?.first?.costUSD == 9.25)
            if !roundTrip { try Self.capture("overflow-counts", snapshot: snapshot, dashboard: dashboard) }
        }
    }

    @Test
    func `latest and month token availability are independent`() {
        CodexBarLocalizationOverride.$appLanguage.withValue("en") {
            let latestValid = Self.snapshot(input: Int.max, cached: 1, daily: [
                .init(day: "2026-09-02", cost: 9.25, inputTokens: 7, cachedTokens: 0, outputTokens: 0, models: []),
            ])
            #expect(Self.summary(latestValid) == ["Latest: $9.25 · 7 tokens", "Month: $9.25"])
            let monthValid = Self.snapshot(input: 7, daily: [
                .init(
                    day: "2026-09-02",
                    cost: 9.25,
                    inputTokens: Int.max,
                    cachedTokens: 1,
                    outputTokens: 0,
                    models: []),
            ])
            #expect(Self.summary(monthValid) == ["Latest: $9.25", "Month: $9.25 · 7 tokens"])
        }
    }

    @Test
    func `a named overflow invalidates the whole ranking without dropping cost data`() throws {
        try CodexBarLocalizationOverride.$appLanguage.withValue("en") {
            let snapshot = Self.inconsistentModelSnapshot()
            #expect(Self.summary(snapshot) == ["Latest: $9.25 · 2 tokens", "Month: $12.50 · 3 tokens"])
            let projected = snapshot.toCostUsageTokenSnapshot()
            #expect(projected.last30DaysTokens == 3)
            #expect(projected.daily.flatMap { $0.modelBreakdowns ?? [] }.count == 3)
            let dashboard = try #require(UsageMenuCardView.Model.inlineUsageDashboard(input: Self.input(snapshot)))
            #expect(!dashboard.detailLines.contains { $0.hasPrefix("Top model:") })
            #expect(dashboard.kpis.contains { $0.value == "$12.50" })
            try Self.capture("overflow-ranking", snapshot: snapshot, dashboard: dashboard)
        }
    }

    @Test
    func `inline ranking checks only the emitted history window`() throws {
        try CodexBarLocalizationOverride.$appLanguage.withValue("en") {
            let snapshot = Self.inconsistentModelSnapshot()
            let projected = snapshot.toCostUsageTokenSnapshot(historyDays: 11)
            #expect(projected.daily.map(\.date) == ["2026-09-02"])
            let dashboard = try #require(UsageMenuCardView.Model.inlineUsageDashboard(
                input: Self.input(snapshot, historyDays: 11, tokenOnly: true)))
            #expect(dashboard.detailLines.contains("Top model: fixture-overflow"))
            #expect(dashboard.kpis.contains { $0.value == "$9.25" })
        }
    }

    @Test
    func `named rankings sum signed daily scalars and preserve alphabetical ties`() {
        CodexBarLocalizationOverride.$appLanguage.withValue("en") {
            let snapshot = Self.snapshot(input: 0, daily: [
                .init(
                    day: "2026-09-01",
                    cost: 1,
                    inputTokens: 0,
                    cachedTokens: 0,
                    outputTokens: 0,
                    models: [.init(
                        name: "fixture-alpha", cost: 1, inputTokens: Int.max, cachedTokens: 0, outputTokens: 0)]),
                .init(
                    day: "2026-09-02",
                    cost: 2,
                    inputTokens: 0,
                    cachedTokens: 0,
                    outputTokens: 0,
                    models: [
                        .init(name: "fixture-alpha", cost: 1, inputTokens: 1, cachedTokens: 0, outputTokens: -1),
                        .init(name: "fixture-beta", cost: 1, inputTokens: Int.max, cachedTokens: 0, outputTokens: 0),
                    ]),
            ])
            #expect(Self.summary(snapshot).last == "Top model: fixture-alpha")
        }
    }

    private static func inconsistentModelSnapshot() -> MistralUsageSnapshot {
        self.snapshot(input: 3, daily: [
            .init(
                day: "2026-09-01",
                cost: 3.25,
                inputTokens: 1,
                cachedTokens: 0,
                outputTokens: 0,
                models: [.init(
                    name: "fixture-overflow", cost: 3.25, inputTokens: Int.max, cachedTokens: 0, outputTokens: 0)]),
            .init(
                day: "2026-09-02",
                cost: 9.25,
                inputTokens: 2,
                cachedTokens: 0,
                outputTokens: 0,
                models: [
                    .init(name: "fixture-overflow", cost: 9, inputTokens: 1, cachedTokens: 0, outputTokens: 0),
                    .init(name: "fixture-other", cost: 0.25, inputTokens: 1, cachedTokens: 0, outputTokens: 0),
                ]),
        ])
    }

    private static func snapshot(
        input: Int,
        cached: Int = 0,
        output: Int = 0,
        daily: [MistralDailyUsageBucket]) -> MistralUsageSnapshot
    {
        .init(
            totalCost: daily.reduce(0) { $0 + $1.cost },
            currency: "USD",
            currencySymbol: "$",
            totalInputTokens: input,
            totalOutputTokens: output,
            totalCachedTokens: cached,
            modelCount: 2,
            daily: daily,
            startDate: ISO8601DateParser.parse("2026-09-01T00:00:00Z"),
            endDate: ISO8601DateParser.parse("2026-09-30T23:59:59Z"),
            updatedAt: self.now)
    }

    private static func normalSnapshot() -> MistralUsageSnapshot {
        MistralUsageSnapshot(
            totalCost: 12.5,
            currency: "USD",
            currencySymbol: "$",
            totalInputTokens: 30,
            totalOutputTokens: 3,
            totalCachedTokens: 5,
            modelCount: 2,
            daily: [
                MistralDailyUsageBucket(
                    day: "2026-09-01",
                    cost: 3.25,
                    inputTokens: 10,
                    cachedTokens: 1,
                    outputTokens: 1,
                    models: [.init(
                        name: "fixture-alpha", cost: 3.25, inputTokens: 10, cachedTokens: 1, outputTokens: 1)]),
                MistralDailyUsageBucket(
                    day: "2026-09-02",
                    cost: 9.25,
                    inputTokens: 20,
                    cachedTokens: 4,
                    outputTokens: 2,
                    models: [.init(
                        name: "fixture-beta", cost: 9.25, inputTokens: 20, cachedTokens: 4, outputTokens: 2)]),
            ],
            startDate: ISO8601DateParser.parse("2026-09-01T00:00:00Z"),
            endDate: ISO8601DateParser.parse("2026-09-30T23:59:59Z"),
            updatedAt: self.now)
    }

    private static func summary(_ snapshot: MistralUsageSnapshot) -> [String] {
        var entries: [MenuDescriptor.Entry] = []
        MenuDescriptor.appendMistralUsageSummary(entries: &entries, usage: snapshot)
        return entries.compactMap { entry in
            guard case let .text(text, _) = entry else { return nil }
            return text
        }
    }

    private static func input(
        _ snapshot: MistralUsageSnapshot,
        historyDays: Int = 30,
        tokenOnly: Bool = false) throws -> UsageMenuCardView.Model.Input
    {
        try .init(
            provider: .mistral,
            metadata: #require(ProviderDefaults.metadata[.mistral]),
            snapshot: tokenOnly ? nil : snapshot.toUsageSnapshot(),
            credits: nil,
            creditsError: nil,
            dashboardError: nil,
            tokenSnapshot: snapshot.toCostUsageTokenSnapshot(historyDays: historyDays),
            tokenError: nil,
            account: AccountInfo(email: nil, plan: nil),
            isRefreshing: false,
            lastError: nil,
            usageBarsShowUsed: true,
            resetTimeDisplayStyle: .countdown,
            tokenCostUsageEnabled: true,
            costSummaryInlineEnabled: true,
            showOptionalCreditsAndExtraUsage: false,
            hidePersonalInfo: true,
            now: self.now)
    }

    private static func capture(
        _ name: String,
        snapshot: MistralUsageSnapshot,
        dashboard: InlineUsageDashboardModel?) throws
    {
        guard let path = ProcessInfo.processInfo.environment["CODEXBAR_MISTRAL_SCREENSHOT_DIR"] else { return }
        try #require(SettingsStore.isRunningTests)
        try #require(ProcessInfo.processInfo.environment["CODEXBAR_SUPPRESS_TEST_KEYCHAIN_ACCESS"] == "1")
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fixture = try CodexWorkspacesNavigationFixture()
        let controller = fixture.makeController()
        defer {
            controller.releaseStatusItemsForTesting()
            fixture.cleanup()
        }
        let rows = NSStackView()
        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = 0
        rows.appearance = NSAppearance(named: .aqua)
        rows.wantsLayer = true
        rows.layer?.backgroundColor = NSColor.white.cgColor
        for text in Self.summary(snapshot) {
            let row = try #require(controller.makeWrappedSecondaryTextItem(text: text, width: 320).view)
            row.widthAnchor.constraint(equalToConstant: 320).isActive = true
            row.heightAnchor.constraint(equalToConstant: row.frame.height).isActive = true
            rows.addArrangedSubview(row)
        }
        let summaryPNG = try #require(MenuLayoutScreenshotRenderTests.pngDataWithWindow(hosting: rows))
        try summaryPNG.write(to: directory.appendingPathComponent("\(name)-summary.png"))
        if let dashboard {
            let hosting = NSHostingView(rootView: AnyView(
                InlineUsageDashboardContent(model: dashboard)
                    .frame(width: 320)
                    .padding(12)
                    .environment(\.colorScheme, .light)
                    .background(Color(nsColor: .windowBackgroundColor))))
            hosting.appearance = NSAppearance(named: .aqua)
            let png = try #require(MenuLayoutScreenshotRenderTests.pngDataWithWindow(hosting: hosting))
            try png.write(to: directory.appendingPathComponent("\(name)-inline.png"))
        }
        #expect(fixture.store.snapshots.isEmpty)
    }
}
