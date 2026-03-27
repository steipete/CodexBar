import AppIntents
import CodexBariOSShared
import WidgetKit

enum ProviderChoice: String, AppEnum {
    case codex
    case claude

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Provider")

    static let caseDisplayRepresentations: [ProviderChoice: DisplayRepresentation] = [
        .codex: DisplayRepresentation(title: "Codex"),
        .claude: DisplayRepresentation(title: "Claude"),
    ]

    var provider: UsageProvider {
        switch self {
        case .codex: .codex
        case .claude: .claude
        }
    }

    init(provider: UsageProvider) {
        switch provider {
        case .codex: self = .codex
        case .claude: self = .claude
        }
    }
}

struct ProviderSelectionIntent: AppIntent, WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Provider"
    static let description = IntentDescription("Select the provider shown in the widget.")

    @Parameter(title: "Provider")
    var provider: ProviderChoice?

    init() {
        self.provider = .codex
    }
}

struct SwitchWidgetProviderIntent: AppIntent {
    static let title: LocalizedStringResource = "Switch Provider"
    static let description = IntentDescription("Switch the provider shown in the widget.")

    @Parameter(title: "Provider")
    var provider: ProviderChoice

    init() {}

    init(provider: ProviderChoice) {
        self.provider = provider
    }

    func perform() async throws -> some IntentResult {
        WidgetSelectionStore.saveSelectedProvider(self.provider.provider)
        WidgetCenter.shared.reloadAllTimelines()
        return .result()
    }
}

struct UsageWidgetEntry: TimelineEntry {
    let date: Date
    let provider: UsageProvider
    let snapshot: WidgetSnapshot
}

struct SwitcherWidgetEntry: TimelineEntry {
    let date: Date
    let provider: UsageProvider
    let availableProviders: [UsageProvider]
    let snapshot: WidgetSnapshot
}

struct UsageTimelineProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> UsageWidgetEntry {
        UsageWidgetEntry(date: Date(), provider: .codex, snapshot: WidgetPreviewData.snapshot())
    }

    func snapshot(for configuration: ProviderSelectionIntent, in context: Context) async -> UsageWidgetEntry {
        UsageWidgetEntry(
            date: Date(),
            provider: configuration.provider?.provider ?? .codex,
            snapshot: WidgetSnapshotStore.load() ?? WidgetPreviewData.snapshot())
    }

    func timeline(for configuration: ProviderSelectionIntent, in context: Context) async -> Timeline<UsageWidgetEntry> {
        let snapshot = WidgetSnapshotStore.load() ?? WidgetPreviewData.snapshot()
        let entry = UsageWidgetEntry(
            date: Date(),
            provider: configuration.provider?.provider ?? .codex,
            snapshot: snapshot)
        return Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(15 * 60)))
    }
}

struct SwitcherTimelineProvider: TimelineProvider {
    func placeholder(in context: Context) -> SwitcherWidgetEntry {
        let snapshot = WidgetPreviewData.snapshot()
        return SwitcherWidgetEntry(
            date: Date(),
            provider: .codex,
            availableProviders: [.codex, .claude],
            snapshot: snapshot)
    }

    func getSnapshot(in context: Context, completion: @escaping (SwitcherWidgetEntry) -> Void) {
        completion(self.makeEntry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<SwitcherWidgetEntry>) -> Void) {
        completion(Timeline(entries: [self.makeEntry()], policy: .after(Date().addingTimeInterval(15 * 60))))
    }

    private func makeEntry() -> SwitcherWidgetEntry {
        let snapshot = WidgetSnapshotStore.load() ?? WidgetPreviewData.snapshot()
        let providers = snapshot.enabledProviders.isEmpty ? [.codex, .claude] : snapshot.enabledProviders
        let selected = WidgetSelectionStore.loadSelectedProvider() ?? providers.first ?? .codex
        return SwitcherWidgetEntry(
            date: Date(),
            provider: providers.contains(selected) ? selected : providers.first ?? .codex,
            availableProviders: providers,
            snapshot: snapshot)
    }
}
