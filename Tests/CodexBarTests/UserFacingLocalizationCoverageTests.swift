import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

struct UserFacingLocalizationCoverageTests {
    @Test
    func `selected user-facing UI surfaces avoid raw English literals`() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()

        let forbiddenMarkersByFile: [String: [String]] = [
            "Sources/CodexBar/CostHistoryChartMenuView.swift": [
                ".value(\"Day\"",
                ".value(\"Cost\"",
                ".value(\"Cap start\"",
                ".value(\"Cap end\"",
            ],
            "Sources/CodexBar/CreditsHistoryChartMenuView.swift": [
                ".value(\"Day\"",
                ".value(\"Credits used\"",
                ".value(\"Cap start\"",
                ".value(\"Cap end\"",
                "Text(\"Total (30d):",
                "\\(total) credits",
                "\\(used) credits",
            ],
            "Sources/CodexBar/PlanUtilizationHistoryChartMenuView.swift": [
                ".value(\"Series\"",
                ".value(\"Capacity Start\"",
                ".value(\"Capacity End\"",
                ".value(\"Utilization Start\"",
                ".value(\"Utilization End\"",
            ],
            "Sources/CodexBar/Providers/JetBrains/JetBrainsLoginFlow.swift": [
                "                \"Install a JetBrains IDE with AI Assistant enabled, then refresh CodexBar.\",",
                "                \"Alternatively, set a custom path in Settings.\",",
                "title: \"No JetBrains IDE detected\"",
            ],
            "Sources/CodexBar/PreferencesCodexAccountsSection.swift": [
                "?? \"No system account\"",
                "return \"Adding Account…\"",
                "return \"Add Account\"",
                "return \"Re-authenticating…\"",
                "return \"Re-auth\"",
                "ProviderSettingsSection(title: \"Accounts\")",
                "Text(\"Active\")",
                "Text(\"Choose which Codex account CodexBar should follow.\")",
                "Text(\"Account\")",
                "Text(\"No Codex accounts detected yet.\")",
                "Text(\"System\")",
                "Text(\"The default Codex account on this Mac.\")",
                "Text(\"(System)\")",
                "Button(\"Remove\")",
            ],
            "Sources/CodexBar/PreferencesProviderDetailView.swift": [
                ".help(\"Refresh\")",
                "accessibilityLabel: \"Usage used\"",
            ],
            "Sources/CodexBar/PreferencesProviderErrorView.swift": [
                ".help(\"Copy error\")",
            ],
            "Sources/CodexBar/PreferencesSpendDashboardPane.swift": [
                "Text(\"Model breakdown unavailable\")",
                "Text(\"Partial model breakdown\")",
                "Text(\"Partial estimate\")",
            ],
            "Sources/CodexBar/PreferencesProviderSettingsRows.swift": [
                "Text(self.title)",
                "Text(self.toggle.title)",
                "Text(self.toggle.subtitle)",
                "Button(action.title)",
                "Text(self.picker.title)",
                "Text(option.title)",
                "Text(trimmedTitle)",
                "Text(trimmedSubtitle)",
                "Text(self.descriptor.title)",
                "Text(self.descriptor.subtitle)",
                "Text(\"No token accounts yet.\")",
                "Button(\"Remove\")",
                "TextField(\"Label\"",
                "Button(\"Add\")",
                "TextField(\"Org ID (optional)\"",
                ".help(\"Optional organization ID for accounts linked to multiple Anthropic organizations.\")",
                "Button(\"Open token file\")",
                "Button(\"Reload\")",
                "Text(\"No organizations loaded. Click Refresh after setting your API key.\")",
                "Button(\"Refresh organizations\")",
            ],
            "Sources/CodexBar/PreferencesSidebar.swift": [
                "\"Disabled —",
                ".accessibilityLabel(\"Sort",
            ],
            "Sources/CodexBar/StatusItemController+CostMenuCard.swift": [
                "static let costMenuTitle",
            ],
            "Sources/CodexBar/UsageBreakdownChartMenuView.swift": [
                ".value(\"Day\"",
                ".value(\"Credits used\"",
                ".value(\"Service\"",
                ".value(\"Cap start\"",
                ".value(\"Cap end\"",
            ],
        ]

        var violations: [String] = []
        for (relativePath, markers) in forbiddenMarkersByFile.sorted(by: { $0.key < $1.key }) {
            let source = try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
            for marker in markers where source.contains(marker) {
                violations.append("\(relativePath): \(marker)")
            }
        }

        #expect(
            violations.isEmpty,
            "Raw user-facing localization markers remain:\n\(violations.joined(separator: "\n"))")
    }

    @Test
    func `provider detail localization preserves technical identifiers`() throws {
        let details = try [
            ProviderDetailSection(
                title: "Usage",
                rows: [
                    .init(label: "Balance", value: "$12.34"),
                    .init(label: "Top model", value: "deepseek-v4-flash"),
                ],
                chart: .init(
                    kind: .bars,
                    title: "Usage",
                    unit: "tokens",
                    points: [.init(label: "2026-08-20", value: 42)])),
        ]

        let localized = CodexBarLocalizationOverride.$appLanguage.withValue("zh-Hans") {
            UsageMenuCardView.Model.localizedProviderDetails(details, provider: .deepseek)
        }

        let section = try #require(localized.first)
        #expect(section.title == "用量")
        #expect(section.rows.map(\.label) == ["余额", "最常用模型"])
        #expect(section.rows.map(\.value) == ["$12.34", "deepseek-v4-flash"])
        #expect(section.chart?.title == "用量")
        #expect(section.chart?.unit == "token")
        #expect(section.chart?.points.first?.label == "2026-08-20")
    }

    @Test
    func `kiro cap phrases localize of prefixes`() throws {
        let details = try [
            ProviderDetailSection(
                title: "Usage",
                rows: [
                    .init(label: "Overage usage", value: "3603.49 credits", secondaryValue: "of 10000"),
                    .init(label: "Overage cost", value: "$144.14", secondaryValue: "of $400.00"),
                ]),
        ]

        let localized = CodexBarLocalizationOverride.$appLanguage.withValue("zh-Hans") {
            UsageMenuCardView.Model.localizedProviderDetails(details, provider: .kiro)
        }

        let section = try #require(localized.first)
        #expect(section.rows.map(\.label) == ["超额用量", "超额费用"])
        #expect(section.rows.map(\.value) == ["3603.49 额度", "$144.14"])
        #expect(section.rows.map(\.secondaryValue) == ["/ 10000", "/ $400.00"])
    }

    @Test
    func `spend dashboard model breakdown state stays precise and localized`() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("Sources/CodexBar/PreferencesSpendDashboardPane.swift"),
            encoding: .utf8)

        #expect(source.contains(#"Text(L("Model breakdown unavailable"))"#))
        #expect(source.contains(#"L("Partial model breakdown")"#))
        #expect(source.contains(#"Text(L("No model-level history"))"#))
    }

    @Test
    func `spend dashboard chart keeps validated points when aggregate total is unavailable`() {
        let start = Date(timeIntervalSince1970: 1_783_036_800)
        let points = [
            SpendDashboardModel.DailyPoint(
                sourceID: "healthy-claude",
                provider: .claude,
                providerName: "Claude",
                day: start,
                cost: 2,
                stackStart: 0,
                stackEnd: 2),
            SpendDashboardModel.DailyPoint(
                sourceID: "healthy-openai-1",
                provider: .openai,
                providerName: "OpenAI",
                day: start,
                cost: 3,
                stackStart: 2,
                stackEnd: 5),
            SpendDashboardModel.DailyPoint(
                sourceID: "healthy-openai-2",
                provider: .openai,
                providerName: "OpenAI",
                day: start.addingTimeInterval(86400),
                cost: 4,
                stackStart: 0,
                stackEnd: 4),
        ]

        let partial = SpendDailyChartPresentation(dailyPoints: points, aggregateTotal: nil)
        #expect(partial.content == .chart)
        #expect(partial.series.map(\.name) == ["Claude", "OpenAI"])
        #expect(partial.dayCount == 2)
        CodexBarLocalizationOverride.$appLanguage.withValue("en") {
            #expect(partial.accessibilityValue == "2 days of usage data across 2 services")
        }

        #expect(SpendDailyChartPresentation(dailyPoints: [], aggregateTotal: nil).content == .unavailable)
        #expect(SpendDailyChartPresentation(dailyPoints: [], aggregateTotal: 0).content == .chart)
    }

    @Test
    func `hourly chart labels include the date across multiple days`() throws {
        let shanghai = try #require(TimeZone(identifier: "Asia/Shanghai"))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = shanghai
        let first = try #require(calendar.date(from: DateComponents(year: 2026, month: 8, day: 16, hour: 10)))
        let second = try #require(calendar.date(from: DateComponents(year: 2026, month: 8, day: 17, hour: 10)))
        let points = [
            SpendDashboardModel.HourlyPoint(
                sourceID: SpendDashboardModel.openCodexSourceID,
                provider: .codex,
                providerName: "OpenCodex",
                hour: first,
                cost: 1.2,
                stackStart: 0,
                stackEnd: 1.2),
            SpendDashboardModel.HourlyPoint(
                sourceID: SpendDashboardModel.openCodexSourceID,
                provider: .codex,
                providerName: "OpenCodex",
                hour: second,
                cost: 0.8,
                stackStart: 0,
                stackEnd: 0.8),
        ]

        let losAngeles = try #require(TimeZone(identifier: "America/Los_Angeles"))
        let multiDay = SpendHourlyChartPresentation(hourlyPoints: points, calendar: calendar)
        let sameDay = SpendHourlyChartPresentation(hourlyPoints: [points[0]], calendar: calendar)
        #expect(multiDay.content == .chart)
        #expect(multiDay.includeDateInPointLabels)
        #expect(!sameDay.includeDateInPointLabels)
        CodexBarLocalizationOverride.$appLanguage.withValue("en") {
            #expect(multiDay.accessibilityValue == "2 hours of usage data across 1 service")
            #expect(sameDay.accessibilityValue == "1 hour of usage data across 1 service")
            #expect(spendDashboardHourlyChartAccessibilityValue(hourCount: 1, serviceCount: 2)
                == "1 hour of usage data across 2 services")
            #expect(spendDashboardHourlyChartAccessibilityValue(hourCount: 2, serviceCount: 2)
                == "2 hours of usage data across 2 services")
            let shanghaiLabel = spendDashboardHourlyPointAccessibilityLabel(
                providerName: "OpenCodex",
                hour: first,
                timeZone: shanghai,
                includeDate: true)
            #expect(shanghaiLabel.hasPrefix("OpenCodex, "))
            #expect(shanghaiLabel.contains("16"))
            #expect(shanghaiLabel.contains("10"))

            let sameClockDifferentZone = spendDashboardHourlyPointAccessibilityLabel(
                providerName: "OpenCodex",
                hour: first,
                timeZone: losAngeles,
                includeDate: false)
            #expect(sameClockDifferentZone != shanghaiLabel)
            #expect(sameClockDifferentZone.contains("7"))
        }
    }

    @Test
    func `hourly chart labels disambiguate repeated DST fallback hours`() throws {
        let newYork = try #require(TimeZone(identifier: "America/New_York"))
        let first1am = Date(timeIntervalSince1970: 1_793_509_200)
        let second1am = Date(timeIntervalSince1970: 1_793_512_800)
        try CodexBarLocalizationOverride.$appLanguage.withValue("en") {
            let label1 = spendDashboardHourlyPointAccessibilityLabel(
                providerName: "OpenCodex",
                hour: first1am,
                timeZone: newYork,
                includeDate: true)
            let label2 = spendDashboardHourlyPointAccessibilityLabel(
                providerName: "OpenCodex",
                hour: second1am,
                timeZone: newYork,
                includeDate: true)
            let firstAbbreviation = try #require(newYork.abbreviation(for: first1am))
            let secondAbbreviation = try #require(newYork.abbreviation(for: second1am))
            #expect(firstAbbreviation != secondAbbreviation)
            #expect(label1 != label2)
            #expect(label1.contains(firstAbbreviation))
            #expect(label2.contains(secondAbbreviation))
        }
    }
}
