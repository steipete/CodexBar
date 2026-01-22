import AppIntents
import CodexBarCore
import SwiftUI
import WidgetKit

enum ProviderChoice: String, AppEnum {
    case codex
    case claude
    case gemini
    case antigravity
    case zai
    case copilot
    case minimax
    case opencode

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Provider")

    static let caseDisplayRepresentations: [ProviderChoice: DisplayRepresentation] = [
        .codex: DisplayRepresentation(title: "Codex"),
        .claude: DisplayRepresentation(title: "Claude"),
        .gemini: DisplayRepresentation(title: "Gemini"),
        .antigravity: DisplayRepresentation(title: "Antigravity"),
        .zai: DisplayRepresentation(title: "z.ai"),
        .copilot: DisplayRepresentation(title: "Copilot"),
        .minimax: DisplayRepresentation(title: "MiniMax"),
        .opencode: DisplayRepresentation(title: "OpenCode"),
    ]

    var provider: UsageProvider {
        switch self {
        case .codex: .codex
        case .claude: .claude
        case .gemini: .gemini
        case .antigravity: .antigravity
        case .zai: .zai
        case .copilot: .copilot
        case .minimax: .minimax
        case .opencode: .opencode
        }
    }

    init?(provider: UsageProvider) {
        switch provider {
        case .codex: self = .codex
        case .claude: self = .claude
        case .gemini: self = .gemini
        case .antigravity: self = .antigravity
        case .cursor: return nil // Cursor not yet supported in widgets
        case .opencode: self = .opencode
        case .zai: self = .zai
        case .factory: return nil // Factory not yet supported in widgets
        case .copilot: self = .copilot
        case .minimax: self = .minimax
        case .vertexai: return nil // Vertex AI not yet supported in widgets
        case .kiro: return nil // Kiro not yet supported in widgets
        case .augment: return nil // Augment not yet supported in widgets
        case .jetbrains: return nil // JetBrains not yet supported in widgets
        case .kimi: return nil // Kimi not yet supported in widgets
        case .kimik2: return nil // Kimi K2 not yet supported in widgets
        case .amp: return nil // Amp not yet supported in widgets
        case .synthetic: return nil // Synthetic not yet supported in widgets
        }
    }
}

enum CompactMetric: String, AppEnum {
    case credits
    case todayCost
    case last30DaysCost

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Metric")

    static let caseDisplayRepresentations: [CompactMetric: DisplayRepresentation] = [
        .credits: DisplayRepresentation(title: "Credits left"),
        .todayCost: DisplayRepresentation(title: "Today cost"),
        .last30DaysCost: DisplayRepresentation(title: "30d cost"),
    ]
}

struct ProviderSelectionIntent: AppIntent, WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Provider"
    static let description = IntentDescription("Select the provider to display in the widget.")

    @Parameter(title: "Provider")
    var provider: ProviderChoice

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

struct CompactMetricSelectionIntent: AppIntent, WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Provider + Metric"
    static let description = IntentDescription("Select the provider and metric to display.")

    @Parameter(title: "Provider")
    var provider: ProviderChoice

    @Parameter(title: "Metric")
    var metric: CompactMetric

    init() {
        self.provider = .codex
        self.metric = .credits
    }
}

struct CodexBarWidgetEntry: TimelineEntry {
    let date: Date
    let provider: UsageProvider
    let snapshot: WidgetSnapshot
}

struct CodexBarCompactEntry: TimelineEntry {
    let date: Date
    let provider: UsageProvider
    let metric: CompactMetric
    let snapshot: WidgetSnapshot
}

struct CodexBarSwitcherEntry: TimelineEntry {
    let date: Date
    let provider: UsageProvider
    let availableProviders: [UsageProvider]
    let snapshot: WidgetSnapshot
}

struct CodexBarTimelineProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> CodexBarWidgetEntry {
        CodexBarWidgetEntry(
            date: Date(),
            provider: .codex,
            snapshot: WidgetPreviewData.snapshot())
    }

    func snapshot(for configuration: ProviderSelectionIntent, in context: Context) async -> CodexBarWidgetEntry {
        let provider = configuration.provider.provider
        return CodexBarWidgetEntry(
            date: Date(),
            provider: provider,
            snapshot: WidgetSnapshotStore.load() ?? WidgetPreviewData.snapshot())
    }

    func timeline(
        for configuration: ProviderSelectionIntent,
        in context: Context) async -> Timeline<CodexBarWidgetEntry>
    {
        let provider = configuration.provider.provider
        let snapshot = WidgetSnapshotStore.load() ?? WidgetPreviewData.snapshot()
        let entry = CodexBarWidgetEntry(date: Date(), provider: provider, snapshot: snapshot)
        let refresh = Date().addingTimeInterval(30 * 60)
        return Timeline(entries: [entry], policy: .after(refresh))
    }
}

struct CodexBarSwitcherTimelineProvider: TimelineProvider {
    func placeholder(in context: Context) -> CodexBarSwitcherEntry {
        let snapshot = WidgetPreviewData.snapshot()
        let providers = self.availableProviders(from: snapshot)
        return CodexBarSwitcherEntry(
            date: Date(),
            provider: providers.first ?? .codex,
            availableProviders: providers,
            snapshot: snapshot)
    }

    func getSnapshot(in context: Context, completion: @escaping (CodexBarSwitcherEntry) -> Void) {
        completion(self.makeEntry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<CodexBarSwitcherEntry>) -> Void) {
        let entry = self.makeEntry()
        let refresh = Date().addingTimeInterval(30 * 60)
        completion(Timeline(entries: [entry], policy: .after(refresh)))
    }

    private func makeEntry() -> CodexBarSwitcherEntry {
        let snapshot = WidgetSnapshotStore.load() ?? WidgetPreviewData.snapshot()
        let providers = self.availableProviders(from: snapshot)
        let stored = WidgetSelectionStore.loadSelectedProvider()
        let selected = providers.first { $0 == stored } ?? providers.first ?? .codex
        if selected != stored {
            WidgetSelectionStore.saveSelectedProvider(selected)
        }
        return CodexBarSwitcherEntry(
            date: Date(),
            provider: selected,
            availableProviders: providers,
            snapshot: snapshot)
    }

    private func availableProviders(from snapshot: WidgetSnapshot) -> [UsageProvider] {
        let enabled = snapshot.enabledProviders
        let providers = enabled.isEmpty ? snapshot.entries.map(\.provider) : enabled
        return providers.isEmpty ? [.codex] : providers
    }
}

struct CodexBarCompactTimelineProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> CodexBarCompactEntry {
        CodexBarCompactEntry(
            date: Date(),
            provider: .codex,
            metric: .credits,
            snapshot: WidgetPreviewData.snapshot())
    }

    func snapshot(for configuration: CompactMetricSelectionIntent, in context: Context) async -> CodexBarCompactEntry {
        let provider = configuration.provider.provider
        return CodexBarCompactEntry(
            date: Date(),
            provider: provider,
            metric: configuration.metric,
            snapshot: WidgetSnapshotStore.load() ?? WidgetPreviewData.snapshot())
    }

    func timeline(
        for configuration: CompactMetricSelectionIntent,
        in context: Context) async -> Timeline<CodexBarCompactEntry>
    {
        let provider = configuration.provider.provider
        let snapshot = WidgetSnapshotStore.load() ?? WidgetPreviewData.snapshot()
        let entry = CodexBarCompactEntry(
            date: Date(),
            provider: provider,
            metric: configuration.metric,
            snapshot: snapshot)
        let refresh = Date().addingTimeInterval(30 * 60)
        return Timeline(entries: [entry], policy: .after(refresh))
    }
}

enum WidgetPreviewData {
    static func snapshot() -> WidgetSnapshot {
        let primary = RateWindow(usedPercent: 35, windowMinutes: nil, resetsAt: nil, resetDescription: "Resets in 4h")
        let secondary = RateWindow(usedPercent: 60, windowMinutes: nil, resetsAt: nil, resetDescription: "Resets in 3d")
        let entry = WidgetSnapshot.ProviderEntry(
            provider: .codex,
            updatedAt: Date(),
            primary: primary,
            secondary: secondary,
            tertiary: nil,
            creditsRemaining: 1243.4,
            codeReviewRemainingPercent: 78,
            tokenUsage: WidgetSnapshot.TokenUsageSummary(
                sessionCostUSD: 12.4,
                sessionTokens: 420_000,
                last30DaysCostUSD: 923.8,
                last30DaysTokens: 12_400_000),
            dailyUsage: [
                WidgetSnapshot.DailyUsagePoint(dayKey: "2025-12-01", totalTokens: 120_000, costUSD: 15.2),
                WidgetSnapshot.DailyUsagePoint(dayKey: "2025-12-02", totalTokens: 80000, costUSD: 10.1),
                WidgetSnapshot.DailyUsagePoint(dayKey: "2025-12-03", totalTokens: 140_000, costUSD: 17.9),
                WidgetSnapshot.DailyUsagePoint(dayKey: "2025-12-04", totalTokens: 90000, costUSD: 11.4),
                WidgetSnapshot.DailyUsagePoint(dayKey: "2025-12-05", totalTokens: 160_000, costUSD: 19.8),
                WidgetSnapshot.DailyUsagePoint(dayKey: "2025-12-06", totalTokens: 70000, costUSD: 8.9),
                WidgetSnapshot.DailyUsagePoint(dayKey: "2025-12-07", totalTokens: 110_000, costUSD: 13.7),
            ])
        return WidgetSnapshot(entries: [entry], generatedAt: Date())
    }
}
