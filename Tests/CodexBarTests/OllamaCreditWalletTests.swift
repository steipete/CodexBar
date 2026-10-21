import AppKit
import Testing
@testable import CodexBar
@testable import CodexBarCore

@MainActor
struct OllamaCreditWalletTests {
    /// Contributor-supplied sanitized excerpt of the current settings page (#4370).
    /// The variants below are synthetic regressions, not additional live captures.
    static let wallet = """
    <section>
      <div>
        <h2>Usage credits<span>pro</span></h2>
        <span>$18.25</span>
        <p>Refills to $30 in 3 weeks.</p>
      </div>
      <div>
        <span>Monthly credits used</span>
        <span>$4.50</span>
      </div>
    </section>
    """

    @Test
    func `wallet fields reach details without a quota`() throws {
        let usage = try OllamaUsageParser.parse(html: Self.wallet).toUsageSnapshot()
        #expect(usage.primary == nil)
        #expect(usage.secondary == nil)
        #expect(usage.identity?.loginMethod == "pro")
        #expect(usage.detailRow(label: "Credit balance")?.value == "$18.25")
        #expect(usage.detailRow(label: "Monthly credits used")?.value == "$4.50")
        #expect(usage.detailRow(label: "Next refill")?.value == "to $30 in 3 weeks.")
    }

    @Test
    func `monthly spending cannot become a missing balance`() throws {
        let html = Self.wallet.replacingOccurrences(of: "<span>$18.25</span>", with: "")
        let usage = try OllamaUsageParser.parse(html: html).toUsageSnapshot()
        #expect(usage.detailRow(label: "Credit balance") == nil)
        #expect(usage.detailRow(label: "Monthly credits used")?.value == "$4.50")
        #expect(MenuBarLayoutBalanceResolver.balance(provider: .ollama, snapshot: usage) == nil)
    }

    @Test(arguments: ["Previous Monthly credits used", "Monthly credits used estimate"])
    func `wallet monthly labels match complete elements`(label: String) throws {
        let html = Self.wallet.replacingOccurrences(of: "Monthly credits used", with: label)
        let usage = try OllamaUsageParser.parse(html: html).toUsageSnapshot()
        #expect(usage.detailRow(label: "Monthly credits used") == nil)
        #expect(usage.detailRow(label: "Credit balance")?.value == "$18.25")
    }

    @Test
    func `refill text ends at its element without sentence punctuation`() throws {
        let html = Self.wallet.replacingOccurrences(of: "3 weeks.</p>", with: "3 weeks</p>")
        let usage = try OllamaUsageParser.parse(html: html).toUsageSnapshot()
        #expect(usage.detailRow(label: "Next refill")?.value == "to $30 in 3 weeks")
    }

    @Test
    func `wallet balance reaches explicit and automatic layout text`() throws {
        let usage = try UsageSnapshot(
            primary: nil,
            secondary: nil,
            details: [ProviderDetailSection(title: "Ollama credits", rows: [
                .init(label: "Credit balance", value: "$18.25"),
            ])],
            updatedAt: Date(),
            identity: ProviderIdentitySnapshot(
                providerID: .ollama, accountEmail: nil, accountOrganization: nil, loginMethod: "pro"))
        #expect(MenuBarLayoutBalanceResolver.balance(provider: .ollama, snapshot: usage) == "$18.25")
        #expect(StatusItemController.menuBarLayoutAutomaticText(
            provider: .ollama, snapshot: usage, automatic: nil) == "$18.25")
        #expect(MenuBarLayoutBalanceResolver.balance(provider: .claude, snapshot: usage) == nil)
        #expect(self.render(usage).attributedTitle.string.components(separatedBy: "$18.25").count == 3)
    }

    @Test
    func `wallet details coexist with an unchanged monthly quota`() throws {
        let html = Self.wallet + """
        <div><span>Monthly usage</span><span>$7.50 of $60 used</span>
        <div data-time="2026-10-30T15:14:29Z">Resets in 4 weeks.</div></div>
        """
        let usage = try OllamaUsageParser.parse(html: html).toUsageSnapshot()
        #expect(usage.primary?.usedPercent == 12.5)
        #expect(usage.primary?.windowMinutes == ProviderPaceCapability.monthlyWindowSentinelMinutes)
        #expect(usage.primary?.resetsAt == ISO8601DateFormatter().date(from: "2026-10-30T15:14:29Z"))
        #expect(usage.detailRow(label: "Credit balance")?.value == "$18.25")
        #expect(MenuBarLayoutBalanceResolver.balance(provider: .ollama, snapshot: usage) == "$18.25")
        #expect(StatusItemController.menuBarLayoutAutomaticText(
            provider: .ollama, snapshot: usage, automatic: MenuBarLayoutRenderWindow(usage.primary)) == nil)
    }

    @Test
    func `wallet does not borrow fields outside its section`() throws {
        let html = """
        <section><h2>Usage credits<span>pro</span></h2><span>$0.00</span></section>
        <section><span>Monthly credits used</span><span>$99.00</span>
        <p>Refills to $100 in 2 weeks.</p></section>
        """
        let usage = try OllamaUsageParser.parse(html: html).toUsageSnapshot()
        #expect(usage.details.flatMap(\.rows).map(\.value) == ["$0.00"])
    }

    @Test(arguments: [-10.0, 0, 50, 110])
    func `shared quota projection keeps clamping durations and reset dates`(percent: Double) {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let snapshot = OllamaUsageSnapshot(
            planName: " pro ",
            accountEmail: " user@example.com ",
            monthlyUsedPercent: percent,
            monthlyResetsAt: now,
            sessionUsedPercent: percent,
            weeklyUsedPercent: percent,
            sessionResetsAt: now,
            weeklyResetsAt: now,
            sessionWindowMinutes: 300,
            updatedAt: now)
        let usage = snapshot.toUsageSnapshot()
        #expect(usage.primary?.usedPercent == min(100, max(0, percent)))
        #expect(usage.secondary?.usedPercent == min(100, max(0, percent)))
        #expect(usage.primary?.resetsAt == now)
        #expect(usage.secondary?.resetsAt == now)
        #expect(usage.primary?.windowMinutes == ProviderPaceCapability.monthlyWindowSentinelMinutes)
        #expect(usage.secondary?.windowMinutes == 10080)
        #expect(usage.identity?.accountEmail == "user@example.com")
        #expect(usage.identity?.loginMethod == "pro")
        #expect(usage.details.isEmpty)
    }

    @Test
    func `synthetic wallet layout render proof`() throws {
        guard let path = ProcessInfo.processInfo.environment["CODEXBAR_OLLAMA_WALLET_PROOF"] else { return }
        let usage = try? OllamaUsageParser.parse(html: Self.wallet).toUsageSnapshot()
        let output = self.render(usage)
        let image = NSImage(size: NSSize(width: 640, height: 240))
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: 640, height: 240).fill()
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 15), .foregroundColor: NSColor.black,
        ]
        ("Ollama · Synthetic wallet fixture" as NSString).draw(
            at: NSPoint(x: 20, y: 206), withAttributes: attributes)
        ("Balance · Automatic layout" as NSString).draw(
            at: NSPoint(x: 20, y: 174), withAttributes: attributes)
        let title = NSMutableAttributedString(attributedString: output.attributedTitle)
        title.addAttribute(.foregroundColor, value: NSColor.black, range: NSRange(location: 0, length: title.length))
        title.draw(at: NSPoint(x: 340, y: 174))
        let rows = usage?.details.flatMap(\.rows).map { "\($0.label): \($0.value)" }
            ?? ["Could not parse Ollama usage: Missing Ollama usage data."]
        for (index, row) in rows.enumerated() {
            (row as NSString).draw(at: NSPoint(x: 20, y: CGFloat(130 - index * 32)), withAttributes: attributes)
        }
        image.unlockFocus()
        let tiff = try #require(image.tiffRepresentation)
        let bitmap = try #require(NSBitmapImageRep(data: tiff))
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: path))
    }

    private func render(_ usage: UsageSnapshot?) -> MenuBarLayoutRenderedTitle {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let data = MenuBarLayoutRenderData(
            provider: .ollama,
            iconKey: "ollama",
            providerName: "Ollama",
            accountLabel: nil,
            laneLabels: MenuBarLayoutLaneLabels(provider: .ollama, snapshot: usage),
            primary: nil,
            secondary: nil,
            tertiary: nil,
            session: nil,
            weekly: nil,
            scopedWeekly: nil,
            scopedWeeklyTitle: nil,
            automatic: nil,
            automaticText: StatusItemController.menuBarLayoutAutomaticText(
                provider: .ollama, snapshot: usage, automatic: nil),
            sessionPace: nil,
            weeklyPace: nil,
            automaticPace: nil,
            runsOut: nil,
            balance: MenuBarLayoutBalanceResolver.balance(provider: .ollama, snapshot: usage),
            costToday: nil,
            cost30d: nil,
            metrics: .unavailable)
        return MenuBarLayoutRenderer().render(
            layout: MenuBarLayout(lines: [[.balance, .separatorDot, .percent(window: .automatic)]]),
            data: data,
            icon: nil,
            options: MenuBarLayoutRenderOptions(
                size: .regular,
                highContrast: false,
                showUsed: true,
                conditionals: [],
                appearanceName: "aqua",
                isDebugApp: false,
                now: now))
    }
}
