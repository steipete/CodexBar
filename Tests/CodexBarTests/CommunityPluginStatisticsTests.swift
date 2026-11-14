import AppKit
import Foundation
import SwiftUI
import Testing
@testable import CodexBar
@testable import CodexBarCore

struct CommunityPluginStatisticsTests {
    private static let id = ProviderInstanceID(rawValue: "community-fixture")!
    private static let now = ISO8601DateFormatter().date(from: "2026-11-14T04:00:00Z")!

    @Test(arguments: [7, 30, 90])
    func `token only plugin is counted once with truthful sparse coverage`(days: Int) throws {
        let input = Self.input()
        let model = Self.model(
            inputs: [input, input],
            days: days)
        let group = try #require(model.groups.first)
        let row = try #require(group.providers.first)
        #expect(model.availableSources.count == 1)
        #expect(group.providers.count == 1)
        #expect(row.provider == Self.id)
        #expect(row.provider.firstPartyProvider == nil)
        #expect(group.currencyCode == "XXX")
        #expect(group.totalTokens == 123)
        #expect(group.totalCost == nil)
        #expect(row.coveredDayCount == 2)
        #expect(row.tokensAreLowerBound)
        #expect(group.hasPartialTokens)
        #expect(group.tokenMix.cacheReadTokens == 40)
        #expect(group.tokenMix.cacheCreationTokens == 0)
        let missing = try #require(group.dailySummaries
            .first { Self.key(
                $0.day,
                zone: "Asia/Shanghai") == "2026-11-13" })
        #expect(missing.totalTokens == nil)
        #expect(missing.requestCount == nil)
        #expect(missing.totalCost == nil)
        let activity = Dictionary(uniqueKeysWithValues: model.tokenActivity.map {
            (Self.key(
                $0.day,
                zone: "Asia/Shanghai"), $0)
        })
        #expect(activity["2026-11-12"]?.totalTokens == 123)
        #expect(activity["2026-11-13"]?.totalTokens == nil)
        #expect(activity["2026-11-13"]?.isScanned == true)
        #expect(activity["2026-11-14"]?.totalTokens == 0)
        #expect(activity["2026-11-10"]?.isScanned == false)
    }

    @Test
    func `source calendar maps into display calendar and all time remains partial`() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        let model = SpendDashboardModel.build(
            inputs: [Self.input()],
            requestedDays: 90,
            reportingPeriod: .allTime,
            now: Self.now,
            calendar: calendar)
        let group = try #require(model.groups.first)
        #expect(group.providers.first?.tokensAreLowerBound == true)
        #expect(group.totalTokens == 123)
        let active = try #require(model.tokenActivity.first { $0.totalTokens == 123 })
        #expect(Self.key(
            active.day,
            zone: "UTC") == "2026-11-11")
        let outside = try #require(model.tokenActivity.first { Self.key(
            $0.day,
            zone: "UTC") == "2026-11-14" })
        #expect(outside.totalTokens == nil)
        #expect(!outside.isScanned)
    }

    @Test @MainActor
    func `shared preview image and text use the dynamic source summary`() throws {
        let model = Self.model(
            inputs: [Self.input()],
            days: 30)
        let payload = try #require(ShareStatsBuilder.make(model: model))
        #expect(payload.providers.count == 1)
        #expect(payload.providers[0].provider == Self.id)
        #expect(payload.providers[0].providerName == "Community Fixture")
        #expect(payload.providers[0].subscriptionName == nil)
        #expect(payload.totalTokens == 123)
        #expect(payload.hasPartialTokens)
        let text = ShareStatsFormatting.text(payload)
        #expect(text.contains("Community Fixture"))
        #expect(text.contains("2/30"))
        #expect(text.contains("Spend unavailable"))
        #expect(!text.contains("XXX"))
        let image = try #require(ShareStatsRenderer.pngData(for: payload))
        let bitmap = try #require(NSBitmapImageRep(data: image))
        #expect(bitmap.pixelsWide == 1200 && bitmap.pixelsHigh == 630)
        if let directory = ProcessInfo.processInfo.environment["CODEXBAR_COMMUNITY_STATS_PROOF_DIR"] {
            let root = URL(fileURLWithPath: directory)
            try image.write(to: root.appendingPathComponent("community-sharing.png"))
            try Self.dashboardImage(model: model).write(to: root.appendingPathComponent("community-statistics.png"))
        }
    }

    @Test
    func `share sanitizer rejects account paths and credentials in plugin labels`() throws {
        for label in [
            "person@example.test",
            "/Users/person/private",
            "https://usage.example",
            String(
                repeating: "a",
                count: 40),
        ] {
            #expect(ShareStatsSanitizer.providerName(label) == nil)
        }
        let input = Self.input(name: "person@example.test")
        let payload = try #require(ShareStatsBuilder.make(model: Self.model(
            inputs: [input],
            days: 30)))
        #expect(payload.providers.first?.providerName == "Community plugin")
        #expect(!ShareStatsFormatting.text(payload).contains("person@"))
    }

    @Test(arguments: ["2026-11-01", "2026-11-11"])
    func `nullable plugin history preserves independently known daily counts`(unknownDay: String) throws {
        let usage = try ProviderPluginSnapshotMapper.map(
            JSONProviderPluginValue([
                "costUsage": [
                    "version": 2, "timeZone": "Asia/Shanghai",
                    "windowStart": "2026-11-01", "windowEnd": "2026-11-14",
                    "entries": [
                        ["date": unknownDay, "totalTokens": NSNull(), "requests": NSNull()],
                        ["date": "2026-11-13", "totalTokens": 123, "requests": 2],
                        ["date": "2026-11-14", "totalTokens": 0, "requests": 0],
                    ],
                ],
            ]),
            provider: Self.id)
        let input = try SpendDashboardModel.ProviderInput(
            providerID: Self.id,
            displayName: "Nullable Fixture",
            snapshot: #require(usage.costUsage),
            sourceKind: .communityPlugin)
        let model = Self.model(inputs: [input], days: 7)
        let group = try #require(model.groups.first)
        #expect(group.totalTokens == (unknownDay == "2026-11-01" ? 123 : nil))
        let days = Dictionary(uniqueKeysWithValues: group.dailySummaries.map {
            (Self.key($0.day, zone: "Asia/Shanghai"), $0)
        })
        #expect(days["2026-11-13"]?.totalTokens == 123)
        #expect(days["2026-11-13"]?.requestCount == 2)
        #expect(days["2026-11-13"]?.providers.first?.totalTokens == 123)
        #expect(days["2026-11-13"]?.providers.first?.requestCount == 2)
        #expect(days["2026-11-14"]?.totalTokens == 0)
        #expect(days["2026-11-14"]?.requestCount == 0)
        #expect(days["2026-11-12"]?.totalTokens == nil)
        #expect(days["2026-11-12"]?.requestCount == nil)
        if unknownDay == "2026-11-11" {
            #expect(days[unknownDay]?.totalTokens == nil)
            #expect(days[unknownDay]?.requestCount == nil)
        }
    }

    @Test
    func `legacy native windows keep known activity from other native sources`() throws {
        func legacyInput(
            provider: UsageProvider,
            historyDays: Int,
            date: String,
            tokens: Int) throws -> SpendDashboardModel.ProviderInput
        {
            let usage = try ProviderPluginSnapshotMapper.map(
                JSONProviderPluginValue([
                    "costUsage": [
                        "currency": "USD", "historyDays": historyDays, "windowEnd": "2026-11-14",
                        "entries": [[
                            "date": date, "inputTokens": tokens, "outputTokens": 0,
                            "requests": tokens == 0 ? 0 : 1, "cost": tokens == 0 ? 0 : 1,
                        ]],
                    ],
                ]),
                provider: provider.instanceID)
            return try SpendDashboardModel.ProviderInput(
                provider: provider,
                displayName: provider.rawValue,
                snapshot: #require(usage.costUsage))
        }
        let model = try Self.model(inputs: [
            legacyInput(provider: .codex, historyDays: 7, date: "2026-11-10", tokens: 10),
            legacyInput(provider: .claude, historyDays: 1, date: "2026-11-14", tokens: 0),
        ], days: 7)
        let point = try #require(model.tokenActivity.first {
            Self.key($0.day, zone: "Asia/Shanghai") == "2026-11-10"
        })
        #expect(point.isScanned)
        #expect(point.totalTokens == 10)
    }

    @Test
    func `native history cannot fill a plugin window edge with zero`() throws {
        let native = SpendDashboardModel.ProviderInput(
            provider: .codex,
            displayName: "Codex",
            snapshot: CostUsageTokenSnapshot(
                sessionTokens: nil,
                sessionCostUSD: nil,
                last30DaysTokens: 10,
                last30DaysCostUSD: 1,
                historyDays: 7,
                daily: [.init(
                    date: "2026-11-10",
                    inputTokens: nil,
                    outputTokens: nil,
                    totalTokens: 10,
                    costUSD: 1,
                    modelsUsed: nil,
                    modelBreakdowns: nil)],
                updatedAt: Self.now))
        let model = Self.model(
            inputs: [Self.input(), native],
            days: 7)
        let point = try #require(model.tokenActivity.first {
            Self.key(
                $0.day,
                zone: "Asia/Shanghai") == "2026-11-10"
        })
        #expect(point.isScanned)
        #expect(point.totalTokens == nil)
        let payload = try #require(ShareStatsBuilder.make(model: model))
        #expect(payload.providers.count == 2)
        #expect(payload.totalTokens == 133)
        #expect(payload.hasPartialTokens)
    }

    @Test(arguments: ["Pacific/Auckland", "Pacific/Kiritimati"])
    func `legacy plugin windows preserve civil dates in far east display zones`(zone: String) throws {
        let usage = try ProviderPluginSnapshotMapper.map(
            JSONProviderPluginValue([
                "costUsage": [
                    "currency": "USD", "historyDays": 7, "windowEnd": "2026-11-14",
                    "entries": [
                        ["date": "2026-11-08", "inputTokens": 100, "outputTokens": 20, "requests": 1, "cost": 1],
                        ["date": "2026-11-14", "inputTokens": 0, "outputTokens": 0, "requests": 0, "cost": 0],
                    ],
                ],
            ]),
            provider: Self.id)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: zone))
        let now = try #require(calendar.date(from: DateComponents(
            year: 2026,
            month: 11,
            day: 14,
            hour: 12)))
        let input = try SpendDashboardModel.ProviderInput(
            id: "plugin:community-fixture",
            providerID: Self.id,
            displayName: "Legacy Fixture",
            snapshot: #require(usage.costUsage),
            sourceKind: .communityPlugin)
        let model = SpendDashboardModel.build(
            inputs: [input],
            requestedDays: 7,
            now: now,
            calendar: calendar)
        let group = try #require(model.groups.first)
        #expect(group.providers.first?.totalTokens == 120)
        #expect(group.providers.first?.totalCost == 1)
        #expect(group.providers.first?.coveredDayCount == 2)
        #expect(group.dailySummaries.count == 7)
        #expect(group.dailySummaries.first?.totalTokens == 120)
        #expect(group.dailySummaries[1].totalTokens == nil)
        #expect(group.hasPartialTokens)
    }

    @MainActor
    private static func dashboardImage(model: SpendDashboardModel) throws -> Data {
        let group = try #require(model.groups.first)
        let view = VStack(spacing: 20) {
            SpendActivityHeatmapView(
                points: model.tokenActivity,
                now: Self.now,
                calendar: group.calendar)
                .frame(height: 230)
            SpendDashboardCurrencySection(
                group: group,
                requestedDays: 30,
                hidePersonalInfo: true)
        }
        .padding(24)
        .frame(
            width: 820,
            height: 1100,
            alignment: .top)
        .environment(\.colorScheme, .light)
        .environment(\.locale, Locale(identifier: "en_US_POSIX"))
        .defaultAppStorage(InMemoryUserDefaults())
        .background(Color.white)
        let hosting = NSHostingView(rootView: view)
        hosting.appearance = NSAppearance(named: .aqua)
        let size = hosting.fittingSize
        hosting.frame = CGRect(
            origin: .zero,
            size: size)
        let window = NSWindow(
            contentRect: CGRect(
                origin: .zero,
                size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = hosting
        window.layoutIfNeeded()
        hosting.layoutSubtreeIfNeeded()
        let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(
            in: hosting.bounds,
            to: bitmap)
        return try #require(bitmap.representation(
            using: .png,
            properties: [:]))
    }

    private static func model(
        inputs: [SpendDashboardModel.ProviderInput],
        days: Int) -> SpendDashboardModel
    {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return SpendDashboardModel.build(
            inputs: inputs,
            requestedDays: days,
            now: Self.now,
            calendar: calendar)
    }

    private static func key(
        _ date: Date,
        zone: String) -> String
    {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: zone)!
        return CostUsageLocalDay.key(
            from: date,
            calendar: calendar)
    }

    private static func input(name: String = "Community Fixture") -> SpendDashboardModel.ProviderInput {
        let daily = [
            CostUsageDailyReport.Entry(
                date: "2026-11-12",
                inputTokens: 100,
                outputTokens: 20,
                cacheReadTokens: 40,
                cacheCreationTokens: 0,
                totalTokens: 123,
                costUSD: nil,
                modelsUsed: nil,
                modelBreakdowns: nil),
            CostUsageDailyReport.Entry(
                date: "2026-11-14",
                inputTokens: nil,
                outputTokens: nil,
                totalTokens: 0,
                costUSD: nil,
                modelsUsed: nil,
                modelBreakdowns: nil),
        ]
        return SpendDashboardModel.ProviderInput(
            providerID: Self.id,
            displayName: name,
            snapshot: CostUsageTokenSnapshot(
                sessionTokens: nil,
                sessionCostUSD: nil,
                last30DaysTokens: 123,
                last30DaysCostUSD: nil,
                currencyCode: "XXX",
                historyDays: 4,
                daily: daily,
                dailyHistory: CostUsageDailyHistory(
                    timeZoneIdentifier: "Asia/Shanghai",
                    windowStart: "2026-11-11",
                    windowEnd: "2026-11-14"),
                updatedAt: Self.now),
            sourceKind: .communityPlugin)
    }
}
