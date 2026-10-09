import AppKit
import CodexBarCore
import Testing
@testable import CodexBar

@MainActor
struct MenuBarLayoutProviderBalanceTests {
    private let now = Date(timeIntervalSince1970: 1_752_768_000)

    @Test
    func `JetBrains top-up balance renders beside the unchanged monthly percentage`() throws {
        let snapshot = try JetBrainsTopUpIntegrationTests.xml().toUsageSnapshot()
        let data = self.data(provider: .jetbrains, snapshot: snapshot)
        let output = self.render(
            layout: MenuBarLayout(lines: [[.balance, .separatorDot, .percent(window: .automatic)]]), data: data)
        if let path = ProcessInfo.processInfo.environment["CODEXBAR_JETBRAINS_BALANCE_PROOF"] {
            let image = NSImage(size: NSSize(width: 420, height: 90))
            image.lockFocus()
            NSColor.white.setFill()
            NSRect(x: 0, y: 0, width: 420, height: 90).fill()
            ("JetBrains · Balance + monthly % used · synthetic" as NSString).draw(
                at: NSPoint(x: 16, y: 60),
                withAttributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.black])
            let title = NSMutableAttributedString(attributedString: output.attributedTitle)
            title.addAttribute(
                .foregroundColor,
                value: NSColor.black,
                range: NSRange(location: 0, length: title.length))
            title.draw(at: NSPoint(x: 16, y: 24))
            image.unlockFocus()
            let tiff = try #require(image.tiffRepresentation)
            let bitmap = try #require(NSBitmapImageRep(data: tiff))
            try #require(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: path))
        }
        #expect(data.balance == "54.90 credits")
        #expect(data.automaticText == nil)
        #expect(output.attributedTitle.string == "54.90 credits\u{2009}·\u{2009}7%")
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `Nous reported credits reach balance and automatic tokens`(engine: ProviderPluginEngineKind) async throws {
        let snapshot = try await NousPluginTests.fetch(Self.nousCreditsAccount, engine: engine)
        #expect(snapshot.primary == nil)
        #expect(snapshot.details.flatMap(\.rows).map(\.value) == ["$6.76", "$6.76"])
        let data = self.data(provider: .nous, snapshot: snapshot)
        #expect(data.balance == "$6.76")
        #expect(data.automaticText == "$6.76")
        for token: MenuBarLayoutToken in [.balance, .percent(window: .automatic)] {
            #expect(self.render(layout: MenuBarLayout(lines: [[token]]), data: data).attributedTitle.string == "$6.76")
        }
    }

    /// Credit amounts and absent monthly grant reported in #4314; no account identifiers.
    private static let nousCreditsAccount = #"""
    {"subscription":null,"purchased_credits_remaining":6.76,
     "paid_service_access":{"has_active_subscription":false,"total_usable_credits":6.76}}
    """#

    @Test(arguments: [
        (#"{"subscription":null,"purchased_credits_remaining":"6.76"}"#, "$6.76" as String?),
        (#"{"paid_service_access":{"total_usable_credits":0},"purchased_credits_remaining":6.76}"#, "$0.00"),
        (#"{"paid_service_access":{"total_usable_credits":"6.76"}}"#, "$6.76"),
        (#"{"subscription":{"monthly_credits":220}}"#, nil),
    ], BundledPluginTestSupport.engines)
    func `Nous balance uses reported total then purchased credits without inventing amounts`(
        fixture: (String, String?),
        engine: ProviderPluginEngineKind) async throws
    {
        let snapshot = try await NousPluginTests.fetch(fixture.0, engine: engine)
        let data = self.data(provider: .nous, snapshot: snapshot)
        #expect(data.balance == fixture.1)
        #expect(data.automaticText == fixture.1)
        #expect(self.render(layout: MenuBarLayout(lines: [[.balance]]), data: data)
            .attributedTitle.string == (fixture.1 ?? "–"))
        #expect(MenuBarLayoutBalanceResolver.balance(provider: .claude, snapshot: snapshot) == nil)
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `Nous total balance coexists with monthly percentage`(engine: ProviderPluginEngineKind) async throws {
        let snapshot = try await NousPluginTests.fetch(NousPluginTests.account, engine: engine)
        let data = self.data(provider: .nous, snapshot: snapshot)
        #expect(data.balance == "$74.25")
        #expect(data.automaticText == nil)
        #expect(self.render(layout: MenuBarLayout(lines: [[.percent(window: .automatic)]]), data: data)
            .attributedTitle.string == "75%")
    }

    @Test
    func `synthetic Nous balance renderer proof`() async throws {
        guard let path = ProcessInfo.processInfo.environment["CODEXBAR_NOUS_BALANCE_PROOF"] else { return }
        let snapshot = try await NousPluginTests.fetch(Self.nousCreditsAccount, engine: .quickJS)
        let output = self.render(
            layout: MenuBarLayout(lines: [[.providerName, .separatorDot, .balance]]),
            data: self.data(provider: .nous, snapshot: snapshot))
        let image = NSImage(size: NSSize(width: 360, height: 90))
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: 360, height: 90).fill()
        ("Nous Portal · Balance layout · synthetic $6.76" as NSString).draw(
            at: NSPoint(x: 16, y: 60),
            withAttributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.black])
        let title = NSMutableAttributedString(attributedString: output.attributedTitle)
        title.addAttribute(.foregroundColor, value: NSColor.black, range: NSRange(location: 0, length: title.length))
        title.draw(at: NSPoint(x: 16, y: 24))
        image.unlockFocus()
        let tiff = try #require(image.tiffRepresentation)
        let bitmap = try #require(NSBitmapImageRep(data: tiff))
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: path))
    }

    @Test(arguments: ["$2.57", "$0.00", "-$1.25", "Less than $0.01"])
    func `balance only plugin amounts reach automatic and explicit tokens`(amount: String) throws {
        let snapshot = try UsageSnapshot(
            primary: nil,
            secondary: nil,
            details: [ProviderDetailSection(title: "Billing", rows: [.init(label: "Balance", value: amount)])],
            updatedAt: self.now,
            identity: ProviderIdentitySnapshot(
                providerID: .lithosai,
                accountEmail: nil,
                accountOrganization: nil,
                loginMethod: "Browser session"))
        let data = self.data(provider: .lithosai, snapshot: snapshot)
        #expect(data.balance == amount)
        #expect(data.automaticText == amount)
        for token: MenuBarLayoutToken in [.balance, .percent(window: .automatic)] {
            #expect(self.render(layout: MenuBarLayout(lines: [[token]]), data: data).attributedTitle.string == amount)
        }
        #expect(MenuBarLayoutBalanceResolver.balance(provider: .claude, snapshot: snapshot) == nil)
        #expect(MenuBarLayoutBalanceResolver.balance(provider: .poe, snapshot: snapshot) == nil)
    }

    @Test
    func `TypeSafe plugin balance reaches automatic and explicit layout tokens`() async throws {
        let snapshot = try await TypeSafePluginTests.fetch(engine: .quickJS)
        let data = self.data(provider: .typesafe, snapshot: snapshot)
        #expect(data.balance == "$4.98")
        #expect(data.automaticText == "$4.98")
        for token: MenuBarLayoutToken in [.balance, .percent(window: .automatic)] {
            #expect(self.render(layout: MenuBarLayout(lines: [[token]]), data: data).attributedTitle.string == "$4.98")
        }
    }

    @Test(arguments: [
        (UsageProvider.typesafe, UsageProvider.typesafe, "$4.98" as String?),
        (.poe, .typesafe, nil),
        (.claude, .claude, nil),
    ])
    func `balance labels require matching provider identity and declared presentation`(
        provider: UsageProvider,
        identityProvider: UsageProvider,
        expected: String?)
    {
        let snapshot = UsageSnapshot(
            primary: nil,
            secondary: nil,
            updatedAt: self.now,
            identity: ProviderIdentitySnapshot(
                providerID: identityProvider.instanceID,
                accountEmail: nil,
                accountOrganization: nil,
                loginMethod: "Balance: $4.98"))
        #expect(MenuBarLayoutBalanceResolver.balance(provider: provider, snapshot: snapshot)
            == expected)
        #expect(MenuBarLayoutBalanceResolver.balance(provider: provider, snapshot: nil) == nil)
    }

    @Test(arguments: [UsageProvider.mimo, .hyper, .atlascloud, .vercel, .devpass, .openrouter])
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

    @Test(arguments: [UsageProvider.mimo, .hyper, .atlascloud, .vercel, .devpass, .doubao, .lithosai])
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

    @Test(arguments: [UsageProvider.nous, .openrouter, .atlascloud, .vercel, .devpass, .jetbrains])
    func `declared balance rows do not borrow identity text or another provider`(provider: UsageProvider) throws {
        let snapshot = UsageSnapshot(
            primary: nil,
            secondary: nil,
            updatedAt: self.now,
            identity: ProviderIdentitySnapshot(
                providerID: provider.instanceID,
                accountEmail: nil,
                accountOrganization: nil,
                loginMethod: "Balance: $99.00"))
        #expect(MenuBarLayoutBalanceResolver.balance(provider: provider, snapshot: snapshot) == nil)
        let otherProvider = try UsageSnapshot(
            primary: nil,
            secondary: nil,
            details: [ProviderDetailSection(rows: [
                .init(label: "Total usable", value: "$99.00"),
                .init(label: "Remaining", value: "$99.00"),
                .init(label: "Available balance", value: "$99.00"),
                .init(label: "Cycle remaining", value: "$99.00"),
            ])],
            updatedAt: self.now,
            identity: ProviderIdentitySnapshot(
                providerID: .claude, accountEmail: nil, accountOrganization: nil, loginMethod: nil))
        #expect(MenuBarLayoutBalanceResolver.balance(provider: provider, snapshot: otherProvider) == nil)
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
        let providers: [UsageProvider] = [.mimo, .hyper, .atlascloud, .vercel, .devpass, .lithosai]
        let image = NSImage(size: NSSize(width: 620, height: 300))
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: 620, height: 300).fill()
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 14), .foregroundColor: NSColor.black,
        ]
        ("Stored layout: Balance · Auto % — synthetic data" as NSString)
            .draw(at: NSPoint(x: 16, y: 270), withAttributes: attributes)
        for (index, provider) in providers.enumerated() {
            let (snapshot, _) = try self.fixture(provider: provider)
            let output = self.render(
                layout: MenuBarLayout(lines: [[.balance, .separatorDot, .percent(window: .automatic)]]),
                data: self.data(provider: provider, snapshot: snapshot))
            let y = CGFloat(230 - index * 40)
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
        let label = provider == .devpass ? "Cycle remaining"
            : provider == .openrouter ? "Remaining"
            : [.hyper, .lithosai].contains(provider) ? "Balance" : "Available balance"
        let value = provider == .hyper ? "42.5 HC" : provider == .lithosai ? "$2.57" : "$25.00"
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
