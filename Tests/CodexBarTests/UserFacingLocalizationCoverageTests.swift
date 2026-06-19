import Foundation
import Testing

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
            "Sources/CodexBar/PreferencesProviderSidebarView.swift": [
                ".help(\"Drag to reorder\")",
                "\"Disabled —",
                ".accessibilityLabel(\"Reorder\")",
            ],
            "Sources/CodexBar/StatusItemController+UsageHistoryMenu.swift": [
                "Text(\"Subscription Utilization\")",
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
}
