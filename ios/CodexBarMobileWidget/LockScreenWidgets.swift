import SwiftUI
import WidgetKit

/// Lock Screen / StandBy accessory widget: circular gauge, rectangular summary, and inline text.
struct LockScreenUsageWidget: Widget {
    let kind = "CodexBarLockScreenUsageWidget"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: self.kind, intent: SelectProviderIntent.self, provider: UsageTimelineProvider()) { entry in
            LockScreenUsageView(entry: entry)
                .containerBackground(.clear, for: .widget)
        }
        .configurationDisplayName("Usage (Lock Screen)")
        .description("Remaining usage on your Lock Screen.")
        .supportedFamilies([.accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}

struct LockScreenUsageView: View {
    let entry: UsageEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        if let providerEntry = entry.entry {
            switch self.family {
            case .accessoryInline:
                Text("\(providerEntry.provider.displayName) \(UsageFormat.percent(providerEntry.headlineRemainingPercent))")
            case .accessoryRectangular:
                RectangularAccessoryView(entry: providerEntry)
            default:
                CircularAccessoryView(entry: providerEntry)
            }
        } else {
            switch self.family {
            case .accessoryInline: Text("CodexBar —")
            default: Image(systemName: "antenna.radiowaves.left.and.right")
            }
        }
    }
}

private struct CircularAccessoryView: View {
    let entry: WidgetSnapshot.ProviderEntry

    var body: some View {
        Gauge(value: (self.entry.headlineRemainingPercent ?? 0) / 100) {
            Text(self.entry.provider.displayName.prefix(3).uppercased())
        } currentValueLabel: {
            Text("\(Int((self.entry.headlineRemainingPercent ?? 0).rounded()))")
        }
        .gaugeStyle(.accessoryCircular)
        .widgetAccentable()
    }
}

private struct RectangularAccessoryView: View {
    let entry: WidgetSnapshot.ProviderEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Image(systemName: "cpu")
                    .font(.caption2)
                Text(self.entry.provider.displayName)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
            }
            .widgetAccentable()
            ForEach(self.entry.displayRows.prefix(2)) { row in
                HStack(spacing: 4) {
                    Text(row.title).font(.caption2).foregroundStyle(.secondary)
                    Gauge(value: (row.percentLeft ?? 0) / 100) { EmptyView() }
                        .gaugeStyle(.accessoryLinearCapacity)
                    Text(UsageFormat.percent(row.percentLeft)).font(.caption2.monospacedDigit())
                }
            }
        }
    }
}
