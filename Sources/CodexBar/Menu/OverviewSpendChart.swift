import CodexBarCore
import Foundation
import SwiftUI

// MARK: - Palette

/// Chart colours for spend across providers. Each provider owns a hue anchored to its brand, and effort steps
/// through lightness inside that hue: higher effort is darker and richer, lower effort paler.
enum OverviewSpendPalette {
    struct Anchor: Equatable {
        let hue: Double
        let chroma: Double
        let lightnessOffset: Double
    }

    struct OKLCH: Equatable {
        let lightness: Double
        let chroma: Double
        let hue: Double
    }

    /// Brand hues crowd: four of the common providers are orange-red and two are the same violet. These stay as close
    /// to the brand as the set allows.
    /// Provider-specific by design: hand-tuned hues keep crowded brand colours apart; the rest derive from branding.
    private static let anchors: [UsageProvider: Anchor] = [
        .claude: Anchor(hue: 33, chroma: 0.11, lightnessOffset: 0.04),
        .codex: Anchor(hue: 200, chroma: 0.105, lightnessOffset: -0.04),
        .cursor: Anchor(hue: 255, chroma: 0.012, lightnessOffset: 0.06),
        .gemini: Anchor(hue: 295, chroma: 0.135, lightnessOffset: -0.04),
        .copilot: Anchor(hue: 334, chroma: 0.15, lightnessOffset: 0.02),
        .factory: Anchor(hue: 93, chroma: 0.115, lightnessOffset: -0.04),
        .windsurf: Anchor(hue: 167, chroma: 0.13, lightnessOffset: 0.02),
        .kimi: Anchor(hue: 252, chroma: 0.14, lightnessOffset: 0.04),
    ]

    /// Coral glows on the dark menu. The same hue with less chroma and no lightness lift still reads as Claude.
    private static let darkAnchors: [UsageProvider: Anchor] = [
        .claude: Anchor(hue: 33, chroma: 0.09, lightnessOffset: 0),
    ]

    static var anchoredProviders: [UsageProvider] {
        self.anchors.keys.sorted { $0.rawValue < $1.rawValue }
    }

    static func anchor(for provider: UsageProvider) -> Anchor {
        if let anchor = self.anchors[provider] { return anchor }
        let brand = self.oklch(ProviderDescriptorRegistry.descriptor(for: provider).branding.color)
        // A mono brand stays mono. A warm brand becomes dusty rose, so nothing reads as orange on the dark menu.
        if brand.chroma < 0.03 { return Anchor(hue: brand.hue, chroma: 0.012, lightnessOffset: 0.03) }
        if (18.0...80.0).contains(brand.hue) { return Anchor(hue: 15, chroma: 0.10, lightnessOffset: 0.04) }
        return Anchor(hue: brand.hue, chroma: 0.12, lightnessOffset: 0)
    }

    static func color(provider: UsageProvider, tier: ModelEffortTier, dark: Bool) -> ProviderColor {
        let anchor = (dark ? self.darkAnchors[provider] : nil) ?? self.anchor(for: provider)
        let base = dark ? 0.62 : 0.50
        let step = dark ? 0.085 : 0.08
        let (lightnessSteps, chromaScale) = switch tier {
        case .high: (0.0, 1.0)
        case .standard: (1.0, 0.95)
        case .fast: (2.0, 0.82)
        }
        return self.color(OKLCH(
            lightness: base + anchor.lightnessOffset + lightnessSteps * step,
            chroma: anchor.chroma * chromaScale,
            hue: anchor.hue))
    }

    static func oklch(_ color: ProviderColor) -> OKLCH {
        func linear(_ channel: Double) -> Double {
            channel <= 0.04045 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
        }
        let red = linear(color.red), green = linear(color.green), blue = linear(color.blue)
        let long = cbrt(0.4122214708 * red + 0.5363325363 * green + 0.0514459929 * blue)
        let medium = cbrt(0.2119034982 * red + 0.6806995451 * green + 0.1073969566 * blue)
        let short = cbrt(0.0883024619 * red + 0.2817188376 * green + 0.6299787005 * blue)
        let labA = 1.9779984951 * long - 2.4285922050 * medium + 0.4505937099 * short
        let labB = 0.0259040371 * long + 0.7827717662 * medium - 0.8086757660 * short
        let hue = atan2(labB, labA) * 180 / .pi
        return OKLCH(
            lightness: 0.2104542553 * long + 0.7936177850 * medium - 0.0040720468 * short,
            chroma: hypot(labA, labB),
            hue: hue < 0 ? hue + 360 : hue)
    }

    /// Chroma gives way first when a colour falls outside sRGB, which keeps the hue and lightness steps intact.
    private static func color(_ value: OKLCH) -> ProviderColor {
        var chroma = value.chroma
        while chroma > 0 {
            let channels = self.linearChannels(lightness: value.lightness, chroma: chroma, hue: value.hue)
            if channels.allSatisfy({ (-0.001...1.001).contains($0) }) { break }
            chroma -= 0.002
        }
        let channels = self.linearChannels(lightness: value.lightness, chroma: max(0, chroma), hue: value.hue)
            .map { channel -> Double in
                let clamped = min(1, max(0, channel))
                return clamped <= 0.0031308 ? clamped * 12.92 : 1.055 * pow(clamped, 1 / 2.4) - 0.055
            }
        return ProviderColor(red: channels[0], green: channels[1], blue: channels[2])
    }

    private static func linearChannels(lightness: Double, chroma: Double, hue: Double) -> [Double] {
        let labA = chroma * cos(hue * .pi / 180)
        let labB = chroma * sin(hue * .pi / 180)
        let long = pow(lightness + 0.3963377774 * labA + 0.2158037573 * labB, 3)
        let medium = pow(lightness - 0.1055613458 * labA - 0.0638541728 * labB, 3)
        let short = pow(lightness - 0.0894841775 * labA - 1.2914855480 * labB, 3)
        return [
            4.0767416621 * long - 3.3077115913 * medium + 0.2309699292 * short,
            -1.2684380046 * long + 2.6097574011 * medium - 0.3413193965 * short,
            -0.0041960863 * long - 0.7034186147 * medium + 1.7076147010 * short,
        ]
    }
}

extension Color {
    init(providerColor color: ProviderColor) {
        self.init(red: color.red, green: color.green, blue: color.blue)
    }
}

// MARK: - Data

struct OverviewDailySpend: Equatable {
    /// One piece of a day's bar. A nil provider is the folded tail, past `maxSeries`.
    struct Segment: Equatable {
        let provider: UsageProvider?
        let tier: ModelEffortTier
        let cost: Double
    }

    struct LegendEntry: Equatable, Identifiable {
        let provider: UsageProvider?
        let name: String
        let share: Double?

        var id: String {
            self.provider?.rawValue ?? "other"
        }
    }

    /// More hues than this stop being tellable apart, so the smallest providers fold into a neutral Other.
    static let maxSeries = 8

    let points: [MenuUsageBarPoint]
    let todayText: String
    var stacks: [String: [Segment]] = [:]
    var legend: [LegendEntry] = []

    /// Providers with spend, largest first. Daily-only contributors stay visible without inventing a range share.
    /// This order also stacks every bar, so a provider keeps its place all month.
    static func legend(
        totals costs: [(provider: UsageProvider, cost: Double)],
        dailyRows: [SpendDashboardModel.DailyProviderRow] = [],
        rangeSharesAvailable: Bool = true) -> [LegendEntry]
    {
        var totals: [UsageProvider: Double] = [:]
        for (provider, cost) in costs where cost > 0 && cost.isFinite {
            totals[provider, default: 0] += cost
        }
        var dailyTotals: [UsageProvider: Double] = [:]
        for row in dailyRows {
            guard let cost = row.totalCost, cost > 0, cost.isFinite else { continue }
            dailyTotals[row.provider, default: 0] += cost
        }
        var rankedTotals = totals
        for (provider, cost) in dailyTotals where rankedTotals[provider] == nil {
            rankedTotals[provider] = cost
        }
        guard !rankedTotals.isEmpty else { return [] }
        let total = totals.values.reduce(0, +)
        let hasRangeShares = rangeSharesAvailable && total > 0 && total.isFinite &&
            dailyTotals.keys.allSatisfy { totals[$0] != nil }
        let sorted = rankedTotals.sorted { ($0.value, $1.key.rawValue) > ($1.value, $0.key.rawValue) }
        let foldsTail = sorted.count > self.maxSeries
        let kept = foldsTail ? Array(sorted.prefix(self.maxSeries - 1)) : sorted
        // An entry can merge several accounts, so it takes the provider's name rather than any one account's.
        var entries = kept.map {
            LegendEntry(
                provider: $0.key,
                name: ProviderDescriptorRegistry.descriptor(for: $0.key).metadata.displayName,
                share: hasRangeShares ? totals[$0.key].map { $0 / total } : nil)
        }
        if foldsTail {
            let otherShare = hasRangeShares
                ? sorted.dropFirst(kept.count).compactMap { totals[$0.key] }.reduce(0, +) / total : nil
            entries.append(LegendEntry(provider: nil, name: L("Other"), share: otherShare))
        }
        return entries
    }

    /// A day's bar, in legend order with higher effort nearest the baseline. It always sums to the day's known spend:
    /// missing or inconsistent model detail stays an unclassified block in the standard shade.
    static func segments(rows: [SpendDashboardModel.DailyProviderRow], legend: [LegendEntry]) -> [Segment] {
        var result: [Segment] = []
        for entry in legend {
            guard let provider = entry.provider else { continue }
            let costs = rows.filter { $0.provider == provider }.flatMap { row -> [(ModelEffortTier, Double)] in
                guard let total = row.totalCost, total > 0, total.isFinite else { return [] }
                let attributed = row.modelCosts.map(\.cost).reduce(0, +)
                guard attributed > 0, row.modelCosts.allSatisfy({ SpendDashboardModel.validCost($0.cost) != nil }),
                      SpendDashboardModel.costsMatch(attributed, total)
                else { return [(.standard, total)] }
                return row.modelCosts.map { (ModelEffortTier.classify($0.modelName), $0.cost) }
            }
            for tier in ModelEffortTier.allCases.sorted() {
                let cost = costs.filter { $0.0 == tier }.map(\.1).reduce(0, +)
                if cost > 0 { result.append(Segment(provider: provider, tier: tier, cost: cost)) }
            }
        }
        if legend.contains(where: { $0.provider == nil }) {
            let kept = Set(legend.compactMap(\.provider))
            let other = rows.filter { !kept.contains($0.provider) }.compactMap(\.totalCost)
                .filter { $0 > 0 && $0.isFinite }.reduce(0, +)
            if other > 0 { result.append(Segment(provider: nil, tier: .standard, cost: other)) }
        }
        return result
    }

    /// A tier too thin to see folds into its provider's largest tier in that bar, so the shades that can be read stay.
    /// If none can be read the provider is one standard block. Spend and stack order do not change.
    static func mergingThinTiers(
        _ segments: [Segment],
        barHeight: CGFloat,
        minimumTierHeight: CGFloat) -> [Segment]
    {
        let total = segments.map(\.cost).reduce(0, +)
        guard total > 0 else { return segments }
        func isVisible(_ segment: Segment) -> Bool {
            barHeight * CGFloat(segment.cost / total) >= minimumTierHeight
        }
        var result: [Segment] = []
        var index = segments.startIndex
        while index < segments.endIndex {
            let provider = segments[index].provider
            let group = segments[index...].prefix { $0.provider == provider }
            index += group.count
            let visible = group.filter(isVisible)
            let hiddenCost = group.filter { !isVisible($0) }.map(\.cost).reduce(0, +)
            guard let largest = visible.max(by: { $0.cost < $1.cost }) else {
                let tier = group.count == 1 ? group[group.startIndex].tier : ModelEffortTier.standard
                result.append(Segment(provider: provider, tier: tier, cost: hiddenCost))
                continue
            }
            result += visible.map { segment in
                segment.tier == largest.tier
                    ? Segment(provider: provider, tier: segment.tier, cost: segment.cost + hiddenCost)
                    : segment
            }
        }
        return result
    }

    /// The range's share, or that day's while one is hovered.
    func share(of entry: LegendEntry, pointID: String?) -> Double? {
        guard let pointID else { return entry.share }
        let segments = self.stacks[pointID] ?? []
        let total = segments.map(\.cost).reduce(0, +)
        guard total > 0 else { return 0 }
        return segments.filter { $0.provider == entry.provider }.map(\.cost).reduce(0, +) / total
    }
}

// MARK: - Views

/// Thirty days of spend, stacked by provider and shaded by model effort. Hovering a bar puts that day in the label
/// and the legend, so one readout answers instead of a label on every segment.
struct OverviewStackedSpendChart: View {
    let daily: OverviewDailySpend
    @State private var hoveredPointID: String?
    @Environment(\.menuUsageBarSelection) private var injectedSelection
    @Environment(\.menuItemHighlighted) private var isHighlighted
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.layoutDirection) private var layoutDirection

    private var selectedPointID: String? {
        self.injectedSelection?.wrappedValue ?? self.hoveredPointID
    }

    /// Below this a tier is a stray pixel row, not a shade anyone can read.
    private static let minimumTierHeight: CGFloat = 2.5

    /// More providers split the same bar into more pieces, so they get more height to split.
    private var chartHeight: CGFloat {
        self.daily.legend.count > 4 ? 52 : 40
    }

    var body: some View {
        let hover = self.daily.points.first { $0.id == self.selectedPointID }?.hoverSummary
        VStack(alignment: .leading, spacing: 4) {
            Text(hover ?? self.daily.todayText)
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(MenuHighlightStyle.secondary(self.isHighlighted))
                .lineLimit(1)
            self.chart
                .frame(height: self.chartHeight)
            OverviewSpendLegend(daily: self.daily, selectedPointID: self.selectedPointID)
        }
    }

    private var chart: some View {
        GeometryReader { geometry in
            let layout = InlineUsageBarLayout(width: geometry.size.width, count: self.daily.points.count)
            let scale = MenuUsageBarMetrics.scale(values: self.daily.points.compactMap(\.value))
            Canvas { context, size in
                self.draw(in: &context, size: size, layout: layout, scale: scale)
            }
            .background {
                MouseLocationReader { location in
                    let pointID = InlineUsageBarHoverSelection.pointID(
                        current: self.selectedPointID,
                        locationX: location?.x,
                        layout: layout,
                        layoutDirection: self.layoutDirection,
                        points: self.daily.points)
                    if pointID != self.hoveredPointID { self.hoveredPointID = pointID }
                }
            }
            .overlay {
                HStack(spacing: layout.spacing) {
                    ForEach(self.daily.points) { point in
                        Color.clear
                            .frame(width: layout.barWidth)
                            .accessibilityElement()
                            .accessibilityLabel(point.accessibilityValue)
                    }
                }
            }
        }
    }

    private func draw(
        in context: inout GraphicsContext,
        size: CGSize,
        layout: InlineUsageBarLayout,
        scale: UsageChartScale)
    {
        let baseline = CGRect(x: 0, y: size.height - 1, width: size.width, height: 1)
        context.fill(
            Path(baseline),
            with: .color(MenuHighlightStyle.secondary(self.isHighlighted).opacity(0.22)))
        let stride = layout.barWidth + layout.spacing
        for (index, point) in self.daily.points.enumerated() {
            guard let value = point.value, value > 0 else { continue }
            let position = CGFloat(index) * stride
            let x = self.layoutDirection == .rightToLeft ? size.width - position - layout.barWidth : position
            let height = max(3, CGFloat(scale.fraction(for: value)) * size.height)
            let bar = CGRect(x: x, y: size.height - height, width: layout.barWidth, height: height)
            let rounded = Path(roundedRect: bar, cornerRadius: 1.5, style: .continuous)
            context.drawLayer { layer in
                layer.clip(to: rounded)
                self.drawSegments(of: point, in: bar, context: &layer)
            }
            if point.id == self.selectedPointID {
                context.stroke(
                    rounded,
                    with: .color(MenuHighlightStyle.primary(self.isHighlighted)),
                    lineWidth: layout.selectionStrokeWidth(barHeight: height))
            }
        }
    }

    private func drawSegments(of point: MenuUsageBarPoint, in bar: CGRect, context: inout GraphicsContext) {
        let segments = OverviewDailySpend.mergingThinTiers(
            self.daily.stacks[point.id] ?? [],
            barHeight: bar.height,
            minimumTierHeight: Self.minimumTierHeight)
        let total = segments.map(\.cost).reduce(0, +)
        guard total > 0 else { return }
        var bottom = bar.maxY
        for (index, segment) in segments.enumerated() {
            let height = bar.height * CGFloat(segment.cost / total)
            // A hairline separates providers. Tiers touch, so each provider reads as one block.
            let startsNewProvider = index + 1 < segments.count && segments[index + 1].provider != segment.provider
            let gap: CGFloat = startsNewProvider && height > 1.5 ? 0.75 : 0
            let rect = CGRect(x: bar.minX, y: bottom - height + gap, width: bar.width, height: height - gap)
            context.fill(Path(rect), with: .color(self.fill(segment)))
            bottom -= height
        }
    }

    private func fill(_ segment: OverviewDailySpend.Segment) -> Color {
        if self.isHighlighted { return MenuHighlightStyle.selectionText.opacity(0.8) }
        guard let provider = segment.provider else { return Color.primary.opacity(0.28) }
        return Color(providerColor: OverviewSpendPalette.color(
            provider: provider,
            tier: segment.tier,
            dark: self.colorScheme == .dark))
    }
}

/// Official logo, the provider's three shades, its share. Four or fewer keep their names; past that the logos carry it.
struct OverviewSpendLegend: View {
    let daily: OverviewDailySpend
    let selectedPointID: String?
    @Environment(\.menuItemHighlighted) private var isHighlighted
    @Environment(\.colorScheme) private var colorScheme

    private var showsNames: Bool {
        self.daily.legend.count <= 4
    }

    var body: some View {
        let columns = Array(
            repeating: GridItem(.flexible(), spacing: 6, alignment: .leading),
            count: min(4, max(1, self.daily.legend.count)))
        LazyVGrid(columns: columns, alignment: .leading, spacing: 4) {
            ForEach(self.daily.legend) { entry in
                self.item(entry)
            }
        }
    }

    private func item(_ entry: OverviewDailySpend.LegendEntry) -> some View {
        let share = self.daily.share(of: entry, pointID: self.selectedPointID)
        let shareText = share.map { share in
            share > 0 && share < 0.01 ? "<1%" : "\(Int((share * 100).rounded()))%"
        } ?? L("Unknown")
        return HStack(spacing: 4) {
            self.swatch(entry)
            if let provider = entry.provider {
                SpendProviderIcon(
                    provider: provider,
                    style: self.isHighlighted ? .monochrome : .brand,
                    size: 12,
                    foreground: MenuHighlightStyle.primary(self.isHighlighted))
            }
            if self.showsNames || entry.provider == nil {
                Text(entry.name)
                    .foregroundStyle(MenuHighlightStyle.primary(self.isHighlighted))
                    .lineLimit(1)
            }
            Text(shareText)
                .foregroundStyle(MenuHighlightStyle.secondary(self.isHighlighted))
                .lineLimit(1)
                .fixedSize()
        }
        .font(.caption)
        .monospacedDigit()
        .help(entry.name)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(entry.name) \(shareText)")
    }

    private func swatch(_ entry: OverviewDailySpend.LegendEntry) -> some View {
        VStack(spacing: 0) {
            ForEach(ModelEffortTier.allCases.sorted().reversed(), id: \.self) { tier in
                Rectangle().fill(self.swatchFill(entry, tier: tier))
            }
        }
        .frame(width: 4, height: 11)
        .clipShape(RoundedRectangle(cornerRadius: 1, style: .continuous))
    }

    private func swatchFill(_ entry: OverviewDailySpend.LegendEntry, tier: ModelEffortTier) -> Color {
        if self.isHighlighted { return MenuHighlightStyle.selectionText.opacity(0.8) }
        guard let provider = entry.provider else { return Color.primary.opacity(0.28) }
        return Color(providerColor: OverviewSpendPalette.color(
            provider: provider,
            tier: tier,
            dark: self.colorScheme == .dark))
    }
}
