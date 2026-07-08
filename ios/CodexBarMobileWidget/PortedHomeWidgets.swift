import AppIntents
import Charts
import SwiftUI
import WidgetKit

// MARK: - Widget registrations

struct HistoryWidget: Widget {
    let kind = "CodexBarHistoryWidget"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: self.kind, intent: SelectProviderIntent.self, provider: UsageTimelineProvider()) { entry in
            HistoryWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Usage History")
        .description("Recent provider spend or token history.")
        .supportedFamilies([.systemMedium, .systemLarge])
    }
}

struct CompactWidget: Widget {
    let kind = "CodexBarCompactWidget"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: self.kind, intent: CompactMetricIntent.self, provider: CompactTimelineProvider()) { entry in
            CompactWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Usage Metric")
        .description("One compact CodexBar usage number.")
        .supportedFamilies([.systemSmall])
    }
}

struct BurnDownWidget: Widget {
    let kind = "CodexBarBurnDownWidget"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: self.kind, intent: SelectProviderIntent.self, provider: UsageTimelineProvider()) { entry in
            BurnDownWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Usage Burn Down")
        .description("Remaining budget versus ideal burn pace.")
        .supportedFamilies([.systemMedium])
    }
}

struct CombinedBurnDownWidget: Widget {
    let kind = "CodexBarCombinedBurnDownWidget"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: self.kind, intent: SelectProviderIntent.self, provider: UsageTimelineProvider()) { entry in
            CombinedBurnDownWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Session & Weekly Burn")
        .description("Session and weekly burn pace together.")
        .supportedFamilies([.systemMedium])
    }
}

struct SwitcherWidget: Widget {
    let kind = "CodexBarSwitcherWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: self.kind, provider: SwitcherTimelineProvider()) { entry in
            SwitcherWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Provider Switcher")
        .description("Most constrained provider across CodexBar.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

// MARK: - Compact intent/provider

enum CompactMetric: String, AppEnum {
    case credits
    case cost
    case sessionPercent

    static var typeDisplayRepresentation: TypeDisplayRepresentation { "Metric" }
    static var caseDisplayRepresentations: [CompactMetric: DisplayRepresentation] {
        [
            .credits: "Credits",
            .cost: "Session Cost",
            .sessionPercent: "Session Percent",
        ]
    }
}

struct CompactMetricIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource { "Choose Metric" }
    static var description: IntentDescription { "Pick the compact usage number." }

    @Parameter(title: "Provider")
    var provider: ProviderEntity?

    @Parameter(title: "Metric")
    var metric: CompactMetric?
}

struct CompactEntry: TimelineEntry {
    let date: Date
    let entry: WidgetSnapshot.ProviderEntry?
    let metadata: SyncMetadata?
    let metric: CompactMetric
}

struct CompactTimelineProvider: AppIntentTimelineProvider {
    func placeholder(in _: Context) -> CompactEntry {
        let usage = UsageEntry.placeholder()
        return CompactEntry(date: usage.date, entry: usage.entry, metadata: usage.metadata, metric: .credits)
    }

    func snapshot(for configuration: CompactMetricIntent, in context: Context) async -> CompactEntry {
        self.currentEntry(for: configuration) ?? self.placeholder(in: context)
    }

    func timeline(for configuration: CompactMetricIntent, in _: Context) async -> Timeline<CompactEntry> {
        let entry = self.currentEntry(for: configuration)
            ?? CompactEntry(date: Date(), entry: nil, metadata: MobileSnapshotStore.loadMetadata(), metric: .credits)
        return Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(60 * 60)))
    }

    private func currentEntry(for configuration: CompactMetricIntent) -> CompactEntry? {
        guard let snapshot = MobileSnapshotStore.loadSnapshot() else { return nil }
        let entries = snapshot.enabledEntries
        let chosen: WidgetSnapshot.ProviderEntry?
        if let selected = configuration.provider?.provider {
            chosen = entries.first { $0.provider == selected }
        } else {
            chosen = entries.min { ($0.headlineRemainingPercent ?? 100) < ($1.headlineRemainingPercent ?? 100) }
        }
        guard let chosen else { return nil }
        return CompactEntry(
            date: Date(),
            entry: chosen,
            metadata: MobileSnapshotStore.loadMetadata(),
            metric: configuration.metric ?? .credits)
    }
}

// MARK: - Switcher provider

struct SwitcherEntry: TimelineEntry {
    let date: Date
    let entry: WidgetSnapshot.ProviderEntry?
    let metadata: SyncMetadata?
    let providers: [UsageProvider]
}

struct SwitcherTimelineProvider: TimelineProvider {
    func placeholder(in _: Context) -> SwitcherEntry {
        let usage = UsageEntry.placeholder()
        return SwitcherEntry(date: usage.date, entry: usage.entry, metadata: usage.metadata, providers: [.codex])
    }

    func getSnapshot(in context: Context, completion: @escaping (SwitcherEntry) -> Void) {
        completion(self.currentEntry() ?? self.placeholder(in: context))
    }

    func getTimeline(in _: Context, completion: @escaping (Timeline<SwitcherEntry>) -> Void) {
        let entry = self.currentEntry()
            ?? SwitcherEntry(date: Date(), entry: nil, metadata: MobileSnapshotStore.loadMetadata(), providers: [])
        completion(Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(60 * 60))))
    }

    private func currentEntry() -> SwitcherEntry? {
        guard let snapshot = MobileSnapshotStore.loadSnapshot() else { return nil }
        let entries = snapshot.enabledEntries
        guard let chosen = entries.min(by: {
            ($0.headlineRemainingPercent ?? 100) < ($1.headlineRemainingPercent ?? 100)
        }) else { return nil }
        return SwitcherEntry(
            date: Date(),
            entry: chosen,
            metadata: MobileSnapshotStore.loadMetadata(),
            providers: entries.map(\.provider))
    }
}

// MARK: - Usage/history views

private struct HistoryWidgetView: View {
    let entry: UsageEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        if let providerEntry = entry.entry {
            VStack(alignment: .leading, spacing: 12) {
                WidgetHeader(entry: providerEntry, metadata: self.entry.metadata)
                HistoryChart(entry: providerEntry, height: self.family == .systemLarge ? 150 : 84)
                if let token = providerEntry.tokenUsage {
                    WidgetValueLine(
                        title: token.sessionLabel,
                        value: WidgetDisplay.costAndTokens(
                            cost: token.sessionCostUSD,
                            tokens: token.sessionTokens,
                            currencyCode: token.currencyCode))
                    WidgetValueLine(
                        title: token.last30DaysLabel,
                        value: WidgetDisplay.costAndTokens(
                            cost: token.last30DaysCostUSD,
                            tokens: token.last30DaysTokens,
                            currencyCode: token.currencyCode))
                }
            }
        } else {
            WidgetEmptyView()
        }
    }
}

private struct CompactWidgetView: View {
    let entry: CompactEntry

    var body: some View {
        if let providerEntry = entry.entry {
            let metric = WidgetDisplay.compactMetric(providerEntry, metric: self.entry.metric)
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    ProviderIconView(provider: providerEntry.provider, size: 28)
                    Spacer()
                    Text(providerEntry.provider.displayName)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Text(metric.value)
                    .font(.system(size: 28, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Text(metric.label)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        } else {
            WidgetEmptyView()
        }
    }
}

private struct SwitcherWidgetView: View {
    let entry: SwitcherEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        if let providerEntry = entry.entry {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 5) {
                    ForEach(entry.providers.prefix(self.family == .systemSmall ? 3 : 6), id: \.self) { provider in
                        Circle()
                            .fill(Color(hex: provider.accentHex))
                            .frame(width: provider == providerEntry.provider ? 9 : 6, height: provider == providerEntry.provider ? 9 : 6)
                            .opacity(provider == providerEntry.provider ? 1 : 0.35)
                    }
                    Spacer()
                    if self.family != .systemSmall {
                        Text(UsageFormat.relative(self.entry.metadata?.snapshotGeneratedAt ?? providerEntry.updatedAt))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                switch self.family {
                case .systemSmall:
                    SmallSwitcherContent(entry: providerEntry)
                case .systemMedium:
                    MediumSwitcherContent(entry: providerEntry)
                default:
                    LargeSwitcherContent(entry: providerEntry)
                }
            }
        } else {
            WidgetEmptyView()
        }
    }
}

private struct SmallSwitcherContent: View {
    let entry: WidgetSnapshot.ProviderEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(self.entry.provider.displayName)
                .font(.callout.weight(.semibold))
                .lineLimit(1)
            ForEach(self.entry.displayRows.prefix(2)) { row in
                CompactUsageRow(row: row)
            }
        }
    }
}

private struct MediumSwitcherContent: View {
    let entry: WidgetSnapshot.ProviderEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            WidgetHeader(entry: self.entry, metadata: nil)
            ForEach(self.entry.displayRows.prefix(3)) { row in
                CompactUsageRow(row: row)
            }
            if let token = self.entry.tokenUsage {
                WidgetValueLine(
                    title: token.sessionLabel,
                    value: WidgetDisplay.costAndTokens(
                        cost: token.sessionCostUSD,
                        tokens: token.sessionTokens,
                        currencyCode: token.currencyCode))
            }
        }
    }
}

private struct LargeSwitcherContent: View {
    let entry: WidgetSnapshot.ProviderEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            WidgetHeader(entry: self.entry, metadata: nil)
            ForEach(self.entry.displayRows.prefix(4)) { row in
                UsageRowView(row: row)
            }
            if let credits = self.entry.creditsRemaining {
                WidgetValueLine(title: "Credits", value: WidgetDisplay.credits(credits))
            }
            if let token = self.entry.tokenUsage {
                WidgetValueLine(
                    title: token.sessionLabel,
                    value: WidgetDisplay.costAndTokens(
                        cost: token.sessionCostUSD,
                        tokens: token.sessionTokens,
                        currencyCode: token.currencyCode))
                WidgetValueLine(
                    title: token.last30DaysLabel,
                    value: WidgetDisplay.costAndTokens(
                        cost: token.last30DaysCostUSD,
                        tokens: token.last30DaysTokens,
                        currencyCode: token.currencyCode))
            }
            HistoryChart(entry: self.entry, height: 58)
        }
    }
}

// MARK: - Burn-down views

private struct BurnDownWidgetView: View {
    let entry: UsageEntry

    var body: some View {
        if let providerEntry = entry.entry, let window = providerEntry.primary {
            BurnDownLayout(entry: providerEntry, window: window)
        } else {
            WidgetEmptyView()
        }
    }
}

private struct CombinedBurnDownWidgetView: View {
    let entry: UsageEntry

    var body: some View {
        if let providerEntry = entry.entry {
            VStack(alignment: .leading, spacing: 8) {
                WidgetHeader(entry: providerEntry, metadata: self.entry.metadata)
                BurnDownMiniRow(title: "Session", window: providerEntry.primary, provider: providerEntry.provider, periods: 5, showsRemaining: true)
                Divider()
                BurnDownMiniRow(title: "Weekly", window: providerEntry.secondary, provider: providerEntry.provider, periods: 7, showsRemaining: false)
            }
        } else {
            WidgetEmptyView()
        }
    }
}

private struct BurnDownLayout: View {
    let entry: WidgetSnapshot.ProviderEntry
    let window: RateWindow

    var body: some View {
        let geom = BurnGeometry(window: self.window)
        let theme = BurnTheme(provider: self.entry.provider, geometry: geom)
        let reset = BurnDisplay.effectiveReset(window: self.window, geometry: geom)
        HStack(alignment: .bottom, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                WidgetHeader(entry: self.entry, metadata: nil)
                Spacer(minLength: 2)
                BurnStatLine(title: "Resets in", value: reset.map { UsageFormat.relative($0) } ?? "—")
                BurnStatLine(title: geom.runsOut ? "Runs out in" : "Runs out", value: geom.runsOut ? BurnDisplay.duration(geom.runOutMinutes(window: self.window)) : "after reset")
                Spacer(minLength: 2)
                HStack(alignment: .lastTextBaseline, spacing: 3) {
                    Text("\(Int(geom.remaining.rounded()))")
                        .font(.system(size: 40, weight: .semibold, design: .rounded))
                        .foregroundStyle(theme.status)
                        .monospacedDigit()
                    Text("% left")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 128, alignment: .leading)
            BurnChart(geometry: geom, theme: theme)
                .frame(maxWidth: .infinity)
                .frame(height: 96)
        }
    }
}

private struct BurnDownMiniRow: View {
    let title: String
    let window: RateWindow?
    let provider: UsageProvider
    let periods: Int
    let showsRemaining: Bool

    var body: some View {
        if let window {
            let geom = BurnGeometry(window: window)
            let theme = BurnTheme(provider: self.provider, geometry: geom)
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(self.title.uppercased())
                        .font(.system(size: 9, weight: .heavy))
                        .foregroundStyle(.secondary)
                    HStack(alignment: .lastTextBaseline, spacing: 2) {
                        Text(self.showsRemaining ? "\(Int(geom.remaining.rounded()))" : "\(abs(Int(geom.margin.rounded())))")
                            .font(.system(size: 27, weight: .semibold, design: .rounded))
                            .foregroundStyle(theme.status)
                            .monospacedDigit()
                        Text("%")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Text(geom.statusText)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(theme.status)
                }
                .frame(width: 94, alignment: .leading)
                CombinedBurnChart(geometry: geom, theme: theme, periods: self.periods)
                    .frame(maxWidth: .infinity)
                    .frame(height: 54)
            }
        } else {
            Text("\(self.title): no data")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Shared pieces

struct WidgetValueLine: View {
    let title: String
    let value: String

    var body: some View {
        HStack(spacing: 6) {
            Text(self.title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(self.value)
                .font(.caption.weight(.medium))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            Spacer(minLength: 0)
        }
    }
}

struct HistoryChart: View {
    let entry: WidgetSnapshot.ProviderEntry
    let height: CGFloat

    var body: some View {
        let points = Array(self.entry.dailyUsage.suffix(14))
        let costMode = points.contains { $0.costUSD != nil }
        VStack(alignment: .leading, spacing: 4) {
            if let total = WidgetDisplay.historyTotal(points: points, costMode: costMode, currencyCode: self.entry.tokenUsage?.currencyCode) {
                Text(total)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Chart(points) { point in
                let value = WidgetDisplay.historyValue(point, costMode: costMode)
                BarMark(x: .value("Day", point.dayKey), y: .value("Usage", value))
                    .foregroundStyle(Color(hex: self.entry.provider.accentHex).opacity(0.78))
                LineMark(x: .value("Day", point.dayKey), y: .value("Usage", value))
                    .foregroundStyle(Color(hex: self.entry.provider.accentHex))
                    .lineStyle(.init(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
            }
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .frame(height: height)
        }
    }
}

private struct WidgetHeader: View {
    let entry: WidgetSnapshot.ProviderEntry
    let metadata: SyncMetadata?

    var body: some View {
        HStack(spacing: 8) {
            ProviderIconView(provider: self.entry.provider, size: 24)
            Text(self.entry.provider.displayName)
                .font(.body.weight(.semibold))
                .lineLimit(1)
            Spacer()
            Text(UsageFormat.relative(self.metadata?.snapshotGeneratedAt ?? self.entry.updatedAt))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }
}

private struct CompactUsageRow: View {
    let row: WidgetSnapshot.WidgetUsageRowSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(self.row.title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                Text(UsageFormat.percent(self.row.percentLeft))
                    .font(.caption.weight(.semibold).monospacedDigit())
            }
            UsageBar(remainingPercent: self.row.percentLeft, height: 6)
        }
    }
}

private struct BurnStatLine: View {
    let title: String
    let value: String

    var body: some View {
        HStack {
            Text(self.title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Spacer()
            Text(self.value)
                .font(.caption2.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
    }
}

enum WidgetDisplay {
    static func credits(_ value: Double) -> String {
        if value >= 1_000 { return String(format: "%.1fk", value / 1_000) }
        return String(format: value.rounded() == value ? "%.0f" : "%.1f", value)
    }

    static func costAndTokens(cost: Double?, tokens: Int?, currencyCode: String) -> String {
        [UsageFormat.currency(cost, code: currencyCode), UsageFormat.tokens(tokens)]
            .compactMap { $0 }
            .joined(separator: " · ")
    }

    static func compactMetric(
        _ entry: WidgetSnapshot.ProviderEntry,
        metric: CompactMetric) -> (value: String, label: String)
    {
        switch metric {
        case .credits:
            if let credits = entry.creditsRemaining {
                return (self.credits(credits), "Credits left")
            }
            fallthrough
        case .cost:
            if let token = entry.tokenUsage,
               let value = UsageFormat.currency(token.sessionCostUSD, code: token.currencyCode)
            {
                return (value, "\(token.sessionLabel) cost")
            }
            fallthrough
        case .sessionPercent:
            return (UsageFormat.percent(entry.headlineRemainingPercent), "Session left")
        }
    }

    static func historyValue(_ point: WidgetSnapshot.DailyUsagePoint, costMode: Bool) -> Double {
        costMode ? point.costUSD ?? 0 : Double(point.totalTokens ?? 0)
    }

    static func historyTotal(
        points: [WidgetSnapshot.DailyUsagePoint],
        costMode: Bool,
        currencyCode: String?) -> String?
    {
        guard !points.isEmpty else { return nil }
        if costMode {
            let total = points.reduce(0) { $0 + ($1.costUSD ?? 0) }
            return "\(UsageFormat.currency(total, code: currencyCode ?? "USD") ?? "$0") recent"
        }
        let total = points.reduce(0) { $0 + ($1.totalTokens ?? 0) }
        return "\(UsageFormat.tokens(total) ?? "0") tokens recent"
    }
}

// MARK: - Burn math/canvas

private struct BurnGeometry {
    enum Status { case ahead, onPace, behind }

    let remaining: Double
    let elapsed: Double
    let ideal: Double
    let margin: Double
    let slope: Double
    let projectionX: Double
    let projectionY: Double
    let runsOut: Bool

    var status: Status {
        if self.margin > 4 { return .ahead }
        if self.margin < -4 { return .behind }
        return .onPace
    }

    var statusText: String {
        switch self.status {
        case .ahead: "under pace"
        case .onPace: "on pace"
        case .behind: "over pace"
        }
    }

    init(window: RateWindow) {
        self.remaining = max(0, min(100, window.remainingPercent))
        if let resetsAt = window.resetsAt, let minutes = window.windowMinutes, minutes > 0 {
            let left = max(0, resetsAt.timeIntervalSinceNow / 60)
            self.elapsed = max(0.001, min(0.999, (Double(minutes) - left) / Double(minutes)))
        } else {
            self.elapsed = max(0.001, min(0.999, window.usedPercent / 100))
        }
        self.ideal = 100 * (1 - self.elapsed)
        self.margin = self.remaining - self.ideal
        self.slope = self.elapsed > 0.001 ? (self.remaining - 100) / self.elapsed : -self.remaining
        if self.slope < -0.01 {
            let out = self.elapsed + self.remaining / -self.slope
            self.projectionX = min(1, out)
            self.projectionY = out <= 1 ? 0 : max(0, self.remaining + self.slope * (1 - self.elapsed))
            self.runsOut = out <= 1 && self.elapsed >= 0.08
        } else {
            self.projectionX = 1
            self.projectionY = self.remaining
            self.runsOut = false
        }
    }

    func runOutMinutes(window: RateWindow) -> Double {
        guard self.slope < -0.01 else { return .infinity }
        return (self.remaining / -self.slope) * Double(window.windowMinutes ?? 300)
    }
}

private struct BurnTheme {
    let status: Color
    let line: Color
    let ideal: Color
    let grid: Color
    let ring: Color

    init(provider: UsageProvider, geometry: BurnGeometry) {
        self.status = switch geometry.status {
        case .ahead: Color(hex: "30D158")
        case .onPace: Color(hex: provider.accentHex)
        case .behind: Color(hex: "FF6A3D")
        }
        self.line = self.status
        self.ideal = .secondary.opacity(0.55)
        self.grid = .secondary.opacity(0.18)
        self.ring = Color(.systemBackground).opacity(0.9)
    }
}

private struct BurnChart: View {
    let geometry: BurnGeometry
    let theme: BurnTheme

    var body: some View {
        Canvas { context, size in
            BurnPainter.paint(context: context, size: size, geometry: self.geometry, theme: self.theme, periods: nil)
        }
    }
}

private struct CombinedBurnChart: View {
    let geometry: BurnGeometry
    let theme: BurnTheme
    let periods: Int

    var body: some View {
        Canvas { context, size in
            BurnPainter.paint(context: context, size: size, geometry: self.geometry, theme: self.theme, periods: self.periods)
        }
    }
}

private enum BurnPainter {
    static func paint(
        context: GraphicsContext,
        size: CGSize,
        geometry: BurnGeometry,
        theme: BurnTheme,
        periods: Int?)
    {
        let padTop: CGFloat = 6
        let padBottom: CGFloat = 2

        func x(_ value: Double) -> CGFloat { CGFloat(value) * size.width }
        func y(_ value: Double) -> CGFloat {
            padTop + CGFloat(1 - value / 100) * (size.height - padTop - padBottom)
        }

        if let periods, periods > 0 {
            let slot = size.width / CGFloat(periods)
            let idealHeight = (size.height - padTop - padBottom) * 0.42
            for index in 0..<periods {
                let start = CGFloat(index) * slot
                let rect = CGRect(x: start, y: size.height - padBottom - idealHeight, width: max(1, slot - 1), height: idealHeight)
                context.fill(Path(rect), with: .color(.secondary.opacity(0.07)))
            }
        }

        var nowLine = Path()
        nowLine.move(to: CGPoint(x: x(geometry.elapsed), y: y(100)))
        nowLine.addLine(to: CGPoint(x: x(geometry.elapsed), y: y(0)))
        context.stroke(nowLine, with: .color(theme.grid), lineWidth: 1)

        var ideal = Path()
        ideal.move(to: CGPoint(x: x(0), y: y(100)))
        ideal.addLine(to: CGPoint(x: x(1), y: y(0)))
        context.stroke(ideal, with: .color(theme.ideal), style: StrokeStyle(lineWidth: 1.2, dash: [3, 3]))

        if geometry.slope < -0.01 {
            var projection = Path()
            projection.move(to: CGPoint(x: x(geometry.elapsed), y: y(geometry.remaining)))
            projection.addLine(to: CGPoint(x: x(geometry.projectionX), y: y(geometry.projectionY)))
            context.stroke(projection, with: .color(theme.line.opacity(0.75)), style: StrokeStyle(lineWidth: 1.5, dash: [1, 3]))
        }

        var actual = Path()
        actual.move(to: CGPoint(x: x(0), y: y(100)))
        actual.addLine(to: CGPoint(x: x(geometry.elapsed), y: y(geometry.remaining)))
        context.stroke(actual, with: .color(theme.line), style: StrokeStyle(lineWidth: 2.4, lineCap: .round))

        let dot = CGPoint(x: x(geometry.elapsed), y: y(geometry.remaining))
        context.fill(Path(ellipseIn: CGRect(x: dot.x - 5, y: dot.y - 5, width: 10, height: 10)), with: .color(theme.ring))
        context.fill(Path(ellipseIn: CGRect(x: dot.x - 3, y: dot.y - 3, width: 6, height: 6)), with: .color(theme.line))
    }
}

private enum BurnDisplay {
    static func effectiveReset(window: RateWindow, geometry: BurnGeometry) -> Date? {
        if let resetsAt = window.resetsAt, resetsAt > Date() { return resetsAt }
        guard let minutes = window.windowMinutes else { return nil }
        return Date().addingTimeInterval((1 - geometry.elapsed) * Double(minutes) * 60)
    }

    static func duration(_ minutes: Double) -> String {
        guard minutes.isFinite, minutes > 0 else { return "—" }
        if minutes >= 1440 { return "\(Int(minutes / 1440))d \(Int(minutes / 60) % 24)h" }
        let hours = Int(minutes / 60)
        let mins = Int(minutes) % 60
        return hours > 0 ? "\(hours)h \(String(format: "%02d", mins))m" : "\(max(1, mins))m"
    }
}
