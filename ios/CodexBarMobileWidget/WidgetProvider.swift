import AppIntents
import Foundation
import WidgetKit

/// A selectable provider for widget configuration. Backed dynamically by whatever providers the
/// mirrored snapshot currently contains.
struct ProviderEntity: AppEntity {
    let id: String
    let name: String

    static var typeDisplayRepresentation: TypeDisplayRepresentation { "Provider" }
    static var defaultQuery: ProviderQuery { ProviderQuery() }

    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(self.name)") }

    var provider: UsageProvider? { UsageProvider(rawValue: self.id) }
}

struct ProviderQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [ProviderEntity] {
        Self.allProviders().filter { identifiers.contains($0.id) }
    }

    func suggestedEntities() async throws -> [ProviderEntity] {
        Self.allProviders()
    }

    func defaultResult() async -> ProviderEntity? {
        Self.allProviders().first
    }

    private static func allProviders() -> [ProviderEntity] {
        let snapshot = MobileSnapshotStore.loadSnapshot()
        let entries = snapshot?.enabledEntries ?? []
        if entries.isEmpty {
            return UsageProvider.allCases.map { ProviderEntity(id: $0.rawValue, name: $0.displayName) }
        }
        return entries.map { ProviderEntity(id: $0.provider.rawValue, name: $0.provider.displayName) }
    }
}

struct SelectProviderIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource { "Choose Provider" }
    static var description: IntentDescription { "Pick which provider this widget shows." }

    @Parameter(title: "Provider")
    var provider: ProviderEntity?
}

struct UsageEntry: TimelineEntry {
    let date: Date
    let entry: WidgetSnapshot.ProviderEntry?
    let metadata: SyncMetadata?
    let isPlaceholder: Bool

    static func placeholder(provider: UsageProvider = .codex) -> UsageEntry {
        UsageEntry(
            date: Date(),
            entry: WidgetSnapshot.ProviderEntry(
                provider: provider,
                updatedAt: Date(),
                primary: RateWindow(usedPercent: 32),
                secondary: RateWindow(usedPercent: 68),
                tertiary: nil,
                usageRows: [
                    .init(id: "primary", title: "Session", percentLeft: 68),
                    .init(id: "secondary", title: "Weekly", percentLeft: 32),
                ],
                creditsRemaining: nil,
                codeReviewRemainingPercent: nil,
                tokenUsage: nil,
                dailyUsage: []),
            metadata: nil,
            isPlaceholder: true)
    }
}

struct UsageTimelineProvider: AppIntentTimelineProvider {
    func placeholder(in _: Context) -> UsageEntry { .placeholder() }

    func snapshot(for configuration: SelectProviderIntent, in _: Context) async -> UsageEntry {
        self.currentEntry(for: configuration) ?? .placeholder()
    }

    func timeline(for configuration: SelectProviderIntent, in _: Context) async -> Timeline<UsageEntry> {
        let entry = self.currentEntry(for: configuration)
            ?? UsageEntry(date: Date(), entry: nil, metadata: MobileSnapshotStore.loadMetadata(), isPlaceholder: false)
        // Data is push-driven (LAN/CloudKit reload the timeline); refresh hourly as a safety net.
        let next = Date().addingTimeInterval(60 * 60)
        return Timeline(entries: [entry], policy: .after(next))
    }

    private func currentEntry(for configuration: SelectProviderIntent) -> UsageEntry? {
        guard let snapshot = MobileSnapshotStore.loadSnapshot() else { return nil }
        let metadata = MobileSnapshotStore.loadMetadata()
        let entries = snapshot.enabledEntries
        let chosen: WidgetSnapshot.ProviderEntry?
        if let selected = configuration.provider?.provider {
            chosen = entries.first { $0.provider == selected }
        } else {
            // Default: the provider closest to running out.
            chosen = entries.min {
                ($0.headlineRemainingPercent ?? 100) < ($1.headlineRemainingPercent ?? 100)
            }
        }
        guard let chosen else { return nil }
        return UsageEntry(date: Date(), entry: chosen, metadata: metadata, isPlaceholder: false)
    }
}
