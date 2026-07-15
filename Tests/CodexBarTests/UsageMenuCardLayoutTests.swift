import AppKit
import CodexBarCore
import SwiftUI
import Testing
@testable import CodexBar

@MainActor
struct UsageMenuCardLayoutTests {
    private static let heightTolerance: CGFloat = 1

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
    func `metric detail uses one row when it fits and at most two when it does not`() {
        let width: CGFloat = 296
        func metricModel(detailLeftText: String, detailRightText: String) -> UsageMenuCardView.Model {
            Self.model(metrics: [
                UsageMenuCardView.Model.Metric(
                    id: "session",
                    title: "Session",
                    percent: 37,
                    percentStyle: .left,
                    resetText: "Resets in 41m",
                    detailText: nil,
                    detailLeftText: detailLeftText,
                    detailRightText: detailRightText,
                    pacePercent: nil,
                    paceOnTop: true),
            ])
        }
        let shortModel = metricModel(detailLeftText: "5% ahead", detailRightText: "Done in 1d")
        let longModel = metricModel(
            detailLeftText: "5% more than current pace",
            detailRightText: "Done in 1d 36m · about 75% likely to finish")
        let veryLongModel = metricModel(
            detailLeftText: "5% more than the current projected pace with additional context",
            detailRightText: "Done in 1d 36m · about 75% likely to finish before the weekly reset window")

        let shortHeight = NSHostingController(rootView: UsageMenuCardView(model: shortModel, width: width))
            .sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude)).height
        let longHeight = NSHostingController(rootView: UsageMenuCardView(model: longModel, width: width))
            .sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude)).height
        let veryLongHeight = NSHostingController(rootView: UsageMenuCardView(model: veryLongModel, width: width))
            .sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude)).height

        #expect(longHeight > shortHeight)
        #expect(abs(veryLongHeight - longHeight) < Self.heightTolerance)
    }

    @Test
    func `tracked metric layout rejects adaptive detail text changes`() {
        func metricModel(detailLeftText: String, detailRightText: String) -> UsageMenuCardView.Model {
            Self.model(metrics: [
                UsageMenuCardView.Model.Metric(
                    id: "session",
                    title: "Session",
                    percent: 37,
                    percentStyle: .left,
                    resetText: "Resets in 41m",
                    detailText: nil,
                    detailLeftText: detailLeftText,
                    detailRightText: detailRightText,
                    pacePercent: nil,
                    paceOnTop: true),
            ])
        }
        let shortModel = metricModel(detailLeftText: "5% ahead", detailRightText: "Done in 1d")
        let longModel = metricModel(
            detailLeftText: "5% more than current pace",
            detailRightText: "Done in 1d 36m · about 75% likely to finish")

        #expect(!shortModel.hasCompatibleTrackedLayout(with: longModel))
    }

    @Test
    func `metric detail with risk stays at most two rows regardless of secondary length`() {
        let width: CGFloat = 296
        func metricModel(detailRightSecondaryText: String) -> UsageMenuCardView.Model {
            Self.model(metrics: [
                UsageMenuCardView.Model.Metric(
                    id: "session",
                    title: "Session",
                    percent: 37,
                    percentStyle: .left,
                    resetText: "Resets in 41m",
                    detailText: nil,
                    detailLeftText: "5% ahead",
                    detailRightText: "Runs out in 2d",
                    detailRightSecondaryText: detailRightSecondaryText,
                    pacePercent: nil,
                    paceOnTop: true),
            ])
        }
        let shortRiskModel = metricModel(detailRightSecondaryText: "≈ 45% run-out risk")
        let longRiskModel = metricModel(
            detailRightSecondaryText: "≈ 45% run-out risk with a lot of additional descriptive context appended")

        let shortRiskHeight = NSHostingController(rootView: UsageMenuCardView(model: shortRiskModel, width: width))
            .sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude)).height
        let longRiskHeight = NSHostingController(rootView: UsageMenuCardView(model: longRiskModel, width: width))
            .sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude)).height

        #expect(abs(longRiskHeight - shortRiskHeight) < Self.heightTolerance)
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
