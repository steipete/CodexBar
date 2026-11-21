import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

extension StatusItemBalanceDisplayTests {
    @Test(arguments: [(#"{"val":1761}"#, Optional(17.61), "$17.61"), ("{}", 0, "$0.00"), ("null", nil, "–")])
    func `Grok purchased credits render beside the weekly allowance in the status item and preview`(
        wallet: String, amount: Double?, balanceText: String) throws
    {
        let now = Date()
        let start = now.addingTimeInterval(-3 * 86400).ISO8601Format()
        let end = now.addingTimeInterval(4 * 86400).ISO8601Format()
        let config = #"""
        {"config":{"creditUsagePercent":100,"prepaidBalance":\#(wallet),
                   "currentPeriod":{"start":"\#(start)","end":"\#(end)"}}}
        """#
        try self.expectGrokBalance(
            config: config,
            tokens: [.percent(window: .automatic), .separatorDot, .balance],
            amount: amount,
            titles: (visible: "100% · \(balanceText)", hidden: "100% · –"),
            now: now)
    }

    @Test(arguments: [MenuBarLayoutToken.percent(window: .automatic), .progressBar(window: .automatic)])
    func `Grok wallet-only automatic tokens show the amount in the status item and preview`(token: MenuBarLayoutToken)
        throws
    {
        try self.expectGrokBalance(
            config: #"{"config":{"prepaidBalance":{"val":1761}}}"#,
            tokens: [token],
            amount: 17.61,
            titles: (visible: "$17.61", hidden: "–"),
            now: .now)
    }

    private func expectGrokBalance(
        config: String,
        tokens: [MenuBarLayoutToken],
        amount: Double?,
        titles: (visible: String, hidden: String),
        now: Date) throws
    {
        let billing = try GrokCreditsProxyFetcher.parseSnapshot(Data(config.utf8), now: now)
        let snapshot = GrokUsageSnapshot(
            billing: nil, webBilling: billing, credentials: nil, localSummary: nil, cliVersion: nil, updatedAt: now)
            .toUsageSnapshot()
        let layout = MenuBarLayout(lines: [tokens])
        let settings = self.makeSettings(suiteName: "StatusItemBalanceDisplayTests-grok-prepaid", provider: .grok)
        settings.menuBarShowsBrandIconWithPercent = true
        settings.setMenuBarLayout(layout, for: nil)
        let (store, controller) = self.makeStoreAndController(settings: settings)
        defer { controller.releaseStatusItemsForTesting() }
        store._setSnapshotForTesting(snapshot, provider: .grok)
        let preview = MenuBarLayoutPreview(layout: layout, provider: .grok, settings: settings, store: store)
        let options = MenuBarLayoutRenderOptions(
            size: .regular,
            highContrast: false,
            showUsed: true,
            conditionals: [],
            appearanceName: "aqua",
            isDebugApp: false,
            now: now)

        for visible in [true, false, true] {
            settings.showOptionalCreditsAndExtraUsage = visible
            for data in [
                controller.menuBarLayoutRenderData(provider: .grok, snapshot: snapshot, warningFlash: false, now: now),
                preview.liveData(provider: .grok, snapshot: snapshot),
            ] {
                let rendered = MenuBarLayoutRenderer().render(layout: layout, data: data, icon: nil, options: options)
                #expect(rendered.attributedTitle.string.replacingOccurrences(of: "\u{2009}", with: " ")
                    == (visible ? titles.visible : titles.hidden))
                #expect(data.metrics.balanceRemainingUSD == (visible ? amount : nil))
                #expect(data.metrics.balanceUsedUSD == nil)
            }
        }
    }
}
