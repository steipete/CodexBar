import SwiftUI
import WidgetKit

struct HomeUsageWidget: Widget {
    let kind = "CodexBarHomeUsageWidget"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: self.kind, intent: SelectProviderIntent.self, provider: UsageTimelineProvider()) { entry in
            HomeUsageWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Provider Usage")
        .description("At-a-glance remaining usage for a CodexBar provider.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

struct HomeUsageWidgetView: View {
    let entry: UsageEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        if let providerEntry = entry.entry {
            switch self.family {
            case .systemMedium: MediumUsageView(entry: providerEntry, metadata: self.entry.metadata)
            case .systemLarge: LargeUsageView(entry: providerEntry, metadata: self.entry.metadata)
            default: SmallUsageView(entry: providerEntry)
            }
        } else {
            WidgetEmptyView()
        }
    }
}

private struct SmallUsageView: View {
    let entry: WidgetSnapshot.ProviderEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                ProviderIconView(provider: self.entry.provider, size: 26)
                Spacer()
                UsageRing(remainingPercent: self.entry.headlineRemainingPercent, lineWidth: 5, showsLabel: false)
                    .frame(width: 30, height: 30)
            }
            Spacer()
            Text(self.entry.provider.displayName)
                .font(.callout.weight(.semibold))
                .lineLimit(1)
            if let row = self.entry.displayRows.first {
                Text("\(UsageFormat.percent(row.percentLeft)) · \(row.title)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                UsageBar(remainingPercent: row.percentLeft, height: 6)
            }
        }
    }
}

private struct MediumUsageView: View {
    let entry: WidgetSnapshot.ProviderEntry
    let metadata: SyncMetadata?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                ProviderIconView(provider: self.entry.provider, size: 30)
                Text(self.entry.provider.displayName).font(.headline)
                Spacer()
                if let metadata {
                    Text(UsageFormat.relative(metadata.snapshotGeneratedAt ?? metadata.receivedAt))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            ForEach(self.entry.displayRows.prefix(3)) { row in
                HStack(spacing: 8) {
                    Text(row.title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 64, alignment: .leading)
                    UsageBar(remainingPercent: row.percentLeft, height: 7)
                    Text(UsageFormat.percent(row.percentLeft))
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .frame(width: 42, alignment: .trailing)
                }
            }
            Spacer(minLength: 0)
        }
    }
}

private struct LargeUsageView: View {
    let entry: WidgetSnapshot.ProviderEntry
    let metadata: SyncMetadata?

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: 10) {
                ProviderIconView(provider: self.entry.provider, size: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text(self.entry.provider.displayName).font(.headline)
                    if let metadata {
                        Text(UsageFormat.relative(metadata.snapshotGeneratedAt ?? metadata.receivedAt))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                Spacer()
                UsageRing(remainingPercent: self.entry.headlineRemainingPercent, lineWidth: 7)
                    .frame(width: 58, height: 58)
            }

            ForEach(self.entry.displayRows.prefix(4)) { row in
                UsageRowView(row: row)
            }

            if let credits = entry.creditsRemaining {
                WidgetValueLine(title: "Credits", value: WidgetDisplay.credits(credits))
            }
            if let token = entry.tokenUsage {
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
            HistoryChart(entry: self.entry, height: 64)
        }
    }
}

struct WidgetEmptyView: View {
    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "antenna.radiowaves.left.and.right")
                .font(.title3)
                .foregroundStyle(.secondary)
            Text("Open CodexBar")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
