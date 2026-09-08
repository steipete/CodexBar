import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

struct ClaudeUsageDetailNoteTests {
    @Test
    func `limited detail describes fidelity without inventing a source`() {
        let notes = CodexBarLocalizationOverride.$appLanguage.withValue("en") {
            ClaudeUsageDetailTestSupport.model(snapshot: ClaudeUsageDetailTestSupport.snapshot()).usageNotes
        }
        #expect(notes == ["Limited usage detail"])
    }

    @Test(arguments: [UsageDataConfidence.exact, .estimated, .unknown])
    func `other confidence levels do not gain a limited detail note`(_ confidence: UsageDataConfidence) {
        let snapshot = ClaudeUsageDetailTestSupport.snapshot(confidence: confidence)
        #expect(ClaudeUsageDetailTestSupport.model(snapshot: snapshot).usageNotes.isEmpty)
    }

    @Test
    func `limited detail has a translation in every app catalog`() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let resources = root.appendingPathComponent("Sources/CodexBar/Resources")
        let catalogs = try FileManager.default.contentsOfDirectory(at: resources, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "lproj" }
        let languages = Set(AppLanguage.allCases.filter { $0 != .system }.map(\.rawValue))
        #expect(Set(catalogs.map { $0.deletingPathExtension().lastPathComponent }) == languages)
        for directory in catalogs {
            let url = directory.appendingPathComponent("Localizable.strings")
            let catalog = try #require(NSDictionary(contentsOf: url) as? [String: String])
            #expect(catalog["claude_limited_usage_detail"]?.isEmpty == false, "\(directory.lastPathComponent)")
        }
    }
}

enum ClaudeUsageDetailTestSupport {
    static let now = Date(timeIntervalSince1970: 1_787_875_500)

    static func snapshot(confidence: UsageDataConfidence = .percentOnly) -> UsageSnapshot {
        UsageSnapshot(
            primary: RateWindow(usedPercent: 21, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
            secondary: RateWindow(usedPercent: 42, windowMinutes: 10080, resetsAt: nil, resetDescription: nil),
            updatedAt: self.now.addingTimeInterval(-300),
            dataConfidence: confidence)
    }

    static func model(
        snapshot: UsageSnapshot?,
        lastError: String? = nil,
        sourceLabel: String? = nil) -> UsageMenuCardView.Model
    {
        UsageMenuCardView.Model.make(.init(
            provider: .claude,
            metadata: ProviderDescriptorRegistry.descriptor(for: .claude).metadata,
            snapshot: snapshot,
            credits: nil,
            creditsError: nil,
            dashboard: nil,
            dashboardError: nil,
            tokenSnapshot: nil,
            tokenError: nil,
            account: AccountInfo(email: nil, plan: nil),
            isRefreshing: false,
            lastError: lastError,
            usageBarsShowUsed: true,
            resetTimeDisplayStyle: .countdown,
            tokenCostUsageEnabled: false,
            showOptionalCreditsAndExtraUsage: true,
            sourceLabel: sourceLabel,
            hidePersonalInfo: true,
            usesLiveSubtitle: false,
            now: self.now))
    }
}
