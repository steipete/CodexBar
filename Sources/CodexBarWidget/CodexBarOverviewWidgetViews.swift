import CodexBarCore
import SwiftUI
import WidgetKit

/// Combined multi-provider tile, mirroring the menu bar's merged-icon Overview: one compact
/// row per enabled provider (name + session/weekly bars) instead of a single-provider widget.
struct CodexBarOverviewEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot
}

struct CodexBarOverviewTimelineProvider: TimelineProvider {
    // ponytail: fixed per-family cap, not wired to the menu bar's configurable
    // mergedOverviewProviderLimit (that setting lives in UserDefaults.standard,
    // not the shared app-group suite, so the widget extension can't read it).
    // Upgrade path: move that setting to AppGroupSupport.sharedDefaults() if the
    // widget should track it exactly.
    private static let mediumProviderLimit = 2
    private static let largeProviderLimit = 4

    static func providerLimit(for family: WidgetFamily) -> Int {
        family == .systemLarge ? Self.largeProviderLimit : Self.mediumProviderLimit
    }

    func placeholder(in context: Context) -> CodexBarOverviewEntry {
        CodexBarOverviewEntry(date: Date(), snapshot: WidgetPreviewData.snapshot())
    }

    func getSnapshot(in context: Context, completion: @escaping (CodexBarOverviewEntry) -> Void) {
        completion(self.makeEntry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<CodexBarOverviewEntry>) -> Void) {
        let entry = self.makeEntry()
        let refresh = Self.nextRefresh(snapshot: entry.snapshot, now: entry.date)
        completion(Timeline(entries: [entry], policy: .after(refresh)))
    }

    private func makeEntry() -> CodexBarOverviewEntry {
        CodexBarOverviewEntry(date: Date(), snapshot: WidgetSnapshotStore.load() ?? WidgetPreviewData.emptySnapshot())
    }

    private static let maximumInterval: TimeInterval = 30 * 60

    private static func nextRefresh(snapshot: WidgetSnapshot, now: Date) -> Date {
        let fallback = now.addingTimeInterval(self.maximumInterval)
        let nextReset = snapshot.entries
            .flatMap { [$0.primary?.resetsAt, $0.secondary?.resetsAt] }
            .compactMap(\.self)
            .filter { $0 > now }
            .min()?
            .addingTimeInterval(1)
        return min(fallback, nextReset ?? fallback)
    }
}

struct CodexBarOverviewWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: CodexBarOverviewEntry

    var body: some View {
        let providers = Array(self.entry.snapshot.enabledProviders
            .prefix(CodexBarOverviewTimelineProvider.providerLimit(for: self.family)))
        let rows = providers.compactMap { provider in
            self.entry.snapshot.entries.first { $0.provider == provider }
        }

        Group {
            if rows.isEmpty {
                self.emptyState
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(rows, id: \.provider) { providerEntry in
                        OverviewProviderRow(entry: providerEntry)
                    }
                }
                .padding(12)
            }
        }
        .containerBackground(.fill.tertiary, for: .widget)
        .environment(\.widgetUsageShowsUsed, self.entry.snapshot.usageBarsShowUsed)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Open CodexBar")
                .font(.body)
                .fontWeight(.semibold)
            Text("Usage data will appear once the app refreshes.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(12)
    }
}

private struct OverviewProviderRow: View {
    let entry: WidgetSnapshot.ProviderEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Circle()
                    .fill(WidgetColors.color(for: self.entry.provider))
                    .frame(width: 7, height: 7)
                Text(ProviderDefaults.metadata[self.entry.provider]?.displayName
                    ?? self.entry.provider.rawValue.capitalized)
                    .font(.caption.weight(.semibold))
            }
            // Antigravity's Gemini and Claude/GPT pools each carry their own 5h + weekly
            // window — give it room for all 4 instead of the usual 2-row cap.
            ForEach(WidgetUsageRow.rows(for: self.entry, limit: self.entry.provider == .antigravity ? 4 : 2)) { row in
                UsageBarRow(
                    title: row.title,
                    percentLeft: row.percentLeft,
                    color: WidgetColors.color(for: self.entry.provider),
                    resetsAt: row.resetsAt)
            }
        }
    }
}
