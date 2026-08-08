import AppKit
import CodexBarCore
import SwiftUI
import Testing
@testable import CodexBar

@MainActor
struct UsageMenuCardLayoutTests {
    private static let heightTolerance: CGFloat = 1

    @Test
    func `overview groups provider content without section dividers`() {
        #expect(OverviewMenuCardRowView.showsSectionDividers == false)
    }

    @Test
    func `header only menu card keeps comfortable padding`() {
        let model = Self.model()
        let width: CGFloat = 296

        let headerSize = NSHostingController(rootView: UsageMenuCardHeaderSectionView(
            model: model,
            showDivider: false,
            width: width))
            .sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude))
        let cardSize = NSHostingController(rootView: UsageMenuCardView(model: model, width: width))
            .sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude))

        #expect(headerSize.height > 0)
        #expect(abs(cardSize.height - headerSize.height) < Self.heightTolerance)
    }

    @Test
    func `overview uses a fixed compact card instead of the full provider detail height`() {
        let model = Self.model(metrics: [
            UsageMenuCardView.Model.Metric(
                id: "session",
                title: "Session",
                percent: 37,
                percentStyle: .left,
                resetText: "Resets in 41m",
                detailText: nil,
                detailLeftText: "24% in reserve",
                detailRightText: "Lasts until reset",
                pacePercent: nil,
                paceOnTop: true),
            UsageMenuCardView.Model.Metric(
                id: "weekly",
                title: "Weekly",
                percent: 52,
                percentStyle: .left,
                resetText: "Resets Friday",
                detailText: nil,
                detailLeftText: nil,
                detailRightText: nil,
                pacePercent: nil,
                paceOnTop: true),
        ])
        let width: CGFloat = 296

        let fullCardSize = NSHostingController(rootView: UsageMenuCardView(model: model, width: width))
            .sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude))
        let overviewSize = NSHostingController(rootView: OverviewMenuCardRowView(
            model: model,
            storageText: nil,
            width: width))
            .sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude))
        let emptyOverviewSize = NSHostingController(rootView: OverviewMenuCardRowView(
            model: Self.model(),
            storageText: nil,
            width: width))
            .sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude))

        #expect(overviewSize.height == OverviewMenuCardRowView.rowHeight)
        #expect(emptyOverviewSize.height == OverviewMenuCardRowView.rowHeight)
        #expect(overviewSize.height < fullCardSize.height)
        #expect(OverviewMenuCardRowView.primaryMetric(for: model)?.id == "session")
    }

    @Test
    func `overview keeps one prominent provider and compresses the remaining rows`() {
        let model = Self.model(metrics: [
            UsageMenuCardView.Model.Metric(
                id: "session",
                title: "Session",
                percent: 37,
                percentStyle: .left,
                resetText: "Resets in 41m",
                detailText: nil,
                detailLeftText: nil,
                detailRightText: nil,
                pacePercent: nil,
                paceOnTop: true),
        ])
        let width: CGFloat = 296

        let prominent = NSHostingController(rootView: OverviewMenuCardRowView(
            model: model,
            storageText: nil,
            width: width,
            emphasis: .prominent))
            .sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude))
        let compact = NSHostingController(rootView: OverviewMenuCardRowView(
            model: model,
            storageText: nil,
            width: width,
            emphasis: .compact))
            .sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude))

        #expect(prominent.height == OverviewMenuCardRowView.rowHeight)
        #expect(compact.height == OverviewMenuCardRowView.compactRowHeight)
        #expect(compact.height < prominent.height)
        #expect(OverviewMenuCardRowView.compactSpendText(for: model) == "Spend unavailable")

        let accessibilityCompact = NSHostingController(rootView: OverviewMenuCardRowView(
            model: model,
            storageText: nil,
            width: width,
            emphasis: .compact)
            .environment(\.dynamicTypeSize, .accessibility2))
            .sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude))
        #expect(accessibilityCompact.height >= OverviewMenuCardRowView.accessibilityRowHeight)
    }

    @Test
    func `overview spend summary keeps partial totals honest across connected services`() {
        let group = SpendDashboardModel.CurrencyGroup(
            currencyCode: "USD",
            providers: [
                .init(
                    id: "codex",
                    rank: 1,
                    provider: .codex,
                    displayName: "Codex",
                    totalTokens: 4_820_000,
                    totalCost: 412.64,
                    coveredDayCount: 30),
                .init(
                    id: "claude",
                    rank: 2,
                    provider: .claude,
                    displayName: "Claude",
                    totalTokens: nil,
                    totalCost: nil,
                    coveredDayCount: 8),
                .init(
                    id: "openrouter",
                    rank: 3,
                    provider: .openrouter,
                    displayName: "OpenRouter",
                    totalTokens: 9_640_000,
                    totalCost: 282.74,
                    coveredDayCount: 30),
                .init(
                    id: "gemini",
                    rank: 4,
                    provider: .gemini,
                    displayName: "Gemini",
                    totalTokens: nil,
                    totalCost: nil,
                    coveredDayCount: 0),
                .init(
                    id: "grok",
                    rank: 5,
                    provider: .grok,
                    displayName: "Grok",
                    totalTokens: nil,
                    totalCost: nil,
                    coveredDayCount: 0),
                .init(
                    id: "cursor",
                    rank: 6,
                    provider: .cursor,
                    displayName: "Cursor",
                    totalTokens: 1_250_000,
                    totalCost: 64.18,
                    coveredDayCount: 30),
            ],
            models: [],
            dailyPoints: [],
            totalTokens: nil,
            totalCost: nil,
            coveredDayCount: 30,
            chartDomain: Date(timeIntervalSince1970: 1_783_036_800)...Date(timeIntervalSince1970: 1_785_628_800),
            modelHistoryCompleteness: .incomplete)
        let summary = OverviewSpendSummary(
            model: SpendDashboardModel(requestedDays: 30, groups: [group]),
            connectedProviderCount: 6)

        #expect(summary.primarySpendText == "~$759.56")
        #expect(summary.coverageText == "3 / 6 Providers")
        #expect(summary.tokenText == "~15.7M tokens")
        #expect(summary.isPartial)
    }

    @Test
    func `overview prioritizes refresh status and expands for accessibility text`() {
        let metric = UsageMenuCardView.Model.Metric(
            id: "weekly",
            title: "Weekly",
            percent: 52,
            percentStyle: .left,
            resetText: "Resets Friday",
            detailText: nil,
            detailLeftText: nil,
            detailRightText: nil,
            pacePercent: nil,
            paceOnTop: true)
        var configuredErrorModel = Self.model(
            metrics: [metric],
            subtitleText: "Could not refresh usage",
            subtitleStyle: .error)
        configuredErrorModel.usesLiveSubtitle = true
        let errorModel = configuredErrorModel
        let width: CGFloat = 296
        let monitor = MenuCardRefreshMonitor(
            resolveModel: { _ in errorModel },
            isProviderRefreshActive: { _ in true })
        monitor.beginManualRefresh(frozenModels: [.codex: errorModel])
        let refreshSubtitle = OverviewMenuCardRowView.liveSubtitle(
            for: errorModel,
            refreshMonitor: monitor)

        let accessibilitySize = NSHostingController(rootView: OverviewMenuCardRowView(
            model: errorModel,
            storageText: nil,
            width: width)
            .environment(\.dynamicTypeSize, .accessibility5))
            .sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude))

        #expect(refreshSubtitle.text == "Refreshing…")
        #expect(refreshSubtitle.style == .loading)
        #expect(OverviewMenuCardRowView.prioritizesStatus(for: refreshSubtitle.style))
        #expect(OverviewMenuCardRowView.primaryMetric(for: errorModel)?.id == "weekly")
        #expect(accessibilitySize.height >= OverviewMenuCardRowView.accessibilityRowHeight)
        #expect(accessibilitySize.height > OverviewMenuCardRowView.rowHeight)
    }

    @Test
    func `detail card keeps compact divider gap without usage section`() {
        let metricsModel = Self.model(metrics: [
            UsageMenuCardView.Model.Metric(
                id: "session",
                title: "Session",
                percent: 37,
                percentStyle: .left,
                resetText: "Resets in 41m",
                detailText: nil,
                detailLeftText: "24% in reserve",
                detailRightText: "Lasts until reset",
                pacePercent: nil,
                paceOnTop: true),
        ])

        #expect(UsageMenuCardView.dividerBottomPadding(for: metricsModel) ==
            UsageMenuCardLayout.postHeaderDividerContentSpacing)
        #expect(UsageMenuCardView.dividerBottomPadding(for: Self.model(creditsText: "$12.34 remaining")) ==
            UsageMenuCardLayout.sectionBottomPadding)
        #expect(UsageMenuCardView.dividerBottomPadding(for: Self.model(usageNotes: ["Waiting for data"])) ==
            UsageMenuCardLayout.sectionBottomPadding)
        #expect(UsageMenuCardView.dividerBottomPadding(for: Self.model(placeholder: "No usage yet")) ==
            UsageMenuCardLayout.sectionBottomPadding)
    }

    @Test
    func `metric line presentation keeps remaining percent and reset in title row`() {
        let metric = UsageMenuCardView.Model.Metric(
            id: "weekly",
            title: "Weekly",
            percent: 69,
            percentStyle: .left,
            resetText: "Resets Jul 22, 8:33 AM",
            detailText: nil,
            detailLeftText: "26% in deficit",
            detailRightText: "Runs out in 19h 7m (85% risk)",
            pacePercent: 43,
            paceOnTop: true,
            sessionEquivalentDetail: .init(
                leftText: "Est. 2 session quotas left",
                rightText: "6 windows until reset",
                accessibilityLabel: "Est. 2 session quotas left · 6 windows until reset"))

        let presentation = metric.linePresentation(title: metric.title)

        #expect(presentation.titleText == "Weekly 69% left")
        #expect(presentation.resetText == "Resets Jul 22, 8:33 AM")
        #expect(presentation.metaText ==
            "26% in deficit · Runs out in 19h 7m (85% risk) · " +
            "Est. 2 session quotas left · 6 windows until reset")
    }

    @Test
    func `metric title follows configured percent style`() {
        let leftMetric = UsageMenuCardView.Model.Metric(
            id: "weekly",
            title: "Weekly",
            percent: 69,
            percentStyle: .left,
            resetText: nil,
            detailText: nil,
            detailLeftText: nil,
            detailRightText: nil,
            pacePercent: nil,
            paceOnTop: true)
        let usedMetric = UsageMenuCardView.Model.Metric(
            id: "weekly",
            title: "Weekly",
            percent: 31,
            percentStyle: .used,
            resetText: nil,
            detailText: nil,
            detailLeftText: nil,
            detailRightText: nil,
            pacePercent: nil,
            paceOnTop: true)

        #expect(leftMetric.linePresentation(title: leftMetric.title).titleText == "Weekly 69% left")
        #expect(usedMetric.linePresentation(title: usedMetric.title).titleText == "Weekly 31% used")
    }

    @Test
    func `metric detail remains one row as pace content grows`() {
        let width: CGFloat = 296
        func card(
            detailRightText: String,
            forecast: UsagePaceText.SessionEquivalentDetail? = nil) -> UsageMenuCardView
        {
            UsageMenuCardView(model: Self.model(metrics: [
                UsageMenuCardView.Model.Metric(
                    id: "weekly",
                    title: "Weekly",
                    percent: 69,
                    percentStyle: .left,
                    resetText: "Resets Jul 22, 8:33 AM",
                    detailText: nil,
                    detailLeftText: "26% in deficit",
                    detailRightText: detailRightText,
                    pacePercent: 43,
                    paceOnTop: true,
                    sessionEquivalentDetail: forecast),
            ]), width: width)
        }
        let shortHeight = NSHostingController(rootView: card(detailRightText: "Runs out in 19h"))
            .sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude)).height
        let longHeight = NSHostingController(rootView: card(
            detailRightText: "Runs out in 19h 7m (85% risk)",
            forecast: .init(
                leftText: "Est. 2 session quotas left",
                rightText: "6 windows until reset",
                accessibilityLabel: "Est. 2 session quotas left · 6 windows until reset")))
            .sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude)).height

        #expect(abs(shortHeight - longHeight) < Self.heightTolerance)
    }

    private static func model(
        metrics: [UsageMenuCardView.Model.Metric] = [],
        usageNotes: [String] = [],
        creditsText: String? = nil,
        placeholder: String? = nil,
        subtitleText: String = "Not fetched yet",
        subtitleStyle: UsageMenuCardView.Model.SubtitleStyle = .info) -> UsageMenuCardView.Model
    {
        UsageMenuCardView.Model(
            provider: .codex,
            providerName: "Codex",
            email: "steipete@gmail.com",
            subtitleText: subtitleText,
            subtitleStyle: subtitleStyle,
            planText: "Pro 20x",
            metrics: metrics,
            usageNotes: usageNotes,
            openAIAPIUsage: nil,
            inlineUsageDashboard: nil,
            creditsText: creditsText,
            creditsRemaining: nil,
            creditsProgressPercent: nil,
            creditsScaleText: nil,
            creditsHintText: nil,
            creditsHintCopyText: nil,
            providerCost: nil,
            tokenUsage: nil,
            placeholder: placeholder,
            progressColor: .blue)
    }
}
