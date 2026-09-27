import AppKit
import CodexBarCore
import Testing
@testable import CodexBar

@MainActor
struct MenuBarLayoutProviderBalanceTests {
    private let now = Date(timeIntervalSince1970: 1_752_768_000)

    @Test(arguments: [UsageProvider.mimo, .hyper, .atlascloud, .vercel, .devpass, .anyrouter])
    func `stored balance and automatic tokens resolve provider amounts`(provider: UsageProvider) throws {
        let (snapshot, expected) = try self.fixture(provider: provider)
        let data = self.data(provider: provider, snapshot: snapshot)
        let layout = try JSONDecoder().decode(MenuBarLayout.self, from: Data(
            #"{"lines":[[{"balance":{}}],[{"percent":{"window":"automatic"}}]]}"#.utf8))
        #expect(data.balance == expected)
        #expect(data.automaticText == expected)
        let output = self.render(layout: layout, data: data)
        #expect(output.attributedTitle.string == "\(expected)\n\(expected)")
    }

    @Test(arguments: [UsageProvider.mimo, .devpass, .opencodego])
    func `explicit balance coexists with real quota percentages`(provider: UsageProvider) throws {
        let snapshot: UsageSnapshot
        let expected: String
        if provider == .mimo {
            snapshot = MiMoUsageSnapshot(
                balance: 4.84,
                currency: "USD",
                planCode: "standard",
                tokenUsed: 25,
                tokenLimit: 100,
                tokenPercent: 0.25,
                updatedAt: self.now).toUsageSnapshot()
            expected = "$4.84"
        } else {
            snapshot = try UsageSnapshot(
                primary: RateWindow(usedPercent: 25, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
                secondary: nil,
                providerCost: provider == .opencodego
                    ? ProviderCostSnapshot(
                        used: 25,
                        limit: 0,
                        currencyCode: "USD",
                        period: "Zen balance",
                        updatedAt: self.now) : nil,
                details: [ProviderDetailSection(title: "DevPass credits", rows: [
                    .init(label: "Cycle remaining", value: "$25.00"),
                ])],
                updatedAt: self.now)
            expected = "$25.00"
        }
        let data = self.data(provider: provider, snapshot: snapshot)
        #expect(data.balance == expected)
        #expect(data.automaticText == nil)
        #expect(self.render(layout: MenuBarLayout(lines: [[.percent(window: .automatic)]]), data: data)
            .attributedTitle.string == "25%")
    }

    @Test(arguments: [UsageProvider.mimo, .hyper, .atlascloud, .vercel, .devpass, .doubao, .anyrouter])
    func `absent balances never borrow unrelated spend`(provider: UsageProvider) throws {
        let snapshot = try UsageSnapshot(
            primary: nil,
            secondary: nil,
            details: [ProviderDetailSection(title: "API key (all time)", rows: [
                .init(label: "All-time key usage", value: "$31.42"),
            ])],
            updatedAt: self.now)
        #expect(MenuBarLayoutBalanceResolver.balance(provider: provider, snapshot: nil) == nil)
        #expect(MenuBarLayoutBalanceResolver.balance(provider: provider, snapshot: snapshot) == nil)
    }

    @Test(arguments: ["$0.00", "-$4.25"])
    func `zero and negative balances remain visible`(amount: String) throws {
        let snapshot = try UsageSnapshot(
            primary: nil,
            secondary: nil,
            details: [ProviderDetailSection(title: "Account balance", rows: [
                .init(label: "Available balance", value: amount),
            ])],
            updatedAt: self.now)
        #expect(MenuBarLayoutBalanceResolver.balance(provider: .atlascloud, snapshot: snapshot) == amount)
    }

    @Test
    func `synthetic balance renderer proof`() throws {
        guard let path = ProcessInfo.processInfo.environment["CODEXBAR_LAYOUT_BALANCE_PROOF"] else { return }
        let providers: [UsageProvider] = [.mimo, .hyper, .atlascloud, .vercel, .devpass]
        let image = NSImage(size: NSSize(width: 620, height: 260))
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: 620, height: 260).fill()
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 14), .foregroundColor: NSColor.black,
        ]
        ("Stored layout: Balance · Auto % — synthetic data" as NSString)
            .draw(at: NSPoint(x: 16, y: 230), withAttributes: attributes)
        for (index, provider) in providers.enumerated() {
            let (snapshot, _) = try self.fixture(provider: provider)
            let output = self.render(
                layout: MenuBarLayout(lines: [[.balance, .separatorDot, .percent(window: .automatic)]]),
                data: self.data(provider: provider, snapshot: snapshot))
            let y = CGFloat(190 - index * 40)
            (provider.rawValue as NSString).draw(at: NSPoint(x: 16, y: y), withAttributes: attributes)
            let title = NSMutableAttributedString(attributedString: output.attributedTitle)
            title.addAttribute(
                .foregroundColor,
                value: NSColor.black,
                range: NSRange(location: 0, length: title.length))
            title.draw(at: NSPoint(x: 160, y: y))
        }
        image.unlockFocus()
        let tiff = try #require(image.tiffRepresentation)
        let bitmap = try #require(NSBitmapImageRep(data: tiff))
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: path))
    }

    private func fixture(provider: UsageProvider) throws -> (UsageSnapshot, String) {
        if provider == .mimo {
            return (MiMoUsageSnapshot(
                balance: 4.84,
                currency: "USD",
                cashBalance: 4.84,
                giftBalance: 0,
                updatedAt: self.now).toUsageSnapshot(), "$4.84")
        }
        let label = provider == .devpass ? "Cycle remaining" : provider == .hyper ? "Balance" : "Available balance"
        let value = provider == .hyper ? "42.5 HC" : "$25.00"
        return try (UsageSnapshot(
            primary: nil,
            secondary: nil,
            details: [ProviderDetailSection(title: "Synthetic credits", rows: [.init(label: label, value: value)])],
            updatedAt: self.now), value)
    }

    private func data(provider: UsageProvider, snapshot: UsageSnapshot) -> MenuBarLayoutRenderData {
        let automatic = MenuBarLayoutRenderWindow(MenuBarMetricWindowResolver.rateWindow(
            preference: .automatic,
            provider: provider,
            snapshot: snapshot,
            supportsAverage: false,
            now: self.now))
        return MenuBarLayoutRenderData(
            provider: provider,
            iconKey: provider.rawValue,
            providerName: provider.rawValue,
            accountLabel: nil,
            laneLabels: MenuBarLayoutLaneLabels(provider: provider, snapshot: snapshot),
            primary: MenuBarLayoutRenderWindow(snapshot.primary),
            secondary: nil,
            tertiary: nil,
            session: nil,
            weekly: nil,
            scopedWeekly: nil,
            scopedWeeklyTitle: nil,
            automatic: automatic,
            automaticText: StatusItemController.menuBarLayoutAutomaticText(
                provider: provider, snapshot: snapshot, automatic: automatic),
            sessionPace: nil,
            weeklyPace: nil,
            automaticPace: nil,
            runsOut: nil,
            balance: MenuBarLayoutBalanceResolver.balance(provider: provider, snapshot: snapshot),
            costToday: nil,
            cost30d: nil,
            metrics: .unavailable)
    }

    private func render(layout: MenuBarLayout, data: MenuBarLayoutRenderData) -> MenuBarLayoutRenderedTitle {
        MenuBarLayoutRenderer().render(layout: layout, data: data, icon: nil, options: MenuBarLayoutRenderOptions(
            size: .regular,
            highContrast: false,
            showUsed: true,
            conditionals: [],
            appearanceName: "aqua",
            isDebugApp: false,
            now: self.now))
    }
}
