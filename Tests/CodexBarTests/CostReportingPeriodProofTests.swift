import AppKit
import SwiftUI
import Testing
@testable import CodexBar

struct CostReportingPeriodProofTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["CODEXBAR_COST_PERIOD_PROOF_DIR"] != nil))
    @MainActor
    func `render synthetic period controls without launching the app`() throws {
        let directory = try #require(ProcessInfo.processInfo.environment["CODEXBAR_COST_PERIOD_PROOF_DIR"])
        let root = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let settings = testSettingsStore(
            suiteName: "CostReportingPeriodProofTests", userDefaults: InMemoryUserDefaults())
        settings.costUsageHistoryDays = 30
        try Self.render(LegacyCostHistoryEditor(settings: settings), to: root.appendingPathComponent("before.png"))
        settings.costReportingPeriod = .monthToDate
        try Self.render(CostHistoryDaysEditor(settings: settings), to: root.appendingPathComponent("after.png"))
    }

    @MainActor
    private static func render(_ content: some View, to url: URL) throws {
        let hosting = NSHostingView(rootView: content.padding(24).frame(width: 520)
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, .light)
            .environment(\.displayScale, 2))
        hosting.appearance = NSAppearance(named: .aqua)
        let data = try #require(MenuLayoutScreenshotRenderTests.pngDataWithWindow(hosting: hosting))
        try data.write(to: url)
    }
}

/// The original control from 243af60017cb, rendered with synthetic settings for before/after proof.
@MainActor
private struct LegacyCostHistoryEditor: View {
    @Bindable var settings: SettingsStore

    var body: some View {
        LabeledContent(CostHistoryDaysEditor.title(days: self.settings.costUsageHistoryDays)) {
            HStack(spacing: 8) {
                TextField(
                    CostHistoryDaysEditor.title(days: self.settings.costUsageHistoryDays),
                    value: self.$settings.costUsageHistoryDays,
                    format: .number)
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .monospacedDigit()
                    .frame(width: 64)
                Stepper(value: self.$settings.costUsageHistoryDays, in: 1...365, step: 1) { EmptyView() }
                    .labelsHidden()
            }
        }
    }
}
