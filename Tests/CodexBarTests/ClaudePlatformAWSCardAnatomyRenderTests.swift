import AppKit
import SwiftUI
import XCTest
@testable import CodexBar
@testable import CodexBarCore

/// Opt-in render of the Claude Platform on AWS menu card from synthetic spend, with its parts outlined and
/// named. Nothing is fetched: the bundled plugin runs against a transport that serves generated rows.
@MainActor
final class ClaudePlatformAWSCardAnatomyRenderTests: XCTestCase {
    /// 2026-11-11T15:30:10Z; the 30-day window starts on 2026-10-13 and the month on 2026-11-01.
    private nonisolated static let now = Date(timeIntervalSince1970: 1_794_411_010)
    private nonisolated static let todayStart: TimeInterval = 1_794_355_200
    private nonisolated static let completedDays = 29
    private nonisolated static let firstNovemberDay = 19
    private static let menuWidth: CGFloat = 320

    /// Workspace, model, and spend in cents on an average day.
    private nonisolated static let combos: [(workspace: String?, model: String?, cents: Double)] = [
        ("wrkspc_fixtureA", "fixture-model-a", 2600),
        ("wrkspc_fixtureA", "fixture-model-b", 1100),
        ("wrkspc_fixtureB", "fixture-model-a", 900),
        ("wrkspc_fixtureB", "fixture-model-c", 500),
        (nil, nil, 120),
    ]

    func test_renderSyntheticCardAnatomy() async throws {
        guard let path = ProcessInfo.processInfo.environment["CODEXBAR_AWS_ANATOMY_DIR"] else {
            throw XCTSkip("Set CODEXBAR_AWS_ANATOMY_DIR to render the synthetic Claude Platform on AWS card.")
        }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let (model, tokens) = try await Self.syntheticCard()
        let dashboard = try XCTUnwrap(model.inlineUsageDashboard)
        XCTAssertFalse(model.metrics.isEmpty)
        XCTAssertEqual(model.providerDetails.count(where: { $0.variant != nil }), 10)

        try CodexBarLocalizationOverride.$appLanguage.withValue("en") {
            let chartHeight = Self.fittingHeight(
                InlineUsageDashboardContent(model: dashboard)
                    .frame(width: Self.menuWidth - 2 * UsageMenuCardLayout.horizontalPadding))
            let view = AnyView(
                AnatomyView(model: model, tokens: tokens, width: Self.menuWidth, chartHeight: chartHeight)
                    .environment(\.locale, Locale(identifier: "en_US_POSIX"))
                    .environment(\.timeZone, Self.utcCalendar.timeZone)
                    .environment(\.colorScheme, .light)
                    .environment(\.displayScale, 2))
            let hosting = NSHostingView(rootView: view)
            hosting.appearance = NSAppearance(named: .aqua)
            let url = directory.appendingPathComponent("claudeplatformaws-card-anatomy.png")
            try XCTUnwrap(MenuLayoutScreenshotRenderTests.pngDataWithWindow(hosting: hosting)).write(to: url)
            print("Wrote \(url.path)")
        }
    }

    private static var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        return calendar
    }

    /// The card of a two-region account with both budgets set, built by the bundled plugin from generated rows.
    static func syntheticCard() async throws -> (model: UsageMenuCardView.Model, tokens: CostUsageTokenSnapshot) {
        let snapshot = try await Self.runtime().fetchUsage(
            settings: [
                "ANTHROPIC_AWS_REGIONS": "us-west-2, us-east-1",
                "ANTHROPIC_AWS_TIME_ZONE": "utc",
                "ANTHROPIC_AWS_MONTHLY_BUDGET": "1500",
                "ANTHROPIC_AWS_DAILY_BUDGET": "80",
            ],
            secrets: [
                "ANTHROPIC_AWS_ACCESS_KEY_ID": "FIXTUREKEYID",
                "ANTHROPIC_AWS_SECRET_ACCESS_KEY": "fixture-secret",
            ],
            now: Self.now)
        let tokens = try XCTUnwrap(ClaudePlatformAWSCostUsageMapping.tokenSnapshot(from: snapshot))
        let model = try UsageMenuCardView.Model.make(.init(
            provider: .claudeplatformaws,
            metadata: XCTUnwrap(ProviderDefaults.metadata[.claudeplatformaws]),
            snapshot: snapshot,
            credits: nil,
            creditsError: nil,
            dashboardError: nil,
            tokenSnapshot: tokens,
            tokenError: nil,
            account: AccountInfo(email: nil, plan: snapshot.loginMethod(for: .claudeplatformaws)),
            isRefreshing: false,
            lastError: nil,
            usageBarsShowUsed: true,
            resetTimeDisplayStyle: .absolute,
            tokenCostUsageEnabled: true,
            costSummaryInlineEnabled: true,
            showOptionalCreditsAndExtraUsage: true,
            hidePersonalInfo: false,
            usesLiveSubtitle: false,
            costUsageBucketCalendar: Self.utcCalendar,
            now: Self.now))
        return (model, tokens)
    }

    private static func fittingHeight(_ view: some View) -> CGFloat {
        let hosting = NSHostingView(rootView: view.environment(\.colorScheme, .light))
        hosting.appearance = NSAppearance(named: .aqua)
        return hosting.fittingSize.height
    }

    // MARK: - Synthetic API

    private static func runtime() throws -> ProviderPluginRuntime {
        try BundledPluginTestSupport.runtime(
            "claudeplatformaws",
            engine: .quickJS,
            transport: ProviderHTTPTransportHandler { request in
                let url = try XCTUnwrap(request.url)
                let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedQuery ?? ""
                // us-east-1 carries a fifth of the spend of us-west-2.
                let scale = (url.host ?? "").contains("us-east-1") ? 0.2 : 1
                let daily = query.contains("time_bucket_width=1d")
                let today = query.contains("starting_at=2026-11-11T00")
                let body: String = switch url.lastPathComponent {
                case "cost":
                    Self.page(Self.costRows(daily: daily, today: today, scale: scale))
                case "usage":
                    Self.page(Self.usageRows(daily: daily, scale: scale))
                default:
                    #"{"data":[{"id":"wrkspc_fixtureA","type":"workspace","name":"Fixture Production"},"#
                        + #"{"id":"wrkspc_fixtureB","type":"workspace","name":"Fixture Research"}],"has_more":false}"#
                }
                let response = try XCTUnwrap(HTTPURLResponse(
                    url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"]))
                return (Data(body.utf8), response)
            })
    }

    private nonisolated static func page(_ rows: [String]) -> String {
        #"{"data":["# + rows.joined(separator: ",")
            + #"],"has_more":false,"next_page":null,"data_refreshed_at":"2026-11-11T12:02:11Z"}"#
    }

    private nonisolated static func quoted(_ value: String?) -> String {
        value.map { "\"\($0)\"" } ?? "null"
    }

    private nonisolated static func stamp(day: Int) -> String {
        let start = Self.todayStart - Double(Self.completedDays - day) * 86400
        return ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: start))
    }

    /// Spend of one combination on one day; `day` counts from 2026-10-13 and today is a partial day.
    private nonisolated static func cents(combo: Int, day: Int, scale: Double) -> Double {
        let level = day == Self.completedDays ? 0.6 : 1 + 0.3 * sin(Double(day) * 0.9 + Double(combo))
        return (Self.combos[combo].cents * level * scale).rounded()
    }

    private nonisolated static func costRows(daily: Bool, today: Bool, scale: Double) -> [String] {
        func row(_ combo: Int, start: String, cents: Double) -> String {
            #"{"starting_at":""# + start + #"","ending_at":""# + start + #"","group":{"model":"#
                + Self.quoted(Self.combos[combo].model) + #","workspace_id":"#
                + Self.quoted(Self.combos[combo].workspace) + #"},"cost":{"currency":"USD","amount":""#
                + String(format: "%.6f", cents) + #"","list_amount":""# + String(format: "%.6f", cents * 1.2)
                + #"","requests":"# + String(Int(cents / 20)) + "}}"
        }
        let combos = Self.combos.indices
        func rows(day: Int) -> [String] {
            combos.map { row($0, start: Self.stamp(day: day), cents: Self.cents(combo: $0, day: day, scale: scale)) }
        }
        if daily {
            return (0..<Self.completedDays).flatMap(rows)
        }
        if today {
            return rows(day: Self.completedDays)
        }
        // The month total: every November day so far, so it agrees with the daily series.
        return combos.map { combo in
            let month = (Self.firstNovemberDay...Self.completedDays)
                .reduce(0) { $0 + Self.cents(combo: combo, day: $1, scale: scale) }
            return row(combo, start: Self.stamp(day: Self.firstNovemberDay), cents: month)
        }
    }

    private nonisolated static func usageRows(daily: Bool, scale: Double) -> [String] {
        let days = daily ? Array(0..<Self.completedDays) : [Self.completedDays]
        return days.flatMap { day in
            Self.combos.indices.compactMap { combo -> String? in
                guard let model = Self.combos[combo].model else { return nil }
                let cents = Self.cents(combo: combo, day: day, scale: scale)
                return #"{"starting_at":""# + Self.stamp(day: day) + #"","group":{"model":""# + model
                    + #"","workspace_id":null},"usage":{"uncached_input_tokens":"# + String(Int(cents * 400))
                    + #","cache_read_input_tokens":0,"cache_creation":{"ephemeral_5m_input_tokens":0,"#
                    + #""ephemeral_1h_input_tokens":0},"output_tokens":"# + String(Int(cents * 40))
                    + #","total_tokens":0,"requests":1}}"#
            }
        }
    }
}

// MARK: - Annotated layout

private struct AnatomyView: View {
    let model: UsageMenuCardView.Model
    let tokens: CostUsageTokenSnapshot
    let width: CGFloat
    let chartHeight: CGFloat

    private static let hover = Color.blue
    private static let details = Color.orange
    private static let submenu = Color.purple

    private var sections: [ProviderDetailSection] {
        self.model.providerDetails
    }

    var body: some View {
        HStack(alignment: .top, spacing: 36) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Menu card").font(.headline)
                self.card
            }
            VStack(alignment: .leading, spacing: 10) {
                Text("Submenu").font(.headline)
                CostHistoryChartMenuView(
                    provider: self.model.provider,
                    daily: self.tokens.daily,
                    totalCostUSD: self.tokens.last30DaysCostUSD,
                    historyDays: self.tokens.historyDays,
                    windowLabel: self.tokens.historyLabel,
                    hidePersonalInfo: false,
                    width: self.width)
                    .modifier(Part(number: 8, color: Self.submenu))
                    .modifier(MenuSurface())
                self.legend
            }
        }
        .padding(28)
        .background(Color(white: 0.93))
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 0) {
            UsageMenuCardHeaderSectionView(model: self.model, showDivider: true, width: self.width)
                .modifier(Part(number: 1, color: Self.hover))
            UsageMenuCardUsageSectionView(
                model: self.model,
                layoutModel: self.model,
                showBottomDivider: false,
                bottomPadding: 6,
                width: self.width,
                showsProviderDetails: false)
                .overlay {
                    // The usage row draws its meters above its chart; the chart's height is measured separately.
                    VStack(spacing: 0) {
                        Color.clear.modifier(Part(number: 2, color: Self.hover))
                        Color.clear.frame(height: self.chartHeight + 12).modifier(Part(number: 3, color: Self.hover))
                    }
                }
            Divider()
            self.detail(4) { $0.variant == nil && $0.title == "Spend" }
            Divider().padding(.horizontal, UsageMenuCardLayout.horizontalPadding)
            self.detail(5) { $0.variant == nil && $0.title != "Spend" }
            Divider().padding(.horizontal, UsageMenuCardLayout.horizontalPadding)
            self.detail(6) { $0.variant != nil }
                .overlay(alignment: .top) {
                    Color.clear.frame(height: 62).modifier(Part(number: 6, color: Self.details))
                }
        }
        .modifier(MenuSurface())
    }

    /// The breakdown is numbered twice: 6 marks its pickers, 7 the rows they select.
    private func detail(_ number: Int, _ matches: (ProviderDetailSection) -> Bool) -> some View {
        ProviderDetailSectionsContent(
            sections: self.sections.filter(matches),
            chartColor: self.model.progressColor,
            paceVisible: self.model.detailPaceVisible)
            .padding(.horizontal, UsageMenuCardLayout.horizontalPadding)
            .padding(.vertical, 8)
            .frame(width: self.width, alignment: .leading)
            .modifier(Part(number: number == 6 ? 7 : number, color: Self.details, badgeAtBottom: number == 6))
    }

    private var legend: some View {
        VStack(alignment: .leading, spacing: 7) {
            self.entry(1, Self.hover, "Header", "Provider, last update, sign-in method")
            self.entry(2, Self.hover, "Budget meters", "Today and This month, shown once budgets are set")
            self.entry(3, Self.hover, "Inline spend chart", "Today, 30-day spend, tokens, requests, daily bars")
            self.entry(4, Self.details, "Spend details", "Month, today, projection, requests, data freshness")
            self.entry(5, Self.details, "By region", "Shown with more than one region")
            self.entry(6, Self.details, "Breakdown pickers", "Model or Workspace; 30d, MTD, 7d, Yesterday, Today")
            self.entry(7, Self.details, "Breakdown", "Spend and share for the picked dimension and period")
            self.entry(8, Self.submenu, "Usage history submenu", "Opens while the pointer is over 1 to 3")
            Text("Blue: the usage row, whose hover opens the submenu.\nOrange: the details row, which does not.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 4)
        }
        .frame(width: self.width, alignment: .leading)
    }

    private func entry(_ number: Int, _ color: Color, _ name: String, _ note: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Badge(number: number, color: color)
            VStack(alignment: .leading, spacing: 1) {
                Text(name).font(.callout.weight(.semibold))
                Text(note).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

private struct MenuSurface: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(Color(nsColor: .windowBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.black.opacity(0.15)))
    }
}

private struct Badge: View {
    let number: Int
    let color: Color

    var body: some View {
        Text("\(self.number)")
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 15, height: 15)
            .background(Circle().fill(self.color))
    }
}

/// Outlines a part and puts its number in the card's leading margin.
private struct Part: ViewModifier {
    let number: Int
    let color: Color
    var badgeAtBottom = false

    func body(content: Content) -> some View {
        content
            .overlay {
                RoundedRectangle(cornerRadius: 5)
                    .stroke(self.color.opacity(0.75), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .padding(2)
            }
            .overlay(alignment: self.badgeAtBottom ? .bottomLeading : .topLeading) {
                Badge(number: self.number, color: self.color).padding(3)
            }
    }
}
