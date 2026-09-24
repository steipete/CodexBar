import AppKit
import CodexBarCore
import SwiftUI
import Testing
@testable import CodexBar

struct CreditsScaleScreenshotTests {
    @Test @MainActor
    func `render synthetic credit balances`() throws {
        guard let path = ProcessInfo.processInfo.environment["CODEXBAR_CREDITS_SCALE_PROOF_DIR"] else { return }
        #expect(ProcessInfo.processInfo.environment["CODEXBAR_SUPPRESS_TEST_KEYCHAIN_ACCESS"] == "1")
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let models = try [750.0, 1250.0, 12000.0].map { balance in
            try UsageMenuCardView.Model.make(.init(
                provider: .codex,
                metadata: #require(ProviderDefaults.metadata[.codex]),
                snapshot: nil,
                credits: CreditsSnapshot(remaining: balance, events: [], updatedAt: now),
                creditsError: nil,
                dashboardError: nil,
                tokenSnapshot: nil,
                tokenError: nil,
                account: AccountInfo(email: nil, plan: nil),
                isRefreshing: false,
                lastError: nil,
                usageBarsShowUsed: true,
                resetTimeDisplayStyle: .countdown,
                tokenCostUsageEnabled: false,
                showOptionalCreditsAndExtraUsage: true,
                hidePersonalInfo: true,
                paceVisible: false,
                usesLiveSubtitle: false,
                now: now))
        }
        let view = VStack(alignment: .leading, spacing: 16) {
            Text("Synthetic credit balances").font(.headline)
            HStack(alignment: .top, spacing: 20) {
                ForEach(models.indices, id: \.self) { index in
                    UsageMenuCardCreditsSectionView(
                        model: models[index], showBottomDivider: false, topPadding: 0, bottomPadding: 0, width: 300)
                }
            }
        }
        .padding(24)
        .environment(\.locale, Locale(identifier: "en_US_POSIX"))
        .environment(\.colorScheme, .light)
        .background(Color(nsColor: .windowBackgroundColor))
        let hosting = NSHostingView(rootView: view)
        hosting.appearance = NSAppearance(named: .aqua)
        try #require(MenuLayoutScreenshotRenderTests.pngDataWithWindow(hosting: hosting))
            .write(to: directory.appendingPathComponent("credits.png"))
    }
}
