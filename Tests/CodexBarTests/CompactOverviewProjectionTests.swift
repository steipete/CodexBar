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
        #expect(lane.accessibilityLabel == L("Usage used"))
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
    func `allocator gives the 310 point budget to a wide bar and full provider header`() throws {
        let minimum = try CompactOverviewColumnLayout.allocate(.init(
            menuWidth: 310,
            idealMetricWidth: 112,
            fontSignature: "fixture-font",
            layoutDirection: .leftToRight))
        let wider = try CompactOverviewColumnLayout.allocate(.init(
            menuWidth: 360,
            idealMetricWidth: 112,
            fontSignature: "fixture-font",
            layoutDirection: .leftToRight))

        #expect(minimum.menuWidth == 310)
        #expect(minimum.metricWidth == 112)
        #expect(minimum.barWidth == 146)
        #expect(minimum.barWidth == CompactOverviewColumnLayout.minimumBarWidth)
        #expect(minimum.contentWidth == 270)
        #expect(minimum.providerHeaderWidth == 258)
        #expect(minimum.occupiedWidth == 310)
        #expect(wider.metricWidth == minimum.metricWidth)
        #expect(wider.barWidth == minimum.barWidth + 50)
        #expect(wider.occupiedWidth == 360)
        #expect(CompactOverviewColumnLayout.barHeight == 8)
        #expect(CompactOverviewColumnLayout.providerContentSpacing == 4)
        #expect(CompactOverviewColumnLayout.laneSpacing == 3)
    }

    @Test
    func `allocator rejects unsupported width caps long labels and reclaims short label space`() throws {
        do {
            _ = try CompactOverviewColumnLayout.allocate(.init(
                menuWidth: 309,
                idealMetricWidth: 112,
                fontSignature: "fixture-font",
                layoutDirection: .leftToRight))
            Issue.record("Expected minimum-width rejection")
        } catch let error as CompactOverviewColumnLayoutError {
            #expect(error == .menuWidthBelowMinimum(309))
        }

        let capped = try CompactOverviewColumnLayout.allocate(.init(
            menuWidth: 310,
            idealMetricWidth: 500,
            fontSignature: "fixture-font",
            layoutDirection: .leftToRight))
        #expect(capped.metricWidth == 112)
        #expect(capped.barWidth == 146)

        let short = try CompactOverviewColumnLayout.allocate(.init(
            menuWidth: 310,
            idealMetricWidth: 48,
            fontSignature: "fixture-font",
            layoutDirection: .leftToRight))
        #expect(short.metricWidth == 48)
        #expect(short.barWidth == 210)
        #expect(short.occupiedWidth == 310)
    }

    @Test
    func `resolver measures only selected metric titles without caching source text`() throws {
        var measured: [(String, CompactOverviewTextWidthMeasurer.Role)] = []
        let measurer = CompactOverviewTextWidthMeasurer(fontSignature: "fixture-font") { text, role in
            measured.append((text, role))
            return switch role {
            case .provider: 80
            case .metric: 140
            }
        }
        let statusProjection = Self.projection(
            providerName: "Private Status Provider",
            metrics: [Self.metric(
                id: "balance",
                title: "Balance Title",
                statusText: "Private status value")])
        let laneProjection = Self.projection(
            providerName: "Private Bar Provider",
            metrics: [Self.metric(id: "session", title: "Session Title")])
        let layout = try CompactOverviewColumnLayout.resolve(
            menuWidth: 310,
            projections: [statusProjection, laneProjection],
            layoutDirection: .rightToLeft,
            textWidthMeasurer: measurer)
        let measuredTexts = measured.map(\.0)

        #expect(!measuredTexts.contains("Private Status Provider"))
        #expect(!measuredTexts.contains("Private Bar Provider"))
        #expect(measuredTexts.contains("Balance Title"))
        #expect(measuredTexts.contains("Session Title"))
        #expect(!measuredTexts.contains("Private status value"))
        #expect(measured.allSatisfy { $0.1 == .metric })
        #expect(layout.metricWidth == 112)
        #expect(layout.barWidth == 146)
        for rawValue in ["Private Status Provider", "Balance Title", "Private Bar Provider", "Session Title"] {
            #expect(!layout.signature.contains(rawValue))
        }
        #expect(layout.signature.contains("direction=rtl"))
        #expect(layout.layoutDirection == .rightToLeft)
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
    }

    @Test
    func `hosted row height includes a provider header and follows every lane`() throws {
        let layout = try CompactOverviewColumnLayout.allocate(.init(
            menuWidth: 310,
            idealMetricWidth: 112,
            fontSignature: "fixture-font",
            layoutDirection: .leftToRight))
        var heights: [Int: CGFloat] = [:]
        for count in [0, 1, 2, 3, 6, 12] {
            let metrics = (0..<count).map { Self.metric(id: "lane-\($0)", title: "Lane \($0)") }
            let projection = CompactOverviewProjection(
                model: Self.model(metrics: metrics),
                noBarsText: "No bars")
            let host = NSHostingController(rootView: CompactOverviewRowContent(
                projection: projection,
                columns: layout))
            heights[count] = host.sizeThatFits(in: CGSize(
                width: layout.menuWidth,
                height: 10000)).height
        }

        let fallbackHeight = try #require(heights[0])
        let oneLaneHeight = try #require(heights[1])
        let twoLaneHeight = try #require(heights[2])
        let threeLaneHeight = try #require(heights[3])
        let sixLaneHeight = try #require(heights[6])
        let twelveLaneHeight = try #require(heights[12])
        #expect(abs(fallbackHeight - oneLaneHeight) <= 1)
        #expect(oneLaneHeight >= 40)
        #expect(oneLaneHeight < twoLaneHeight)
        #expect(twoLaneHeight < threeLaneHeight)
        #expect(threeLaneHeight < sixLaneHeight)
        #expect(sixLaneHeight < twelveLaneHeight)
        #expect(twoLaneHeight <= 66)
        #expect(twoLaneHeight + 7 <= 73)
        #expect(abs((twoLaneHeight - oneLaneHeight) - (threeLaneHeight - twoLaneHeight)) <= 1)

        let canonicalAttachedHeight = 2 * (oneLaneHeight + 7)
            + 2 * (twoLaneHeight + 7)
            + 2 * (threeLaneHeight + 7)
        #expect(canonicalAttachedHeight <= 432)
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
