import AppIntents
import CodexBarCore
import SwiftUI
import WidgetKit

enum ProviderChoice: String, AppEnum {
    case codex
    case claude
    case gemini
    case alibaba
    case alibabatokenplan
    case antigravity
    case cursor
    case zai
    case copilot
    case devin
    case minimax
    case kilo
    case opencode
    case opencodego
    case mistral
    case kimi

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Provider")

    static let caseDisplayRepresentations: [ProviderChoice: DisplayRepresentation] = [
        .codex: DisplayRepresentation(title: "Codex"),
        .claude: DisplayRepresentation(title: "Claude"),
        .gemini: DisplayRepresentation(title: "Gemini"),
        .alibaba: DisplayRepresentation(title: "Alibaba"),
        .alibabatokenplan: DisplayRepresentation(title: "Alibaba Token Plan"),
        .antigravity: DisplayRepresentation(title: "Antigravity"),
        .cursor: DisplayRepresentation(title: "Cursor"),
        .zai: DisplayRepresentation(title: "z.ai"),
        .copilot: DisplayRepresentation(title: "Copilot"),
        .devin: DisplayRepresentation(title: "Devin"),
        .minimax: DisplayRepresentation(title: "MiniMax"),
        .kilo: DisplayRepresentation(title: "Kilo"),
        .opencode: DisplayRepresentation(title: "OpenCode"),
        .opencodego: DisplayRepresentation(title: "OpenCode Go"),
        .mistral: DisplayRepresentation(title: "Mistral"),
        .kimi: DisplayRepresentation(title: "Kimi"),
    ]

    var provider: UsageProvider {
        switch self {
        case .codex: .codex
        case .claude: .claude
        case .gemini: .gemini
        case .alibaba: .alibaba
        case .alibabatokenplan: .alibabatokenplan
        case .antigravity: .antigravity
        case .cursor: .cursor
        case .zai: .zai
        case .copilot: .copilot
        case .devin: .devin
        case .minimax: .minimax
        case .kilo: .kilo
        case .opencode: .opencode
        case .opencodego: .opencodego
        case .mistral: .mistral
        case .kimi: .kimi
        }
    }

    // swiftlint:disable:next cyclomatic_complexity
    init?(provider: UsageProvider) {
        switch provider {
        case .codex: self = .codex
        case .openai: return nil // OpenAI not yet supported in widgets
        case .azureopenai: return nil // Azure OpenAI not yet supported in widgets
        case .claude: self = .claude
        case .gemini: self = .gemini
        case .alibaba: self = .alibaba
        case .alibabatokenplan: self = .alibabatokenplan
        case .antigravity: self = .antigravity
        case .cursor: self = .cursor
        case .opencode: self = .opencode
        case .opencodego: self = .opencodego
        case .zai: self = .zai
        case .factory: return nil // Factory not yet supported in widgets
        case .copilot: self = .copilot
        case .devin: self = .devin
        case .minimax: self = .minimax
        case .manus: return nil // Manus not yet supported in widgets
        case .vertexai: return nil // Vertex AI not yet supported in widgets
        case .kilo: self = .kilo
        case .kiro: return nil // Kiro not yet supported in widgets
        case .augment: return nil // Augment not yet supported in widgets
        case .jetbrains: return nil // JetBrains not yet supported in widgets
        case .kimi: self = .kimi
        case .kimik2: return nil // Kimi K2 not yet supported in widgets
        case .moonshot: return nil // Moonshot not yet supported in widgets
        case .amp: return nil // Amp not yet supported in widgets
        case .t3chat: return nil // T3 Chat not yet supported in widgets
        case .ollama: return nil // Ollama not yet supported in widgets
        case .synthetic: return nil // Synthetic not yet supported in widgets
        case .openrouter: return nil // OpenRouter not yet supported in widgets
        case .crossmodel: return nil // CrossModel not yet supported in widgets
        case .clawrouter: return nil // ClawRouter not yet supported in widgets
        case .sub2api: return nil // sub2api not yet supported in widgets
        case .wayfinder: return nil // Wayfinder not yet supported in widgets
        case .elevenlabs: return nil // ElevenLabs not yet supported in widgets
        case .warp: return nil // Warp not yet supported in widgets
        case .windsurf: return nil // Windsurf not yet supported in widgets
        case .perplexity: return nil // Perplexity not yet supported in widgets
        case .mimo: return nil // Xiaomi MiMo not yet supported in widgets
        case .doubao: return nil // Doubao not yet supported in widgets
        case .sakana: return nil // Sakana AI not yet supported in widgets
        case .abacus: return nil // Abacus AI not yet supported in widgets
        case .mistral: self = .mistral
        case .deepseek: return nil // DeepSeek not yet supported in widgets
        case .codebuff: return nil // Codebuff not yet supported in widgets
        case .crof: return nil // Crof not yet supported in widgets
        case .venice: return nil // Venice not yet supported in widgets
        case .commandcode: return nil // CommandCode not yet supported in widgets
        case .qoder: return nil // Qoder not yet supported in widgets
        case .stepfun: return nil // StepFun not yet supported in widgets
        case .bedrock: return nil // Bedrock not yet supported in widgets
        case .grok: return nil // Grok not yet supported in widgets
        case .groq: return nil // Groq not yet supported in widgets
        case .llmproxy: return nil // LLM Proxy not yet supported in widgets
        case .litellm: return nil // LiteLLM not yet supported in widgets
        case .deepgram: return nil // Deepgram not yet supported in widgets
        case .poe: return nil // Poe not yet supported in widgets
        case .chutes: return nil // Chutes not yet supported in widgets
        case .zed: return nil // Zed not yet supported in widgets
        case .zenmux: return nil // ZenMux not yet supported in widgets
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

    @Parameter(title: "Provider", default: .codex)
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

    @Parameter(title: "Provider", default: .codex)
    var provider: ProviderChoice

    @Parameter(title: "Metric", default: .credits)
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
        let snapshot = WidgetSnapshotStore.load() ?? WidgetPreviewData.emptySnapshot()
        let now = Date()
        let entry = CodexBarWidgetEntry(date: now, provider: provider, snapshot: snapshot)
        let refresh = BurnDownRefreshSchedule.nextRefresh(snapshot: snapshot, provider: provider, now: now)
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
        let refresh = BurnDownRefreshSchedule.nextRefresh(
            snapshot: entry.snapshot,
            provider: entry.provider,
            now: entry.date)
        completion(Timeline(entries: [entry], policy: .after(refresh)))
    }

    private func makeEntry() -> CodexBarSwitcherEntry {
        let snapshot = WidgetSnapshotStore.load() ?? WidgetPreviewData.emptySnapshot()
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
        Self.supportedProviders(from: snapshot)
    }

    static func supportedProviders(from snapshot: WidgetSnapshot) -> [UsageProvider] {
        let enabled = snapshot.enabledProviders
        let providers = enabled.isEmpty ? snapshot.entries.map(\.provider) : enabled
        let supported = providers.filter { ProviderChoice(provider: $0) != nil }
        return supported.isEmpty ? [.codex] : supported
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
        let metric = configuration.metric
        return CodexBarCompactEntry(
            date: Date(),
            provider: provider,
            metric: metric,
            snapshot: WidgetSnapshotStore.load() ?? WidgetPreviewData.snapshot())
    }

    func timeline(
        for configuration: CompactMetricSelectionIntent,
        in context: Context) async -> Timeline<CodexBarCompactEntry>
    {
        let provider = configuration.provider.provider
        let metric = configuration.metric
        let snapshot = WidgetSnapshotStore.load() ?? WidgetPreviewData.emptySnapshot()
        let entry = CodexBarCompactEntry(
            date: Date(),
            provider: provider,
            metric: metric,
            snapshot: snapshot)
        let refresh = Date().addingTimeInterval(30 * 60)
        return Timeline(entries: [entry], policy: .after(refresh))
    }
}

enum WidgetPreviewData {
    static func emptySnapshot() -> WidgetSnapshot {
        WidgetSnapshot(entries: [], enabledProviders: [], generatedAt: Date())
    }

    static func snapshot() -> WidgetSnapshot {
        let primary = RateWindow(usedPercent: 35, windowMinutes: 300, resetsAt: nil, resetDescription: "Resets in 4h")
        let secondary = RateWindow(
            usedPercent: 60,
            windowMinutes: 10080,
            resetsAt: nil,
            resetDescription: "Resets in 3d")
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
