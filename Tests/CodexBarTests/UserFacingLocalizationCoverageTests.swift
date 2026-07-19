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
    func `spend dashboard model breakdown state stays precise and localized`() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("Sources/CodexBar/PreferencesSpendDashboardPane.swift"),
            encoding: .utf8)

        #expect(source.contains(#"Text(L("Model breakdown unavailable"))"#))
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
}
