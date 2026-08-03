import CodexBarCore
import SwiftUI

struct CompactOverviewProjection {
    struct Lane: Identifiable {
        let id: String
        let title: String
        let percent: Double
        let percentStyle: UsageMenuCardView.Model.PercentStyle
        let tint: Color
        let pacePercent: Double?
        let paceOnTop: Bool
        let warningMarkerPercents: [Double]
        let workdayMarkerPercents: [Double]

        var barAccessibilityLabel: String {
            self.percentStyle.accessibilityLabel
        }

        var accessibilitySummary: String {
            "\(self.title), \(UsageFormatter.percentText(self.percent, suffix: self.percentStyle.labelSuffix))"
        }
    }

    enum Fallback {
        case loading(text: String)
        case status(metricID: String, title: String, text: String)
        case generic(text: String)

        var text: String {
            switch self {
            case let .loading(text), let .generic(text): text
            case let .status(_, _, text): text
            }
        }

        var metricTitle: String? {
            guard case let .status(_, title, _) = self else { return nil }
            return title
        }

        var accessibilityLabel: String {
            self.metricTitle ?? self.text
        }

        var accessibilityValue: String? {
            guard case let .status(_, _, text) = self else { return nil }
            return text
        }

        var accessibilitySummary: String {
            switch self {
            case let .status(_, title, text): "\(title): \(text)"
            case let .loading(text), let .generic(text): text
            }
        }

        fileprivate var layoutSignature: String {
            switch self {
            case .loading:
                "fallback:loading"
            case let .status(metricID, title, _):
                Self.joinSignature([
                    "fallback:status",
                    UsageMenuCardView.Model.heightFingerprintField("id", metricID),
                    UsageMenuCardView.Model.heightFingerprintField("title", title),
                ])
            case .generic:
                "fallback:generic"
            }
        }

        private static func joinSignature(_ fields: [String]) -> String {
            fields.map { "\($0.utf8.count):\($0)" }.joined(separator: "|")
        }
    }

    let providerName: String
    let lanes: [Lane]
    let fallback: Fallback?
    let layoutSignature: String

    var accessibilitySummary: String {
        if !self.lanes.isEmpty {
            return self.lanes.map(\.accessibilitySummary).joined(separator: ". ")
        }
        return self.fallback?.accessibilitySummary ?? ""
    }

    var accessibilityLabel: String {
        let summary = self.accessibilitySummary
        return summary.isEmpty ? self.providerName : "\(self.providerName). \(summary)"
    }

    init(
        model: UsageMenuCardView.Model,
        loadingText: String = L("Loading…"),
        noBarsText: String = L("overview_compact_no_bars"))
    {
        let disclosesDoubaoPlanFamily = model.provider == .doubao
            && model.metrics.contains { $0.id.hasPrefix("doubao-agent-") }
        self.providerName = model.providerName
        self.lanes = model.metrics.compactMap { metric in
            guard metric.statusText == nil else { return nil }
            return Lane(
                id: metric.id,
                title: Self.metricTitle(
                    provider: model.provider,
                    metric: metric,
                    disclosesDoubaoPlanFamily: disclosesDoubaoPlanFamily),
                percent: metric.percent,
                percentStyle: metric.percentStyle,
                tint: model.progressColor,
                pacePercent: metric.pacePercent,
                paceOnTop: metric.paceOnTop,
                warningMarkerPercents: metric.warningMarkerPercents,
                workdayMarkerPercents: metric.workdayMarkerPercents)
        }

        if self.lanes.isEmpty {
            self.fallback = Self.makeFallback(
                model: model,
                loadingText: loadingText,
                noBarsText: noBarsText,
                disclosesDoubaoPlanFamily: disclosesDoubaoPlanFamily)
        } else {
            self.fallback = nil
        }
        self.layoutSignature = Self.makeLayoutSignature(lanes: self.lanes, fallback: self.fallback)
    }

    private static func makeFallback(
        model: UsageMenuCardView.Model,
        loadingText: String,
        noBarsText: String,
        disclosesDoubaoPlanFamily: Bool) -> Fallback
    {
        if case .loading = model.subtitleStyle {
            return .loading(text: loadingText)
        }

        for metric in model.metrics {
            guard let statusText = metric.statusText?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                !statusText.isEmpty
            else { continue }
            return .status(
                metricID: metric.id,
                title: Self.metricTitle(
                    provider: model.provider,
                    metric: metric,
                    disclosesDoubaoPlanFamily: disclosesDoubaoPlanFamily),
                text: statusText)
        }
        return .generic(text: noBarsText)
    }

    private static func metricTitle(
        provider: UsageProvider,
        metric: UsageMenuCardView.Model.Metric,
        disclosesDoubaoPlanFamily: Bool) -> String
    {
        let title = UsageMenuCardView.popupMetricTitle(provider: provider, metric: metric)
        guard disclosesDoubaoPlanFamily else { return title }
        let planTitle = metric.id.hasPrefix("doubao-agent-") ? L("Agent Plan") : L("Coding Plan")
        return "\(planTitle) — \(title)"
    }

    private static func makeLayoutSignature(lanes: [Lane], fallback: Fallback?) -> String {
        guard !lanes.isEmpty else {
            return fallback?.layoutSignature ?? "fallback:generic"
        }
        let fields = lanes.flatMap { lane in
            [
                UsageMenuCardView.Model.heightFingerprintField("id", lane.id),
                UsageMenuCardView.Model.heightFingerprintField("title", lane.title),
                "percentStyle=\(lane.percentStyle.rawValue)",
            ]
        }
        return Self.joinSignature(["drawable:count=\(lanes.count)"] + fields)
    }

    func heightFingerprint(section: String, layoutSignature: String) -> String {
        Self.joinSignature([
            "section=\(section)",
            "projection=\(self.layoutSignature)",
            "layout=\(layoutSignature)",
        ])
    }

    private static func joinSignature(_ fields: [String]) -> String {
        fields.map { "\($0.utf8.count):\($0)" }.joined(separator: "|")
    }
}

struct CompactOverviewLayout {
    static let minimumMenuWidth: CGFloat = 310
    static let horizontalPadding: CGFloat = UsageMenuCardLayout.horizontalPadding
    static let chevronGutterWidth: CGFloat = 20
    static let barHeight = UsageProgressBar.defaultHeight
    static let labeledHeaderVerticalPadding: CGFloat = UsageMenuCardLayout.headerOnlyVerticalPadding
    static let labeledUsageTopPadding: CGFloat = UsageMenuCardLayout.usageSectionTopPadding
    static let labeledBottomPadding: CGFloat = UsageMenuCardLayout.sectionBottomPadding
    static let labeledMetricSpacing: CGFloat = UsageMenuCardLayout.metricSpacing
    static let labeledMetricContentSpacing: CGFloat = 6
    static let providerBarsLaneSpacing: CGFloat = UsageMenuCardLayout.metricSpacing
    static let barsOnlyLaneSpacing: CGFloat = UsageMenuCardLayout.metricSpacing
    static let barsOnlyInterProviderSpacing: CGFloat = 24
    static let barsOnlySectionOuterSpacing: CGFloat = 15
    static var barsOnlyVerticalPadding: CGFloat {
        (self.barsOnlyInterProviderSpacing - MenuCardItemSizing.measuredHeightPadding) / 2
    }

    static var barsOnlySectionSpacerHeight: CGFloat {
        self.barsOnlySectionOuterSpacing
            - MenuCardItemSizing.measuredHeightPadding / 2
            - self.barsOnlyVerticalPadding
    }

    let menuWidth: CGFloat
    let layoutDirection: LayoutDirection
    let signature: String

    var contentWidth: CGFloat {
        self.menuWidth - Self.horizontalPadding * 2
    }

    var labeledBarWidth: CGFloat {
        self.contentWidth
    }

    var providerHeaderWidth: CGFloat {
        self.contentWidth - Self.chevronGutterWidth
    }

    var providerBarsBarWidth: CGFloat {
        self.contentWidth
    }

    var barsOnlyBarWidth: CGFloat {
        self.contentWidth
    }

    static func resolveForMenu(
        menuWidth: CGFloat,
        layoutDirection: LayoutDirection) -> Self
    {
        let resolvedMenuWidth = max(menuWidth, self.minimumMenuWidth)
        let direction = switch layoutDirection {
        case .leftToRight: "ltr"
        case .rightToLeft: "rtl"
        @unknown default: "unknown"
        }
        let signature = Self.signature(fields: [
            "menu=\(Self.geometryToken(resolvedMenuWidth))",
            "gutter=\(Self.geometryToken(Self.chevronGutterWidth))",
            "padding=\(Self.geometryToken(Self.horizontalPadding))",
            "barHeight=\(Self.geometryToken(Self.barHeight))",
            "labeledHeaderPadding=\(Self.geometryToken(Self.labeledHeaderVerticalPadding))",
            "labeledUsageTop=\(Self.geometryToken(Self.labeledUsageTopPadding))",
            "labeledBottom=\(Self.geometryToken(Self.labeledBottomPadding))",
            "labeledMetricSpacing=\(Self.geometryToken(Self.labeledMetricSpacing))",
            "labeledContentSpacing=\(Self.geometryToken(Self.labeledMetricContentSpacing))",
            "providerBarsSpacing=\(Self.geometryToken(Self.providerBarsLaneSpacing))",
            "barsOnlyPadding=\(Self.geometryToken(Self.barsOnlyVerticalPadding))",
            "barsOnlySpacing=\(Self.geometryToken(Self.barsOnlyLaneSpacing))",
            "barsOnlyInterProvider=\(Self.geometryToken(Self.barsOnlyInterProviderSpacing))",
            "barsOnlySectionOuter=\(Self.geometryToken(Self.barsOnlySectionOuterSpacing))",
            "barsOnlySectionSpacer=\(Self.geometryToken(Self.barsOnlySectionSpacerHeight))",
            "direction=\(direction)",
        ])
        return Self(
            menuWidth: resolvedMenuWidth,
            layoutDirection: layoutDirection,
            signature: signature)
    }

    private static func geometryToken(_ value: CGFloat) -> Int {
        Int((value * 100).rounded())
    }

    private static func signature(fields: [String]) -> String {
        fields.map { "\($0.utf8.count):\($0)" }.joined(separator: "|")
    }
}

struct CompactOverviewLabeledContent: View {
    let projection: CompactOverviewProjection
    let layout: CompactOverviewLayout

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            CompactOverviewProviderHeader(projection: self.projection, layout: self.layout)

            self.content
        }
        .frame(width: self.layout.menuWidth, alignment: .leading)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var content: some View {
        if self.projection.lanes.isEmpty, let fallback = self.projection.fallback {
            CompactOverviewLabeledFallback(fallback: fallback, layout: self.layout)
        } else {
            VStack(alignment: .leading, spacing: CompactOverviewLayout.labeledMetricSpacing) {
                ForEach(self.projection.lanes) { lane in
                    CompactOverviewLabeledMetric(lane: lane, layout: self.layout)
                }
            }
            .padding(.horizontal, CompactOverviewLayout.horizontalPadding)
            .padding(.top, CompactOverviewLayout.labeledUsageTopPadding)
            .padding(.bottom, CompactOverviewLayout.labeledBottomPadding)
            .accessibilityElement(children: .contain)
        }
    }
}

private struct CompactOverviewProviderHeader: View {
    let projection: CompactOverviewProjection
    let layout: CompactOverviewLayout

    var body: some View {
        HStack(spacing: 0) {
            Text(self.projection.providerName)
                .usageMenuCardProviderTitleStyle()
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: self.layout.providerHeaderWidth, alignment: .leading)
                .help(self.projection.providerName)
                .accessibilityHidden(true)

            Color.clear
                .frame(width: CompactOverviewLayout.chevronGutterWidth, height: 0)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, CompactOverviewLayout.horizontalPadding)
        .padding(.vertical, CompactOverviewLayout.labeledHeaderVerticalPadding)
    }
}

private struct CompactOverviewLabeledMetric: View {
    let lane: CompactOverviewProjection.Lane
    let layout: CompactOverviewLayout

    var body: some View {
        VStack(alignment: .leading, spacing: CompactOverviewLayout.labeledMetricContentSpacing) {
            Text(self.lane.title)
                .usageMenuCardMetricTitleStyle()
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: self.layout.contentWidth, alignment: .leading)
                .help(self.lane.title)
                .accessibilityHidden(true)

            UsageProgressBar(
                percent: self.lane.percent,
                tint: self.lane.tint,
                accessibilityLabel: self.lane.barAccessibilityLabel,
                pacePercent: self.lane.pacePercent,
                paceOnTop: self.lane.paceOnTop,
                warningMarkerPercents: self.lane.warningMarkerPercents,
                workdayMarkerPercents: self.lane.workdayMarkerPercents,
                height: CompactOverviewLayout.barHeight)
                .frame(width: self.layout.labeledBarWidth)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(self.lane.title)
    }
}

struct CompactOverviewProviderBarsContent: View {
    let projection: CompactOverviewProjection
    let layout: CompactOverviewLayout

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            CompactOverviewProviderHeader(projection: self.projection, layout: self.layout)

            self.content
        }
        .frame(width: self.layout.menuWidth, alignment: .leading)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var content: some View {
        if self.projection.lanes.isEmpty, let fallback = self.projection.fallback {
            CompactOverviewUnavailableRail(
                fallback: fallback,
                barWidth: self.layout.providerBarsBarWidth)
                .padding(.horizontal, CompactOverviewLayout.horizontalPadding)
                .padding(.top, CompactOverviewLayout.labeledUsageTopPadding)
                .padding(.bottom, CompactOverviewLayout.labeledBottomPadding)
        } else {
            VStack(alignment: .leading, spacing: CompactOverviewLayout.providerBarsLaneSpacing) {
                ForEach(self.projection.lanes) { lane in
                    CompactOverviewBareBarLane(
                        lane: lane,
                        barWidth: self.layout.providerBarsBarWidth)
                }
            }
            .padding(.horizontal, CompactOverviewLayout.horizontalPadding)
            .padding(.top, CompactOverviewLayout.labeledUsageTopPadding)
            .padding(.bottom, CompactOverviewLayout.labeledBottomPadding)
            .accessibilityElement(children: .contain)
        }
    }
}

private struct CompactOverviewLabeledFallback: View {
    let fallback: CompactOverviewProjection.Fallback
    let layout: CompactOverviewLayout
    @Environment(\.menuItemHighlighted) private var isHighlighted

    var body: some View {
        Group {
            switch self.fallback {
            case let .status(_, title, text):
                VStack(alignment: .leading, spacing: CompactOverviewLayout.labeledMetricContentSpacing) {
                    Text(title)
                        .font(.body)
                        .fontWeight(.medium)
                        .foregroundStyle(MenuHighlightStyle.primary(self.isHighlighted))
                        .lineLimit(1)
                        .help(title)
                        .accessibilityHidden(true)
                    self.fallbackText(text, font: .footnote)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(title)
                .accessibilityValue(text)
            case let .loading(text), let .generic(text):
                self.fallbackText(text, font: .body)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(text)
            }
        }
        .padding(.horizontal, CompactOverviewLayout.horizontalPadding)
        .padding(.top, CompactOverviewLayout.labeledUsageTopPadding)
        .padding(.bottom, CompactOverviewLayout.labeledBottomPadding)
        .frame(width: self.layout.menuWidth, alignment: .leading)
    }

    private func fallbackText(_ text: String, font: Font) -> some View {
        Text(text)
            .font(font)
            .foregroundStyle(MenuHighlightStyle.secondary(self.isHighlighted))
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(width: self.layout.contentWidth, alignment: .leading)
            .help(text)
    }
}

struct CompactOverviewBarsOnlyContent: View {
    let projection: CompactOverviewProjection
    let layout: CompactOverviewLayout

    var body: some View {
        VStack(alignment: .leading, spacing: CompactOverviewLayout.barsOnlyLaneSpacing) {
            if self.projection.lanes.isEmpty, let fallback = self.projection.fallback {
                CompactOverviewUnavailableRail(
                    fallback: fallback,
                    barWidth: self.layout.barsOnlyBarWidth)
            } else {
                ForEach(self.projection.lanes) { lane in
                    CompactOverviewBareBarLane(
                        lane: lane,
                        barWidth: self.layout.barsOnlyBarWidth)
                }
            }
        }
        .padding(.horizontal, CompactOverviewLayout.horizontalPadding)
        .padding(.vertical, CompactOverviewLayout.barsOnlyVerticalPadding)
        .frame(width: self.layout.menuWidth, alignment: .leading)
        .accessibilityElement(children: .contain)
    }
}

private struct CompactOverviewBareBarLane: View {
    let lane: CompactOverviewProjection.Lane
    let barWidth: CGFloat

    var body: some View {
        UsageProgressBar(
            percent: self.lane.percent,
            tint: self.lane.tint,
            accessibilityLabel: self.lane.barAccessibilityLabel,
            pacePercent: self.lane.pacePercent,
            paceOnTop: self.lane.paceOnTop,
            warningMarkerPercents: self.lane.warningMarkerPercents,
            workdayMarkerPercents: self.lane.workdayMarkerPercents,
            height: CompactOverviewLayout.barHeight)
            .frame(width: self.barWidth)
            .help(self.lane.title)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(self.lane.title)
    }
}

private struct CompactOverviewUnavailableRail: View {
    let fallback: CompactOverviewProjection.Fallback
    let barWidth: CGFloat
    @Environment(\.menuItemHighlighted) private var isHighlighted

    var body: some View {
        self.accessibleRail
    }

    @ViewBuilder
    private var accessibleRail: some View {
        switch self.fallback {
        case let .status(_, title, text):
            self.rail
                .accessibilityLabel(title)
                .accessibilityValue(text)
        case let .loading(text), let .generic(text):
            self.rail
                .accessibilityLabel(text)
        }
    }

    private var rail: some View {
        Capsule()
            .fill(MenuHighlightStyle.progressTrack(self.isHighlighted).opacity(0.55))
            .overlay {
                Capsule()
                    .strokeBorder(
                        MenuHighlightStyle.secondary(self.isHighlighted).opacity(0.55),
                        style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            }
            .frame(width: self.barWidth, height: CompactOverviewLayout.barHeight)
            .help(self.fallback.text)
            .accessibilityElement(children: .ignore)
    }
}
