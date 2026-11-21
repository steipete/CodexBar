import AppKit
import SwiftUI
import Testing
@testable import CodexBar
@testable import CodexBarCore

@MainActor
struct AmpEnterpriseTests {
    @Test
    func `enterprise paid workspace is usable without a fabricated balance or quota`() throws {
        let snapshot = try AmpUsageParser.parse(displayText: """
        Signed in as member@example.test (member)
        **Workspace example:** usage paid by your enterprise - https://ampcode.com/workspaces/example
        """)
        let usage = snapshot.toUsageSnapshot()
        #expect(usage.primary == nil)
        #expect(usage.providerCost == nil)
        #expect(usage.identity?.loginMethod == "Enterprise")
        #expect(usage.identity?.accountEmail == "member@example.test")
        #expect(usage.detailRow(label: "Workspace example")?.value == "Enterprise")
        let mixed = try AmpUsageParser.parse(displayText: """
        Signed in as member@example.test (member)
        Amp Free: 75% remaining today (resets daily)
        Workspace example: usage paid by your enterprise
        """).toUsageSnapshot()
        #expect(mixed.primary?.usedPercent == 25)
        #expect(mixed.identity?.loginMethod == "Amp Free")
        #expect(mixed.detailRow(label: "Workspace example")?.value == "Enterprise")
        guard let directory = ProcessInfo.processInfo.environment["CODEXBAR_AMP_ENTERPRISE_PROOF_DIR"] else { return }
        for after in [false, true] {
            let model = UsageMenuCardView.Model.make(.init(
                provider: .amp,
                metadata: AmpProviderDescriptor.descriptor.metadata,
                snapshot: after ? usage : nil,
                credits: nil,
                creditsError: nil,
                dashboardError: nil,
                tokenSnapshot: nil,
                tokenError: nil,
                account: AccountInfo(email: nil, plan: after ? "Enterprise" : nil),
                isRefreshing: false,
                lastError: after ? nil : "Missing Amp usage data.",
                usageBarsShowUsed: true,
                resetTimeDisplayStyle: .absolute,
                tokenCostUsageEnabled: false,
                showOptionalCreditsAndExtraUsage: true,
                hidePersonalInfo: true,
                paceVisible: false,
                now: usage.updatedAt))
            let renderer = ImageRenderer(content: UsageMenuCardView(model: model, width: 380)
                .environment(\.locale, Locale(identifier: "en_US_POSIX"))
                .environment(\.colorScheme, .light).background(Color.white))
            renderer.scale = 2
            let bitmap = try NSBitmapImageRep(cgImage: #require(renderer.cgImage))
            try #require(bitmap.representation(using: .png, properties: [:])).write(
                to: URL(fileURLWithPath: directory).appendingPathComponent(after ? "amp-after.png" : "amp-before.png"))
        }
    }
}
