import CodexBariOSShared
import SwiftUI
import WidgetKit

private let widgetAppURL = URL(string: "codexbarios://dashboard")!

struct UsageWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: UsageWidgetEntry

    var body: some View {
        ZStack {
            WidgetBackground()

            if let providerEntry = self.entry.snapshot.entries.first(where: { $0.provider == self.entry.provider }) {
                ProviderUsageContent(entry: providerEntry, family: self.family, availableProviders: nil)
            } else {
                EmptyWidgetState()
            }
        }
        .containerBackground(.fill.tertiary, for: .widget)
        .widgetURL(widgetAppURL)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct SwitcherWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: SwitcherWidgetEntry

    var body: some View {
        ZStack {
            WidgetBackground()

            if let providerEntry = self.entry.snapshot.entries.first(where: { $0.provider == self.entry.provider }) {
                ProviderUsageContent(
                    entry: providerEntry,
                    family: self.family,
                    availableProviders: self.entry.availableProviders)
            } else {
                EmptyWidgetState()
            }
        }
        .containerBackground(.fill.tertiary, for: .widget)
        .widgetURL(widgetAppURL)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct ProviderUsageContent: View {
    let entry: WidgetSnapshot.ProviderEntry
    let family: WidgetFamily
    let availableProviders: [UsageProvider]?

    var body: some View {
        if let availableProviders {
            switch self.family {
            case .systemSmall:
                CompactSwitcherCard(entry: self.entry, availableProviders: availableProviders)
            default:
                ExpandedSwitcherCard(entry: self.entry, family: self.family, availableProviders: availableProviders)
            }
        } else {
            switch self.family {
            case .systemSmall:
                CompactUsageCard(entry: self.entry)
            default:
                ExpandedUsageCard(entry: self.entry, family: self.family)
            }
        }
    }
}

private struct CompactUsageCard: View {
    let entry: WidgetSnapshot.ProviderEntry

    private var accent: Color {
        WidgetColors.color(for: self.entry.provider)
    }

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Spacer(minLength: 0)
                TimestampText(updatedAt: self.entry.updatedAt)
            }

            CompactHeroGauge(
                title: "Session",
                value: self.entry.primaryMetricValue,
                subtitle: self.entry.primaryMetricSubtitle,
                session: self.entry.sessionWindow,
                weekly: self.entry.weeklyWindow,
                accent: self.accent)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 10)
    }
}

private struct CompactSwitcherCard: View {
    let entry: WidgetSnapshot.ProviderEntry
    let availableProviders: [UsageProvider]

    private var accent: Color {
        WidgetColors.color(for: self.entry.provider)
    }

    var body: some View {
        VStack(spacing: 4) {
            ProviderSwitcherRow(
                providers: self.availableProviders,
                selected: self.entry.provider,
                updatedAt: self.entry.updatedAt,
                compact: true,
                showsTimestamp: false)

            CompactHeroGauge(
                title: "Session",
                value: self.entry.primaryMetricValue,
                subtitle: nil,
                session: self.entry.sessionWindow,
                weekly: self.entry.weeklyWindow,
                accent: self.accent,
                compact: true)

            if let reset = self.entry.primaryMetricSubtitle {
                Text(reset)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.65)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }
}

private struct ExpandedUsageCard: View {
    let entry: WidgetSnapshot.ProviderEntry
    let family: WidgetFamily

    private var accent: Color {
        WidgetColors.color(for: self.entry.provider)
    }

    var body: some View {
        Group {
            if self.family == .systemMedium {
                MediumUsageCard(entry: self.entry, accent: self.accent)
            } else {
                LargeUsageCard(entry: self.entry, accent: self.accent)
            }
        }
    }
}

private struct ExpandedSwitcherCard: View {
    let entry: WidgetSnapshot.ProviderEntry
    let family: WidgetFamily
    let availableProviders: [UsageProvider]

    private var accent: Color {
        WidgetColors.color(for: self.entry.provider)
    }

    var body: some View {
        Group {
            if self.family == .systemMedium {
                MediumSwitcherCard(
                    entry: self.entry,
                    accent: self.accent,
                    availableProviders: self.availableProviders)
            } else {
                LargeSwitcherCard(
                    entry: self.entry,
                    accent: self.accent,
                    availableProviders: self.availableProviders)
            }
        }
    }
}

private struct MediumUsageCard: View {
    let entry: WidgetSnapshot.ProviderEntry
    let accent: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            WidgetHeader(
                provider: self.entry.provider,
                updatedAt: self.entry.updatedAt,
                compact: false,
                subtitle: nil)

            HStack(alignment: .center, spacing: 16) {
                ConcentricUsageRings(
                    session: self.entry.sessionWindow,
                    weekly: self.entry.weeklyWindow,
                    accent: self.accent,
                    size: 88,
                    sessionLineWidth: 13,
                    weeklyLineWidth: 9)
                .frame(width: 88, height: 88)

                MetricSummaryColumn(rows: self.entry.widgetMetricRows)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }
}

private struct MediumSwitcherCard: View {
    let entry: WidgetSnapshot.ProviderEntry
    let accent: Color
    let availableProviders: [UsageProvider]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ProviderSwitcherRow(
                providers: self.availableProviders,
                selected: self.entry.provider,
                updatedAt: self.entry.updatedAt,
                compact: false,
                showsTimestamp: true)

            HStack(alignment: .center, spacing: 16) {
                ConcentricUsageRings(
                    session: self.entry.sessionWindow,
                    weekly: self.entry.weeklyWindow,
                    accent: self.accent,
                    size: 88,
                    sessionLineWidth: 13,
                    weeklyLineWidth: 9)
                .frame(width: 88, height: 88)

                MetricSummaryColumn(rows: self.entry.widgetMetricRows)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }
}

private struct LargeUsageCard: View {
    let entry: WidgetSnapshot.ProviderEntry
    let accent: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            WidgetHeader(
                provider: self.entry.provider,
                updatedAt: self.entry.updatedAt,
                compact: false,
                subtitle: "Remaining quota")

            MetricProgressStack(rows: self.entry.largeWidgetMetricRows, accent: self.accent)

            if !self.entry.dailyUsage.isEmpty {
                DailyUsageSparkline(points: self.entry.dailyUsage, accent: self.accent)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 16)
    }
}

private struct LargeSwitcherCard: View {
    let entry: WidgetSnapshot.ProviderEntry
    let accent: Color
    let availableProviders: [UsageProvider]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ProviderSwitcherRow(
                providers: self.availableProviders,
                selected: self.entry.provider,
                updatedAt: self.entry.updatedAt,
                compact: false,
                showsTimestamp: true)

            MetricProgressStack(rows: self.entry.largeWidgetMetricRows, accent: self.accent)

            if !self.entry.dailyUsage.isEmpty {
                DailyUsageSparkline(points: self.entry.dailyUsage, accent: self.accent)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 16)
    }
}

private struct ConcentricUsageRings: View {
    let session: RateWindow?
    let weekly: RateWindow?
    let accent: Color
    let size: CGFloat
    let sessionLineWidth: CGFloat
    let weeklyLineWidth: CGFloat

    var body: some View {
        ZStack {
            RingLayer(progress: self.ratio(for: self.session), lineWidth: self.sessionLineWidth, color: self.accent)
            RingLayer(progress: self.ratio(for: self.weekly), lineWidth: self.weeklyLineWidth, color: self.accent.opacity(0.5))
                .padding(self.sessionLineWidth + 2)
        }
        .frame(width: self.size, height: self.size)
    }

    private func ratio(for window: RateWindow?) -> Double {
        guard let window else { return 0 }
        return min(max(window.remainingPercent / 100, 0), 1)
    }
}

private struct RingLayer: View {
    let progress: Double
    let lineWidth: CGFloat
    let color: Color

    var body: some View {
        Circle()
            .stroke(Color.primary.opacity(0.08), lineWidth: self.lineWidth)
            .overlay {
                Circle()
                    .trim(from: 0, to: self.progress)
                    .stroke(
                        self.color,
                        style: StrokeStyle(lineWidth: self.lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
    }
}

private struct CompactHeroGauge: View {
    let title: String
    let value: String
    let subtitle: String?
    let session: RateWindow?
    let weekly: RateWindow?
    let accent: Color
    var compact: Bool = false

    private var ringSize: CGFloat { self.compact ? 100 : 124 }
    private var sessionLine: CGFloat { self.compact ? 12 : 14 }
    private var weeklyLine: CGFloat { self.compact ? 8 : 10 }
    private static let ringGap: CGFloat = 2

    var body: some View {
        ZStack {
            ConcentricUsageRings(
                session: self.session,
                weekly: self.weekly,
                accent: self.accent,
                size: self.ringSize,
                sessionLineWidth: self.sessionLine,
                weeklyLineWidth: self.weeklyLine)

            VStack(spacing: self.compact ? 1 : 2) {
                Text(self.title)
                    .font(.system(size: self.compact ? 10 : 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text(self.value)
                    .font(.system(size: self.compact ? 22 : 28, weight: .bold, design: .rounded))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.55)
                }
            }
            .multilineTextAlignment(.center)
            .frame(maxWidth: self.ringSize - 2 * (self.sessionLine + Self.ringGap + self.weeklyLine) - 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct MetricSummaryColumn: View {
    let rows: [MetricRowModel]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(self.rows) { row in
                MetricSummaryRow(row: row)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct MetricSummaryRow: View {
    let row: MetricRowModel

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(self.row.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Spacer(minLength: 6)
                Text(self.row.value)
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
            }

            if let subtitle = self.row.subtitle {
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
            }
        }
    }
}

private struct MetricProgressStack: View {
    let rows: [MetricRowModel]
    let accent: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            ForEach(self.rows) { row in
                MetricProgressRow(row: row, accent: self.accent)
            }
        }
    }
}

private struct MetricProgressRow: View {
    let row: MetricRowModel
    let accent: Color

    private static let titleWidth: CGFloat = 56
    private static let titleBarSpacing: CGFloat = 10

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: Self.titleBarSpacing) {
                Text(self.row.title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(minWidth: Self.titleWidth, alignment: .leading)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)

                if self.row.progress != nil {
                    MetricProgressBar(progress: self.row.progress ?? 0, accent: self.accent)
                } else {
                    Spacer(minLength: 4)
                }

                Text(self.row.value)
                    .font(.system(size: 17, weight: .bold, design: .rounded))
                    .foregroundStyle(.primary)
                    .frame(minWidth: 76, alignment: .trailing)
                    .lineLimit(1)
                    .minimumScaleFactor(0.68)
            }

            if let subtitle = self.row.subtitle {
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.76)
                    .padding(.leading, Self.titleWidth + Self.titleBarSpacing)
            }
        }
    }
}

private struct MetricProgressBar: View {
    let progress: Double
    let accent: Color

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(0.08))

                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [self.accent.opacity(0.96), self.accent.opacity(0.78)],
                            startPoint: .leading,
                            endPoint: .trailing))
                    .frame(width: proxy.size.width * max(min(self.progress, 1), 0))
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 16)
    }
}

private struct DailyUsageSparkline: View {
    let points: [WidgetSnapshot.DailyUsagePoint]
    let accent: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Recent usage")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)

            GeometryReader { proxy in
                let values = self.normalizedValues
                let barWidth = max(4, (proxy.size.width - CGFloat(max(values.count - 1, 0)) * 3) / CGFloat(max(values.count, 1)))
                HStack(alignment: .bottom, spacing: 3) {
                    ForEach(Array(values.enumerated()), id: \.offset) { _, value in
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [self.accent.opacity(0.85), self.accent.opacity(0.5)],
                                    startPoint: .top,
                                    endPoint: .bottom))
                            .frame(width: barWidth, height: max(3, proxy.size.height * value))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            }
            .frame(height: 48)

            if let lastDay = self.points.last {
                HStack {
                    Text(self.dayLabel(lastDay.dayKey))
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                    Spacer()
                    if let cost = lastDay.costUSD {
                        Text(DisplayFormat.usd(cost))
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary)
                    } else if let tokens = lastDay.totalTokens {
                        Text(DisplayFormat.tokenCount(tokens))
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var normalizedValues: [Double] {
        let raw: [Double] = self.points.suffix(7).map { point in
            if let cost = point.costUSD { return cost }
            if let tokens = point.totalTokens { return Double(tokens) }
            return 0
        }
        let maxVal = raw.max() ?? 1
        guard maxVal > 0 else { return raw.map { _ in 0.0 } }
        return raw.map { $0 / maxVal }
    }

    private func dayLabel(_ key: String) -> String {
        let parts = key.split(separator: "-")
        guard parts.count >= 2 else { return key }
        return "\(parts[parts.count - 2])/\(parts.last ?? "")"
    }
}

private struct MetricRowModel: Identifiable {
    let title: String
    let value: String
    let subtitle: String?

    let progress: Double?

    var id: String {
        self.title
    }
}

private struct EmptyWidgetState: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Open CodexBar iOS")
                .font(.body.weight(.semibold))
            Text("Sign in once in the app, then refresh to populate the widget.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(14)
    }
}

private struct ProviderSwitcherRow: View {
    let providers: [UsageProvider]
    let selected: UsageProvider
    let updatedAt: Date
    let compact: Bool
    let showsTimestamp: Bool

    var body: some View {
        HStack(spacing: self.compact ? 6 : 10) {
            HStack(spacing: self.compact ? 3 : 3) {
                ForEach(self.providers, id: \.self) { provider in
                    ProviderSwitchChip(
                        provider: provider,
                        selected: provider == self.selected,
                        compact: self.compact)
                }
            }
            .padding(self.compact ? 2 : 4)
            .background(Capsule().fill(Color.primary.opacity(0.06)))
            .overlay(
                Capsule()
                    .stroke(Color.primary.opacity(0.05), lineWidth: 1))

            if self.showsTimestamp {
                Spacer(minLength: self.compact ? 4 : 8)
                TimestampText(updatedAt: self.updatedAt)
            }
        }
    }
}

private struct ProviderSwitchChip: View {
    let provider: UsageProvider
    let selected: Bool
    let compact: Bool

    var body: some View {
        Button(intent: SwitchWidgetProviderIntent(provider: ProviderChoice(provider: self.provider))) {
            Text(self.provider.displayName)
                .font(self.compact ? .caption2.weight(.semibold) : .caption.weight(.semibold))
                .foregroundStyle(self.selected ? Color.primary : Color.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
                .frame(minWidth: self.compact ? nil : 52)
                .padding(.horizontal, self.compact ? 6 : 10)
                .padding(.vertical, self.compact ? 4 : 6)
                .background(
                    Capsule()
                        .fill(self.selected ? WidgetColors.color(for: self.provider).opacity(0.18) : .clear))
                .overlay(
                    Capsule()
                        .stroke(self.selected ? WidgetColors.color(for: self.provider).opacity(0.14) : .clear, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

private struct ProviderBadge: View {
    let provider: UsageProvider
    let compact: Bool

    var body: some View {
        Text(self.provider.displayName)
            .font(self.compact ? .caption2.weight(.semibold) : .caption.weight(.semibold))
            .foregroundStyle(.primary)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .padding(.horizontal, self.compact ? 8 : 10)
            .padding(.vertical, self.compact ? 5 : 6)
            .background(
                Capsule()
                    .fill(WidgetColors.color(for: self.provider).opacity(0.16)))
    }
}

private struct TimestampText: View {
    let updatedAt: Date

    var body: some View {
        Text(DisplayFormat.updateTimestamp(self.updatedAt))
            .font(.caption2.weight(.medium))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .minimumScaleFactor(0.78)
            .monospacedDigit()
    }
}

private struct WidgetHeader: View {
    let provider: UsageProvider
    let updatedAt: Date
    let compact: Bool
    let subtitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: self.compact ? 4 : 6) {
            HStack(alignment: .center) {
                ProviderBadge(provider: self.provider, compact: self.compact)
                Spacer(minLength: 8)
                TimestampText(updatedAt: self.updatedAt)
            }

            if let subtitle {
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
        }
    }
}

private struct WidgetBackground: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        LinearGradient(
            colors: [
                Color(uiColor: self.colorScheme == .dark ? .secondarySystemBackground : .systemBackground),
                Color(uiColor: self.colorScheme == .dark ? .tertiarySystemBackground : .secondarySystemBackground),
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing)
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(Color.white.opacity(self.colorScheme == .dark ? 0.06 : 0.22), lineWidth: 1)
        }
        .overlay(alignment: .top) {
            LinearGradient(
                colors: [
                    Color.white.opacity(self.colorScheme == .dark ? 0.06 : 0.16),
                    .clear,
                ],
                startPoint: .top,
                endPoint: .bottom)
                .frame(height: 56)
                .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        }
    }
}

private enum WidgetColors {
    static func color(for provider: UsageProvider) -> Color {
        switch provider {
        case .codex:
            Color(red: 73 / 255, green: 163 / 255, blue: 176 / 255)
        case .claude:
            Color(red: 204 / 255, green: 124 / 255, blue: 94 / 255)
        }
    }
}

private func compactPercent(_ value: Double?) -> String {
    guard let value else { return "--" }
    return "\(Int(value.rounded()))%"
}

private func normalizedPercent(_ value: Double?) -> Double? {
    guard let value else { return nil }
    return min(max(value / 100, 0), 1)
}

private func normalizedFraction(_ value: Double?, total: Double) -> Double? {
    guard let value, total > 0 else { return nil }
    return min(max(value / total, 0), 1)
}

private extension WidgetSnapshot.ProviderEntry {
    var primaryMetricValue: String {
        compactPercent(self.sessionWindow?.remainingPercent)
    }

    var primaryMetricSubtitle: String? {
        self.sessionWindow.flatMap(DisplayFormat.resetLine)
    }

    var widgetMetricRows: [MetricRowModel] {
        var rows: [MetricRowModel] = [
            MetricRowModel(
                title: "Session",
                value: compactPercent(self.sessionWindow?.remainingPercent),
                subtitle: self.sessionWindow.flatMap(DisplayFormat.resetLine),
                progress: normalizedPercent(self.sessionWindow?.remainingPercent)),
            MetricRowModel(
                title: "Week",
                value: compactPercent(self.weeklyWindow?.remainingPercent),
                subtitle: self.weeklyWindow.flatMap(DisplayFormat.resetLine),
                progress: normalizedPercent(self.weeklyWindow?.remainingPercent)),
        ]

        if let credits = self.creditsRemaining {
            rows.append(
                MetricRowModel(
                    title: "Credits",
                    value: DisplayFormat.credits(credits),
                    subtitle: nil,
                    progress: normalizedFraction(credits, total: 1000)))
        } else if let tertiary = self.tertiary, self.secondary != nil {
            rows.append(
                MetricRowModel(
                    title: "Extra",
                    value: compactPercent(tertiary.remainingPercent),
                    subtitle: DisplayFormat.resetLine(for: tertiary),
                    progress: normalizedPercent(tertiary.remainingPercent)))
        }

        return rows
    }

    var largeWidgetMetricRows: [MetricRowModel] {
        var rows = self.widgetMetricRows

        if let codeReview = self.codeReviewRemainingPercent {
            rows.append(
                MetricRowModel(
                    title: "Review",
                    value: compactPercent(codeReview),
                    subtitle: nil,
                    progress: normalizedPercent(codeReview)))
        }

        if let tokenUsage {
            if let sessionCost = tokenUsage.sessionCostUSD {
                rows.append(
                    MetricRowModel(
                        title: "Cost",
                        value: DisplayFormat.usd(sessionCost),
                        subtitle: tokenUsage.sessionTokens.map { "Session: \(DisplayFormat.tokenCount($0)) tokens" },
                        progress: nil))
            }
            if let last30DaysCost = tokenUsage.last30DaysCostUSD {
                rows.append(
                    MetricRowModel(
                        title: "30-day",
                        value: DisplayFormat.usd(last30DaysCost),
                        subtitle: tokenUsage.last30DaysTokens.map { "\(DisplayFormat.tokenCount($0)) tokens" },
                        progress: nil))
            }
        }

        return rows
    }

    var sessionWindow: RateWindow? {
        self.primary
    }

    var weeklyWindow: RateWindow? {
        self.secondary ?? self.tertiary
    }
}
