import AppIntents
import CodexBariOSShared
import SwiftUI
import WidgetKit

enum ProviderChoice: String, AppEnum {
    case codex
    case claude
    case gemini
    case cursor
    case copilot
    case minimax
    case opencode
    case zai

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Provider")

    static let caseDisplayRepresentations: [ProviderChoice: DisplayRepresentation] = [
        .codex: .init(title: "Codex"),
        .claude: .init(title: "Claude"),
        .gemini: .init(title: "Gemini"),
        .cursor: .init(title: "Cursor"),
        .copilot: .init(title: "Copilot"),
        .minimax: .init(title: "MiniMax"),
        .opencode: .init(title: "OpenCode"),
        .zai: .init(title: "z.ai"),
    ]
}

struct ProviderSelectionIntent: AppIntent, WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Provider"
    static let description = IntentDescription("Select which provider appears in the widget.")

    @Parameter(title: "Provider")
    var provider: ProviderChoice

    init() {
        self.provider = .codex
    }
}

struct CodexBariOSWidgetEntry: TimelineEntry {
    let date: Date
    let providerID: String
    let snapshot: iOSWidgetSnapshot
}

struct CodexBariOSWidgetTimelineProvider: AppIntentTimelineProvider {
    func placeholder(in _: Context) -> CodexBariOSWidgetEntry {
        CodexBariOSWidgetEntry(
            date: Date(),
            providerID: "codex",
            snapshot: iOSWidgetPreviewData.snapshot())
    }

    func snapshot(for configuration: ProviderSelectionIntent, in _: Context) async -> CodexBariOSWidgetEntry {
        let snapshot = iOSWidgetSnapshotStore.load() ?? iOSWidgetPreviewData.snapshot()
        return CodexBariOSWidgetEntry(
            date: Date(),
            providerID: snapshot.selectedProviderID(preferred: configuration.provider.rawValue) ?? "codex",
            snapshot: snapshot)
    }

    func timeline(
        for configuration: ProviderSelectionIntent,
        in _: Context) async -> Timeline<CodexBariOSWidgetEntry>
    {
        let snapshot = iOSWidgetSnapshotStore.load() ?? iOSWidgetPreviewData.snapshot()
        let entry = CodexBariOSWidgetEntry(
            date: Date(),
            providerID: snapshot.selectedProviderID(preferred: configuration.provider.rawValue) ?? "codex",
            snapshot: snapshot)
        let refreshDate = Date().addingTimeInterval(30 * 60)
        return Timeline(entries: [entry], policy: .after(refreshDate))
    }
}

struct CodexBariOSUsageWidget: Widget {
    private let kind = "CodexBariOSUsageWidget"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(
            kind: self.kind,
            intent: ProviderSelectionIntent.self,
            provider: CodexBariOSWidgetTimelineProvider())
        { entry in
            CodexBariOSUsageWidgetView(entry: entry)
        }
        .configurationDisplayName("CodexBar Usage")
        .description("Session and weekly usage for your selected provider.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

private struct CodexBariOSUsageWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: CodexBariOSWidgetEntry

    private var summary: iOSWidgetSnapshot.ProviderSummary? {
        self.entry.snapshot.providerSummaries.first { $0.providerID == self.entry.providerID }
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.02)
            if let summary {
                self.content(summary: summary)
            } else {
                self.emptyState
            }
        }
        .containerBackground(.fill.tertiary, for: .widget)
    }

    @ViewBuilder
    private func content(summary: iOSWidgetSnapshot.ProviderSummary) -> some View {
        switch self.family {
        case .systemSmall:
            VStack(alignment: .leading, spacing: 8) {
                self.header(summary: summary)
                UsageBarRow(title: "Session", percentLeft: summary.sessionRemainingPercent)
                UsageBarRow(title: "Weekly", percentLeft: summary.weeklyRemainingPercent)
                if let credits = summary.creditsRemaining {
                    ValueLine(title: "Credits", value: Self.decimal(credits))
                }
            }
            .padding(12)
        default:
            VStack(alignment: .leading, spacing: 10) {
                self.header(summary: summary)
                UsageBarRow(title: "Session", percentLeft: summary.sessionRemainingPercent)
                UsageBarRow(title: "Weekly", percentLeft: summary.weeklyRemainingPercent)
                ValueLine(title: "Today", value: summary.todayCostUSD.map(Self.usd) ?? "—")
                ValueLine(title: "30d", value: summary.last30DaysCostUSD.map(Self.usd) ?? "—")
                if let credits = summary.creditsRemaining {
                    ValueLine(title: "Credits", value: Self.decimal(credits))
                }
            }
            .padding(12)
        }
    }

    private func header(summary: iOSWidgetSnapshot.ProviderSummary) -> some View {
        HStack {
            Text(summary.displayName)
                .font(.body.weight(.semibold))
            Spacer()
            Text(Self.relative(summary.updatedAt))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Open CodexBar")
                .font(.body.weight(.semibold))
            Text("Import a widget snapshot in the app first.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(12)
    }

    private static func relative(_ value: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: value, relativeTo: Date())
    }

    private static func usd(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = "USD"
        formatter.maximumFractionDigits = 2
        formatter.minimumFractionDigits = 2
        return formatter.string(from: NSNumber(value: value)) ?? String(format: "$%.2f", value)
    }

    private static func decimal(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 2
        formatter.minimumFractionDigits = 0
        return formatter.string(from: NSNumber(value: value)) ?? String(format: "%.2f", value)
    }
}

private struct UsageBarRow: View {
    let title: String
    let percentLeft: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(self.title)
                    .font(.caption)
                Spacer()
                Text(self.percentLeft.map { String(format: "%.0f%%", $0) } ?? "—")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            GeometryReader { proxy in
                let ratio = max(0, min(100, self.percentLeft ?? 0)) / 100
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.12))
                    Capsule().fill(Color.accentColor).frame(width: proxy.size.width * ratio)
                }
            }
            .frame(height: 6)
        }
    }
}

private struct ValueLine: View {
    let title: String
    let value: String

    var body: some View {
        HStack(spacing: 6) {
            Text(self.title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(self.value)
                .font(.caption)
        }
    }
}
