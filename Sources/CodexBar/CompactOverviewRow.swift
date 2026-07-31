import AppKit
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

        var accessibilityLabel: String {
            self.percentStyle.accessibilityLabel
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

    init(
        model: UsageMenuCardView.Model,
        loadingText: String = L("Loading…"),
        noBarsText: String = L("overview_compact_no_bars"))
    {
        self.providerName = model.providerName
        self.lanes = model.metrics.compactMap { metric in
            guard metric.statusText == nil else { return nil }
            return Lane(
                id: metric.id,
                title: metric.title,
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
                noBarsText: noBarsText)
        } else {
            self.fallback = nil
        }
        self.layoutSignature = Self.makeLayoutSignature(lanes: self.lanes, fallback: self.fallback)
    }

    var metricTitlesForColumnMeasurement: [String] {
        if self.lanes.isEmpty {
            return self.fallback?.metricTitle.map { [$0] } ?? []
        }
        return self.lanes.map(\.title)
    }

    private static func makeFallback(
        model: UsageMenuCardView.Model,
        loadingText: String,
        noBarsText: String) -> Fallback
    {
        if case .loading = model.subtitleStyle {
            return .loading(text: loadingText)
        }

        for metric in model.metrics {
            guard let statusText = metric.statusText?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                !statusText.isEmpty
            else { continue }
            return .status(metricID: metric.id, title: metric.title, text: statusText)
        }
        return .generic(text: noBarsText)
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

    private static func joinSignature(_ fields: [String]) -> String {
        fields.map { "\($0.utf8.count):\($0)" }.joined(separator: "|")
    }
}

struct CompactOverviewTextWidthMeasurer {
    enum Role: Hashable {
        case provider
        case metric
    }

    let fontSignature: String
    private let measure: (String, Role) -> CGFloat

    init(fontSignature: String, measure: @escaping (String, Role) -> CGFloat) {
        self.fontSignature = fontSignature
        self.measure = measure
    }

    func width(of text: String, role: Role) -> CGFloat {
        max(0, self.measure(text, role))
    }

    static func appKit() -> Self {
        let bodyFont = NSFont.preferredFont(forTextStyle: .body)
        let fonts: [Role: NSFont] = [
            .provider: NSFont.systemFont(ofSize: bodyFont.pointSize, weight: .semibold),
            .metric: bodyFont,
        ]
        let signature = [Role.provider, .metric]
            .compactMap { role -> String? in
                guard let font = fonts[role] else { return nil }
                return "\(font.fontName):\(font.pointSize)"
            }
            .joined(separator: "|")
        return Self(fontSignature: signature) { text, role in
            guard let font = fonts[role] else { return 0 }
            return ceil((text as NSString).size(withAttributes: [.font: font]).width)
        }
    }
}

enum CompactOverviewColumnLayoutError: Error, Equatable {
    case menuWidthBelowMinimum(CGFloat)
}

struct CompactOverviewColumnLayout {
    struct AllocationInput {
        let menuWidth: CGFloat
        let idealMetricWidth: CGFloat
        let fontSignature: String
        let layoutDirection: LayoutDirection
    }

    static let minimumMenuWidth: CGFloat = 310
    static let horizontalPadding: CGFloat = UsageMenuCardLayout.horizontalPadding
    static let columnSpacing: CGFloat = 12
    static let metricWidthCap: CGFloat = 112
    static let minimumBarWidth: CGFloat = 146
    static let chevronGutterWidth: CGFloat = 12
    static let rowVerticalPadding: CGFloat = 4
    static let providerContentSpacing: CGFloat = 4
    static let laneSpacing: CGFloat = 3
    static let barHeight: CGFloat = 8

    let menuWidth: CGFloat
    let metricWidth: CGFloat
    let barWidth: CGFloat
    let layoutDirection: LayoutDirection
    let signature: String

    var contentWidth: CGFloat {
        self.metricWidth
            + Self.columnSpacing
            + self.barWidth
    }

    var occupiedWidth: CGFloat {
        Self.horizontalPadding * 2
            + self.contentWidth
    }

    var providerHeaderWidth: CGFloat {
        self.contentWidth - Self.chevronGutterWidth
    }

    static func resolve(
        menuWidth: CGFloat,
        projections: [CompactOverviewProjection],
        layoutDirection: LayoutDirection,
        textWidthMeasurer: CompactOverviewTextWidthMeasurer) throws -> Self
    {
        let idealMetricWidth = projections
            .flatMap(\.metricTitlesForColumnMeasurement)
            .map { textWidthMeasurer.width(of: $0, role: .metric) }
            .max() ?? 0

        return try Self.allocate(AllocationInput(
            menuWidth: menuWidth,
            idealMetricWidth: idealMetricWidth,
            fontSignature: textWidthMeasurer.fontSignature,
            layoutDirection: layoutDirection))
    }

    static func resolveForMenu(
        menuWidth: CGFloat,
        projections: [CompactOverviewProjection],
        layoutDirection: LayoutDirection,
        textWidthMeasurer: CompactOverviewTextWidthMeasurer) -> Self
    {
        assert(
            menuWidth >= self.minimumMenuWidth,
            "Compact Overview menu width must be at least \(self.minimumMenuWidth) points")
        do {
            return try self.resolve(
                menuWidth: menuWidth,
                projections: projections,
                layoutDirection: layoutDirection,
                textWidthMeasurer: textWidthMeasurer)
        } catch {
            preconditionFailure("Compact Overview failed to resolve a supported menu width: \(error)")
        }
    }

    static func allocate(_ input: AllocationInput) throws -> Self {
        guard input.menuWidth >= self.minimumMenuWidth else {
            throw CompactOverviewColumnLayoutError.menuWidthBelowMinimum(input.menuWidth)
        }

        let idealMetricWidth = max(0, input.idealMetricWidth)
        let metricWidth = min(idealMetricWidth, Self.metricWidthCap)
        let fixedWidth = Self.horizontalPadding * 2
            + Self.columnSpacing
        var barWidth = input.menuWidth - fixedWidth - metricWidth

        let widthExpansion = max(0, Self.minimumBarWidth - barWidth)
        let resolvedMenuWidth = input.menuWidth + widthExpansion
        barWidth += widthExpansion

        let direction = switch input.layoutDirection {
        case .leftToRight: "ltr"
        case .rightToLeft: "rtl"
        @unknown default: "unknown"
        }
        let signature = Self.signature(fields: [
            "menu=\(Self.geometryToken(resolvedMenuWidth))",
            "metric=\(Self.geometryToken(metricWidth))",
            "bar=\(Self.geometryToken(barWidth))",
            "spacing=\(Self.geometryToken(Self.columnSpacing))",
            "gutter=\(Self.geometryToken(Self.chevronGutterWidth))",
            "padding=\(Self.geometryToken(Self.horizontalPadding))",
            "barHeight=\(Self.geometryToken(Self.barHeight))",
            "providerSpacing=\(Self.geometryToken(Self.providerContentSpacing))",
            "laneSpacing=\(Self.geometryToken(Self.laneSpacing))",
            "font=\(input.fontSignature)",
            "direction=\(direction)",
        ])
        return Self(
            menuWidth: resolvedMenuWidth,
            metricWidth: metricWidth,
            barWidth: barWidth,
            layoutDirection: input.layoutDirection,
            signature: signature)
    }

    private static func geometryToken(_ value: CGFloat) -> Int {
        Int((value * 100).rounded())
    }

    private static func signature(fields: [String]) -> String {
        fields.map { "\($0.utf8.count):\($0)" }.joined(separator: "|")
    }
}

struct CompactOverviewRowContent: View {
    let projection: CompactOverviewProjection
    let columns: CompactOverviewColumnLayout
    @Environment(\.menuItemHighlighted) private var isHighlighted

    var body: some View {
        VStack(alignment: .leading, spacing: CompactOverviewColumnLayout.providerContentSpacing) {
            HStack(spacing: 0) {
                Text(self.projection.providerName)
                    .font(.headline)
                    .foregroundStyle(MenuHighlightStyle.primary(self.isHighlighted))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(width: self.columns.providerHeaderWidth, alignment: .leading)
                    .help(self.projection.providerName)
                    .accessibilityHidden(true)

                Color.clear
                    .frame(width: CompactOverviewColumnLayout.chevronGutterWidth, height: 0)
                    .accessibilityHidden(true)
            }

            self.content
        }
        .padding(.horizontal, CompactOverviewColumnLayout.horizontalPadding)
        .padding(.vertical, CompactOverviewColumnLayout.rowVerticalPadding)
        .frame(width: self.columns.menuWidth, alignment: .leading)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var content: some View {
        if self.projection.lanes.isEmpty, let fallback = self.projection.fallback {
            CompactOverviewFallbackContent(fallback: fallback, columns: self.columns)
        } else {
            VStack(alignment: .leading, spacing: CompactOverviewColumnLayout.laneSpacing) {
                ForEach(self.projection.lanes) { lane in
                    CompactOverviewMetricLane(lane: lane, columns: self.columns)
                }
            }
            .accessibilityElement(children: .contain)
        }
    }
}

private struct CompactOverviewMetricLane: View {
    let lane: CompactOverviewProjection.Lane
    let columns: CompactOverviewColumnLayout
    @Environment(\.menuItemHighlighted) private var isHighlighted

    var body: some View {
        HStack(alignment: .center, spacing: 0) {
            Text(self.lane.title)
                .font(.body)
                .foregroundStyle(MenuHighlightStyle.primary(self.isHighlighted))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: self.columns.metricWidth, alignment: .leading)
                .help(self.lane.title)
                .accessibilityHidden(true)

            Color.clear
                .frame(width: CompactOverviewColumnLayout.columnSpacing, height: 0)
                .accessibilityHidden(true)

            UsageProgressBar(
                percent: self.lane.percent,
                tint: self.lane.tint,
                accessibilityLabel: self.lane.accessibilityLabel,
                pacePercent: self.lane.pacePercent,
                paceOnTop: self.lane.paceOnTop,
                warningMarkerPercents: self.lane.warningMarkerPercents,
                workdayMarkerPercents: self.lane.workdayMarkerPercents,
                height: CompactOverviewColumnLayout.barHeight)
                .frame(width: self.columns.barWidth)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(self.lane.title)
    }
}

private struct CompactOverviewFallbackContent: View {
    let fallback: CompactOverviewProjection.Fallback
    let columns: CompactOverviewColumnLayout
    @Environment(\.menuItemHighlighted) private var isHighlighted

    var body: some View {
        switch self.fallback {
        case let .status(_, title, text):
            HStack(spacing: 0) {
                self.fallbackText(title, width: self.columns.metricWidth)
                Color.clear
                    .frame(width: CompactOverviewColumnLayout.columnSpacing, height: 0)
                    .accessibilityHidden(true)
                self.fallbackText(
                    text,
                    width: self.columns.barWidth)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(title)
            .accessibilityValue(text)
        case let .loading(text), let .generic(text):
            self.fallbackText(text, width: self.columns.contentWidth)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(text)
        }
    }

    private func fallbackText(_ text: String, width: CGFloat) -> some View {
        Text(text)
            .font(.body)
            .foregroundStyle(MenuHighlightStyle.secondary(self.isHighlighted))
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(width: width, alignment: .leading)
            .help(text)
    }
}
