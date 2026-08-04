import AppKit
import CodexBarCore
import SwiftUI
import Testing
@testable import CodexBar

@MainActor
struct UsageMenuCardLayoutTests {
    private static let heightTolerance: CGFloat = 1

    @Test
    func `detailed overview separates provider header without inner usage dividers`() {
        #expect(OverviewMenuCardRowView.showsHeaderDivider)
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
    func `full provider card matches overview height`() {
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
        ])
        let width: CGFloat = 296

        let fullCardSize = NSHostingController(rootView: UsageMenuCardView(model: model, width: width))
            .sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude))
        let overviewStyleSize = NSHostingController(rootView: UsageMenuCardHeaderAndUsageSectionView(
            model: model,
            layoutModel: model,
            bottomPadding: UsageMenuCardLayout.sectionBottomPadding,
            width: width))
            .sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude))

        #expect(UsageMenuCardLayout.postHeaderDividerContentSpacing == 16)
        #expect(UsageMenuCardLayout.headerOnlyVerticalPadding == 6)
        #expect(UsageMenuCardLayout.sectionTopPadding == 6)
        #expect(UsageMenuCardLayout.sectionBottomPadding == 6)

        #expect(abs(fullCardSize.height - overviewStyleSize.height) < Self.heightTolerance)
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
    func `metric line presentation keeps used percent and reset in title row`() {
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

        #expect(presentation.titleText == "Weekly 31%")
        #expect(presentation.resetText == "Resets Jul 22, 8:33 AM")
        #expect(presentation.metaText ==
            "26% in deficit · Runs out in 19h 7m (85% risk) · " +
            "Est. 2 session quotas left · 6 windows until reset")
    }

    @Test
    func `metric title always reports used percent`() {
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

        #expect(leftMetric.linePresentation(title: leftMetric.title).titleText == "Weekly 31%")
        #expect(usedMetric.linePresentation(title: usedMetric.title).titleText == "Weekly 31%")
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
        placeholder: String? = nil) -> UsageMenuCardView.Model
    {
        UsageMenuCardView.Model(
            provider: .codex,
            providerName: "Codex",
            email: "steipete@gmail.com",
            subtitleText: "Not fetched yet",
            subtitleStyle: .info,
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
