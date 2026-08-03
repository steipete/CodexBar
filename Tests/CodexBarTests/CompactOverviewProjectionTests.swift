import AppKit
import CodexBarCore
import SwiftUI
import Testing
@testable import CodexBar

@MainActor
struct CompactOverviewProjectionTests {
    @Test
    func `projection preserves every drawable lane for variable response sizes`() {
        for count in [0, 1, 2, 3, 6, 12] {
            let metrics = (0..<count).map { index in
                Self.metric(id: "lane-\(index)", title: "Lane \(index)", percent: Double(index))
            }
            let projection = CompactOverviewProjection(
                model: Self.model(metrics: metrics),
                noBarsText: "No bars")

            #expect(projection.lanes.map(\.id) == metrics.map(\.id))
            #expect(projection.lanes.count == count)
            #expect((projection.fallback != nil) == (count == 0))
        }
    }

    @Test
    func `response sized projection retains every lane without a cap`() {
        let metrics = (0..<64).map { index in
            Self.metric(id: "response-lane-\(index)", title: "Lane \(index)", percent: Double(index))
        }
        let projection = CompactOverviewProjection(model: Self.model(metrics: metrics))

        #expect(projection.lanes.map(\.id) == metrics.map(\.id))
        #expect(projection.lanes.count == 64)
    }

    @Test
    func `projection omits text metrics without disturbing drawable order`() {
        let projection = CompactOverviewProjection(model: Self.model(metrics: [
            Self.metric(id: "session", title: "Session", percent: 72),
            Self.metric(id: "balance", title: "Balance", statusText: "$12.40"),
            Self.metric(id: "weekly", title: "Weekly", percent: 31),
        ]))

        #expect(projection.lanes.map(\.id) == ["session", "weekly"])
        #expect(projection.fallback == nil)
    }

    @Test
    func `projection uses the same provider specific metric titles as detailed cards`() {
        let drawable = CompactOverviewProjection(model: Self.model(
            provider: .openrouter,
            metrics: [Self.metric(id: "primary", title: "Credits")]))
        let status = CompactOverviewProjection(model: Self.model(
            provider: .openrouter,
            metrics: [Self.metric(id: "primary", title: "Credits", statusText: "Unavailable")]))

        #expect(drawable.lanes.first?.title == L("API key limit"))
        #expect(status.fallback?.metricTitle == L("API key limit"))
    }

    @Test
    func `loading status and generic fallback precedence is deterministic`() {
        let statusMetrics = [
            Self.metric(id: "empty", title: "Empty", statusText: " \n "),
            Self.metric(id: "credits", title: "Credits", statusText: "  $12.40 remaining\n"),
            Self.metric(id: "later", title: "Later", statusText: "ignored"),
        ]
        let loading = CompactOverviewProjection(
            model: Self.model(subtitleStyle: .loading, metrics: statusMetrics),
            loadingText: "Loading fixture",
            noBarsText: "No bars fixture")
        let status = CompactOverviewProjection(
            model: Self.model(subtitleStyle: .info, metrics: statusMetrics),
            loadingText: "Loading fixture",
            noBarsText: "No bars fixture")
        let generic = CompactOverviewProjection(
            model: Self.model(metrics: [statusMetrics[0]]),
            noBarsText: "No bars fixture")

        guard case let .loading(text) = loading.fallback else {
            Issue.record("Expected loading fallback")
            return
        }
        #expect(text == "Loading fixture")

        guard case let .status(metricID, title, text) = status.fallback else {
            Issue.record("Expected status fallback")
            return
        }
        #expect(metricID == "credits")
        #expect(title == "Credits")
        #expect(text == "$12.40 remaining")
        #expect(status.fallback?.accessibilityLabel == "Credits")
        #expect(status.fallback?.accessibilityValue == "$12.40 remaining")

        guard case let .generic(text) = generic.fallback else {
            Issue.record("Expected generic fallback")
            return
        }
        #expect(text == "No bars fixture")
        #expect(generic.fallback?.accessibilityValue == nil)
    }

    @Test
    func `lane carries bar semantics tint pace and markers unchanged`() throws {
        let tint = Color(red: 0.2, green: 0.4, blue: 0.6)
        let projection = CompactOverviewProjection(model: Self.model(
            providerName: "Full Provider Name",
            metrics: [Self.metric(
                id: "session",
                title: "Full Metric Name",
                percent: 0.4,
                percentStyle: .used,
                pacePercent: 61,
                paceOnTop: false,
                warningMarkerPercents: [25, 75],
                workdayMarkerPercents: [20, 40, 60])],
            progressColor: tint))
        let lane = try #require(projection.lanes.first)

        #expect(projection.providerName == "Full Provider Name")
        #expect(lane.title == "Full Metric Name")
        #expect(lane.percent == 0.4)
        #expect(lane.percentStyle.rawValue == UsageMenuCardView.Model.PercentStyle.used.rawValue)
        #expect(lane.barAccessibilityLabel == L("Usage used"))
        #expect(lane.accessibilitySummary == "Full Metric Name, <1% used")
        #expect(projection.accessibilitySummary == lane.accessibilitySummary)
        #expect(projection.accessibilityLabel == "Full Provider Name. Full Metric Name, <1% used")
        #expect(lane.tint == tint)
        #expect(lane.pacePercent == 61)
        #expect(lane.paceOnTop == false)
        #expect(lane.warningMarkerPercents == [25, 75])
        #expect(lane.workdayMarkerPercents == [20, 40, 60])
    }

    @Test
    func `drawable signature tracks every geometry relevant lane change without raw text`() {
        let original = Self.projection(metrics: [
            Self.metric(id: "private-session-id", title: "Private Session Title"),
            Self.metric(id: "weekly", title: "Weekly"),
        ])
        let idChange = Self.projection(metrics: [
            Self.metric(id: "replacement-id", title: "Private Session Title"),
            Self.metric(id: "weekly", title: "Weekly"),
        ])
        let reordered = Self.projection(metrics: [
            Self.metric(id: "weekly", title: "Weekly"),
            Self.metric(id: "private-session-id", title: "Private Session Title"),
        ])
        let titleChange = Self.projection(metrics: [
            Self.metric(id: "private-session-id", title: "Replacement Title"),
            Self.metric(id: "weekly", title: "Weekly"),
        ])
        let styleChange = Self.projection(metrics: [
            Self.metric(id: "private-session-id", title: "Private Session Title", percentStyle: .used),
            Self.metric(id: "weekly", title: "Weekly"),
        ])
        let removed = Self.projection(metrics: [
            Self.metric(id: "private-session-id", title: "Private Session Title"),
        ])
        let status = Self.projection(metrics: [
            Self.metric(id: "private-session-id", title: "Private Session Title", statusText: "Private value"),
        ])

        #expect(original.layoutSignature != idChange.layoutSignature)
        #expect(original.layoutSignature != reordered.layoutSignature)
        #expect(original.layoutSignature != titleChange.layoutSignature)
        #expect(original.layoutSignature != styleChange.layoutSignature)
        #expect(original.layoutSignature != removed.layoutSignature)
        #expect(original.layoutSignature != status.layoutSignature)
        #expect(!original.layoutSignature.contains("private-session-id"))
        #expect(!original.layoutSignature.contains("Private Session Title"))
        #expect(!original.layoutSignature.contains("Private Provider Name"))
    }

    @Test
    func `fallback signature tracks kind and selected status shape but not status value`() {
        let first = Self.projection(metrics: [
            Self.metric(id: "private-credit-id", title: "Private Credits", statusText: "$12.40"),
        ])
        let valueOnly = Self.projection(metrics: [
            Self.metric(id: "private-credit-id", title: "Private Credits", statusText: "$99.00"),
        ])
        let selectedID = Self.projection(metrics: [
            Self.metric(id: "other-credit-id", title: "Private Credits", statusText: "$12.40"),
        ])
        let selectedTitle = Self.projection(metrics: [
            Self.metric(id: "private-credit-id", title: "Balance", statusText: "$12.40"),
        ])
        let loading = CompactOverviewProjection(
            model: Self.model(subtitleStyle: .loading),
            loadingText: "Loading fixture")
        let generic = CompactOverviewProjection(model: Self.model(), noBarsText: "No bars fixture")

        #expect(first.layoutSignature == valueOnly.layoutSignature)
        #expect(first.layoutSignature != selectedID.layoutSignature)
        #expect(first.layoutSignature != selectedTitle.layoutSignature)
        #expect(first.layoutSignature != loading.layoutSignature)
        #expect(first.layoutSignature != generic.layoutSignature)
        for rawValue in ["private-credit-id", "Private Credits", "$12.40", "Private Provider Name"] {
            #expect(!first.layoutSignature.contains(rawValue))
        }
        #expect(valueOnly.fallback?.text == "$99.00")
    }

    @Test
    func `layout gives every reduced mode stable full width geometry`() {
        let minimum = CompactOverviewLayout.resolveForMenu(
            menuWidth: 310,
            layoutDirection: .leftToRight)
        let wider = CompactOverviewLayout.resolveForMenu(
            menuWidth: 360,
            layoutDirection: .leftToRight)
        let undersized = CompactOverviewLayout.resolveForMenu(
            menuWidth: 200,
            layoutDirection: .leftToRight)

        #expect(minimum.menuWidth == CompactOverviewLayout.minimumMenuWidth)
        #expect(minimum.contentWidth == 270)
        #expect(minimum.labeledBarWidth == minimum.contentWidth)
        #expect(minimum.providerHeaderWidth + CompactOverviewLayout.chevronGutterWidth == minimum.contentWidth)
        #expect(minimum.providerBarsBarWidth == minimum.contentWidth)
        #expect(minimum.barsOnlyBarWidth == minimum.contentWidth)
        #expect(minimum.labeledBarWidth == minimum.providerBarsBarWidth)
        #expect(minimum.labeledBarWidth == minimum.barsOnlyBarWidth)
        #expect(wider.contentWidth == minimum.contentWidth + 50)
        #expect(wider.labeledBarWidth == minimum.labeledBarWidth + 50)
        #expect(wider.providerBarsBarWidth == minimum.providerBarsBarWidth + 50)
        #expect(wider.barsOnlyBarWidth == minimum.barsOnlyBarWidth + 50)
        #expect(undersized.menuWidth == CompactOverviewLayout.minimumMenuWidth)
        #expect(undersized.signature == minimum.signature)
        #expect(CompactOverviewLayout.barHeight == UsageProgressBar.defaultHeight)
        #expect(CompactOverviewLayout.providerBarsLaneSpacing == 12)
        #expect(CompactOverviewLayout.barsOnlyLaneSpacing == 12)
        #expect(CompactOverviewLayout.barsOnlyInterProviderSpacing == 24)
        #expect(CompactOverviewLayout.barsOnlySectionOuterSpacing == 15)
        #expect(CompactOverviewLayout.barsOnlyVerticalPadding == 8.5)
        #expect(CompactOverviewLayout.barsOnlySectionSpacerHeight == 3)
        let interProviderSpacing = MenuCardItemSizing.measuredHeightPadding
            + CompactOverviewLayout.barsOnlyVerticalPadding * 2
        #expect(interProviderSpacing == CompactOverviewLayout.barsOnlyInterProviderSpacing)
        let sectionOuterSpacing = MenuCardItemSizing.measuredHeightPadding / 2
            + CompactOverviewLayout.barsOnlyVerticalPadding
            + CompactOverviewLayout.barsOnlySectionSpacerHeight
        #expect(sectionOuterSpacing == CompactOverviewLayout.barsOnlySectionOuterSpacing)
        #expect(CompactOverviewLayout.labeledMetricSpacing == CompactOverviewLayout.barsOnlyLaneSpacing)
        #expect(minimum.signature.contains("barsOnlySectionSpacer"))
    }

    @Test
    func `layout signature tracks width and direction without provider text`() {
        let leftToRight = CompactOverviewLayout.resolveForMenu(
            menuWidth: 310,
            layoutDirection: .leftToRight)
        let same = CompactOverviewLayout.resolveForMenu(
            menuWidth: 310,
            layoutDirection: .leftToRight)
        let wider = CompactOverviewLayout.resolveForMenu(
            menuWidth: 360,
            layoutDirection: .leftToRight)
        let rightToLeft = CompactOverviewLayout.resolveForMenu(
            menuWidth: 310,
            layoutDirection: .rightToLeft)

        #expect(leftToRight.signature == same.signature)
        #expect(leftToRight.signature != wider.signature)
        #expect(leftToRight.signature != rightToLeft.signature)
        #expect(leftToRight.signature.contains("direction=ltr"))
        #expect(rightToLeft.signature.contains("direction=rtl"))
        #expect(!leftToRight.signature.contains("Private Provider Name"))
        #expect(rightToLeft.layoutDirection == .rightToLeft)
    }

    @Test
    func `selected app language controls compact layout direction`() {
        let english = CodexBarLocalizationOverride.$appLanguage.withValue("en") {
            codexBarUsesRightToLeftLayout()
        }
        let arabic = CodexBarLocalizationOverride.$appLanguage.withValue("ar") {
            codexBarUsesRightToLeftLayout()
        }
        let persian = CodexBarLocalizationOverride.$appLanguage.withValue("fa") {
            codexBarUsesRightToLeftLayout()
        }

        #expect(!english)
        #expect(arabic)
        #expect(persian)
        let leftToRight = CompactOverviewLayout.resolveForMenu(
            menuWidth: 310,
            layoutDirection: .leftToRight)
        let rightToLeft = CompactOverviewLayout.resolveForMenu(
            menuWidth: 310,
            layoutDirection: .rightToLeft)
        #expect(leftToRight.contentWidth == rightToLeft.contentWidth)
        #expect(leftToRight.labeledBarWidth == rightToLeft.labeledBarWidth)
        #expect(leftToRight.providerBarsBarWidth == rightToLeft.providerBarsBarWidth)
        #expect(leftToRight.barsOnlyBarWidth == rightToLeft.barsOnlyBarWidth)
        #expect(MenuCardSectionContainerView<EmptyView>.submenuIndicatorSystemName(for: .leftToRight) ==
            "chevron.right")
        #expect(MenuCardSectionContainerView<EmptyView>.submenuIndicatorSystemName(for: .rightToLeft) ==
            "chevron.left")
    }

    @Test
    func `live resolver mirrors gate accepts compatible frozen shape and rejects drift`() {
        let fallback = Self.model(
            usesLiveSubtitle: true,
            metrics: [Self.metric(id: "fallback", title: "Fallback", percent: 10)])
        let frozenLayout = Self.model(
            usesLiveSubtitle: true,
            metrics: [
                Self.metric(id: "one", title: "One", percent: 11),
                Self.metric(id: "two", title: "Two", percent: 22),
                Self.metric(id: "three", title: "Three", percent: 33),
            ])
        let compatibleLive = Self.model(
            usesLiveSubtitle: true,
            metrics: [
                Self.metric(id: "one", title: "One", percent: 44),
                Self.metric(id: "two", title: "Two", percent: 55),
                Self.metric(id: "three", title: "Three", percent: 66),
            ])
        var resolutionCount = 0
        let compatible = CompactOverviewProjectionResolver.resolve(
            fallbackModel: fallback,
            layoutModel: frozenLayout)
        {
            resolutionCount += 1
            return compatibleLive
        }

        #expect(resolutionCount == 1)
        #expect(compatible.lanes.map(\.id) == ["one", "two", "three"])
        #expect(compatible.lanes.map(\.percent) == [44, 55, 66])

        let incompatible = CompactOverviewProjectionResolver.resolve(
            fallbackModel: fallback,
            layoutModel: frozenLayout)
        {
            Self.model(
                usesLiveSubtitle: true,
                metrics: [Self.metric(id: "one", title: "One", percent: 99)])
        }
        #expect(incompatible.lanes.map(\.id) == ["one", "two", "three"])
        #expect(incompatible.lanes.map(\.percent) == [11, 22, 33])

        var gatedResolutionCount = 0
        let gated = CompactOverviewProjectionResolver.resolve(
            fallbackModel: Self.model(metrics: [Self.metric(id: "static", title: "Static")]),
            layoutModel: nil)
        {
            gatedResolutionCount += 1
            return compatibleLive
        }
        #expect(gatedResolutionCount == 0)
        #expect(gated.lanes.map(\.id) == ["static"])

        var wrongProviderResolutionCount = 0
        let wrongProviderLayout = CompactOverviewProjectionResolver.resolve(
            fallbackModel: fallback,
            layoutModel: Self.model(
                provider: .claude,
                usesLiveSubtitle: true,
                metrics: [Self.metric(id: "foreign", title: "Foreign")]))
        {
            wrongProviderResolutionCount += 1
            return compatibleLive
        }
        #expect(wrongProviderResolutionCount == 0)
        #expect(wrongProviderLayout.lanes.map(\.id) == ["fallback"])
    }

    @Test
    func `compact interaction policy never exposes detailed embedded controls`() {
        let live = Self.model(usesLiveSubtitle: true)
        let error = Self.model(subtitleStyle: .error)

        #expect(OverviewMenuRowInteractionPolicy.containsInteractiveControls(style: .detailed, model: live))
        #expect(OverviewMenuRowInteractionPolicy.containsInteractiveControls(style: .detailed, model: error))
        #expect(!OverviewMenuRowInteractionPolicy.containsInteractiveControls(style: .compact, model: live))
        #expect(!OverviewMenuRowInteractionPolicy.containsInteractiveControls(style: .compact, model: error))
        #expect(!OverviewMenuRowInteractionPolicy.containsInteractiveControls(style: .providerBars, model: live))
        #expect(!OverviewMenuRowInteractionPolicy.containsInteractiveControls(style: .providerBars, model: error))
        #expect(!OverviewMenuRowInteractionPolicy.containsInteractiveControls(style: .barsOnly, model: live))
        #expect(!OverviewMenuRowInteractionPolicy.containsInteractiveControls(style: .barsOnly, model: error))
    }

    @Test
    func `hosted reduced rows preserve every lane in increasing detail order`() throws {
        let layout = CompactOverviewLayout.resolveForMenu(
            menuWidth: 310,
            layoutDirection: .leftToRight)
        var labeledHeights: [Int: CGFloat] = [:]
        var providerBarsHeights: [Int: CGFloat] = [:]
        var barsOnlyHeights: [Int: CGFloat] = [:]
        for count in [0, 1, 2, 3, 6] {
            let metrics = (0..<count).map { Self.metric(id: "lane-\($0)", title: "Lane \($0)") }
            let projection = CompactOverviewProjection(
                model: Self.model(metrics: metrics),
                noBarsText: "No bars")
            let labeledHost = NSHostingController(rootView: CompactOverviewLabeledContent(
                projection: projection,
                layout: layout))
            let providerBarsHost = NSHostingController(rootView: CompactOverviewProviderBarsContent(
                projection: projection,
                layout: layout))
            let barsOnlyHost = NSHostingController(rootView: CompactOverviewBarsOnlyContent(
                projection: projection,
                layout: layout))
            labeledHeights[count] = labeledHost.sizeThatFits(in: CGSize(
                width: layout.menuWidth,
                height: 10000)).height
            providerBarsHeights[count] = providerBarsHost.sizeThatFits(in: CGSize(
                width: layout.menuWidth,
                height: 10000)).height
            barsOnlyHeights[count] = barsOnlyHost.sizeThatFits(in: CGSize(
                width: layout.menuWidth,
                height: 10000)).height
        }

        let fallbackLabeledHeight = try #require(labeledHeights[0])
        let fallbackProviderBarsHeight = try #require(providerBarsHeights[0])
        let fallbackBarsOnlyHeight = try #require(barsOnlyHeights[0])
        #expect(fallbackLabeledHeight > 0)
        #expect(fallbackBarsOnlyHeight > 0)
        #expect(fallbackBarsOnlyHeight < fallbackProviderBarsHeight)
        #expect(fallbackProviderBarsHeight < fallbackLabeledHeight)

        for count in [1, 2, 3, 6] {
            let labeledHeight = try #require(labeledHeights[count])
            let providerBarsHeight = try #require(providerBarsHeights[count])
            let barsOnlyHeight = try #require(barsOnlyHeights[count])
            #expect(barsOnlyHeight < providerBarsHeight)
            #expect(providerBarsHeight < labeledHeight)
        }

        for (count, target) in [(1, 23.0), (2, 41.0), (3, 59.0)] {
            let barsOnlyHeight = try #require(barsOnlyHeights[count])
            #expect(abs(barsOnlyHeight - target) <= 1)
        }

        for pair in zip([1, 2, 3], [2, 3, 6]) {
            let labeledBefore = try #require(labeledHeights[pair.0])
            let labeledAfter = try #require(labeledHeights[pair.1])
            let providerBarsBefore = try #require(providerBarsHeights[pair.0])
            let providerBarsAfter = try #require(providerBarsHeights[pair.1])
            let barsOnlyBefore = try #require(barsOnlyHeights[pair.0])
            let barsOnlyAfter = try #require(barsOnlyHeights[pair.1])
            #expect(labeledBefore < labeledAfter)
            #expect(providerBarsBefore < providerBarsAfter)
            #expect(barsOnlyBefore < barsOnlyAfter)
            #expect(abs((providerBarsAfter - providerBarsBefore) - CGFloat(pair.1 - pair.0) * 18) <= 1)
        }

        let oneLaneBarsOnlyHeight = try #require(barsOnlyHeights[1])
        let oneLaneProviderBarsHeight = try #require(providerBarsHeights[1])
        #expect(abs(fallbackBarsOnlyHeight - oneLaneBarsOnlyHeight) <= 1)
        #expect(abs(fallbackProviderBarsHeight - oneLaneProviderBarsHeight) <= 1)
    }

    @Test
    func `bars only rows keep symmetric padding independent of section position`() {
        let layout = CompactOverviewLayout.resolveForMenu(
            menuWidth: 310,
            layoutDirection: .leftToRight)
        let projection = CompactOverviewProjection(model: Self.model(metrics: [
            Self.metric(id: "lane", title: "Lane"),
        ]))

        let host = NSHostingController(rootView: CompactOverviewBarsOnlyContent(
            projection: projection,
            layout: layout))
        let height = host.sizeThatFits(in: CGSize(width: layout.menuWidth, height: 10000)).height

        #expect(abs(height - 23) <= 1)
        #expect(CompactOverviewLayout.barsOnlySectionSpacerHeight == 3)
    }

    private static func projection(
        providerName: String = "Private Provider Name",
        metrics: [UsageMenuCardView.Model.Metric]) -> CompactOverviewProjection
    {
        CompactOverviewProjection(
            model: self.model(providerName: providerName, metrics: metrics),
            loadingText: "Loading fixture",
            noBarsText: "No bars fixture")
    }

    private static func metric(
        id: String,
        title: String,
        percent: Double = 50,
        percentStyle: UsageMenuCardView.Model.PercentStyle = .left,
        statusText: String? = nil,
        pacePercent: Double? = nil,
        paceOnTop: Bool = true,
        warningMarkerPercents: [Double] = [],
        workdayMarkerPercents: [Double] = []) -> UsageMenuCardView.Model.Metric
    {
        UsageMenuCardView.Model.Metric(
            id: id,
            title: title,
            percent: percent,
            percentStyle: percentStyle,
            statusText: statusText,
            resetText: "Detailed reset sentinel",
            detailText: "Detailed text sentinel",
            detailLeftText: "Detailed left sentinel",
            detailRightText: "Detailed right sentinel",
            pacePercent: pacePercent,
            paceOnTop: paceOnTop,
            warningMarkerPercents: warningMarkerPercents,
            workdayMarkerPercents: workdayMarkerPercents)
    }

    private static func model(
        provider: UsageProvider = .codex,
        providerName: String = "Provider",
        subtitleStyle: UsageMenuCardView.Model.SubtitleStyle = .info,
        usesLiveSubtitle: Bool = false,
        metrics: [UsageMenuCardView.Model.Metric] = [],
        progressColor: Color = .blue) -> UsageMenuCardView.Model
    {
        UsageMenuCardView.Model(
            provider: provider,
            providerName: providerName,
            email: "Private email sentinel",
            subtitleText: "Detailed subtitle sentinel",
            subtitleStyle: subtitleStyle,
            usesLiveSubtitle: usesLiveSubtitle,
            planText: "Detailed plan sentinel",
            metrics: metrics,
            usageNotes: ["Detailed note sentinel"],
            openAIAPIUsage: nil,
            inlineUsageDashboard: nil,
            creditsText: "Detailed credits sentinel",
            creditsRemaining: 12,
            creditsProgressPercent: 34,
            creditsScaleText: "Detailed scale sentinel",
            creditsHintText: "Detailed credits hint sentinel",
            creditsHintCopyText: "Detailed copy sentinel",
            providerCost: nil,
            tokenUsage: nil,
            placeholder: "Detailed placeholder sentinel",
            progressColor: progressColor)
    }
}
