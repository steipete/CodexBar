import AppIntents
import CodexBarCore
import WidgetKit

/// Provider-specific by design: AppIntents requires compile-time enum cases and display representations;
/// runtime presentation policy still comes from each provider descriptor below this literal WidgetKit surface.
enum BurnProviderChoice: String, AppEnum {
    case codex
    case openai
    case azureopenai
    case claude
    case clinepass
    case cursor
    case opencode
    case opencodego
    case alibaba
    case alibabatokenplan
    case qwencloud
    case factory
    case fireworks
    case gemini
    case antigravity
    case copilot
    case devin
    case zai
    case minimax
    case manus
    case kimi
    case kilo
    case kiro
    case vertexai
    case augment
    case jetbrains
    case moonshot
    case amp
    case t3chat
    case ollama
    case synthetic
    case openrouter
    case elevenlabs
    case warp
    case windsurf
    case zed
    case perplexity
    case mimo
    case doubao
    case sakana
    case abacus
    case mistral
    case deepseek
    case deepinfra
    case codebuff
    case venice
    case commandcode
    case qoder
    case stepfun
    case bedrock
    case grok
    case groq
    case llmproxy
    case litellm
    case bifrost
    case aixy
    case deepgram
    case poe
    case chutes
    case neuralwatt
    case helmcode
    case clawrouter
    case longcat
    case sub2api
    case wayfinder
    case zenmux
    case aiand
    case zoommate
    case xai
    case notion
    case ibmbob
    case nous
    case muse
    case coderabbit
    case replicate
    case huggingface
    case raycast
    case pi
    case v0
    case typesafe
    case hyper
    case gitkraken
    case devpass
    case atlascloud
    case vercel
    case llmman
    case xkiro
    case cline

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Provider")

    static let caseDisplayRepresentations: [BurnProviderChoice: DisplayRepresentation] = [
        // Provider-specific by design: AppIntents requires literal catalog titles; snapshot data gates eligibility.
        .codex: DisplayRepresentation(title: "Codex"),
        .openai: DisplayRepresentation(title: "OpenAI"),
        .azureopenai: DisplayRepresentation(title: "Azure OpenAI"),
        .claude: DisplayRepresentation(title: "Claude"),
        .clinepass: DisplayRepresentation(title: "ClinePass"),
        .cursor: DisplayRepresentation(title: "Cursor"),
        .opencode: DisplayRepresentation(title: "OpenCode"),
        .opencodego: DisplayRepresentation(title: "OpenCode Go"),
        .alibaba: DisplayRepresentation(title: "Alibaba"),
        .alibabatokenplan: DisplayRepresentation(title: "Alibaba Token Plan"),
        .qwencloud: DisplayRepresentation(title: "Qwen Cloud"),
        .factory: DisplayRepresentation(title: "Droid"),
        .fireworks: DisplayRepresentation(title: "Fireworks"),
        .gemini: DisplayRepresentation(title: "Gemini"),
        .antigravity: DisplayRepresentation(title: "Antigravity"),
        .copilot: DisplayRepresentation(title: "Copilot"),
        .devin: DisplayRepresentation(title: "Devin"),
        .zai: DisplayRepresentation(title: "z.ai / GLM"),
        .minimax: DisplayRepresentation(title: "MiniMax"),
        .manus: DisplayRepresentation(title: "Manus"),
        .kimi: DisplayRepresentation(title: "Kimi Code"),
        .kilo: DisplayRepresentation(title: "Kilo"),
        .kiro: DisplayRepresentation(title: "Kiro"),
        .vertexai: DisplayRepresentation(title: "Vertex AI"),
        .augment: DisplayRepresentation(title: "Augment"),
        .jetbrains: DisplayRepresentation(title: "JetBrains AI"),
        .moonshot: DisplayRepresentation(title: "Moonshot / Kimi Open Platform"),
        .amp: DisplayRepresentation(title: "Amp"),
        .t3chat: DisplayRepresentation(title: "T3 Chat"),
        .ollama: DisplayRepresentation(title: "Ollama"),
        .synthetic: DisplayRepresentation(title: "Synthetic"),
        .openrouter: DisplayRepresentation(title: "OpenRouter"),
        .elevenlabs: DisplayRepresentation(title: "ElevenLabs"),
        .warp: DisplayRepresentation(title: "Warp"),
        .windsurf: DisplayRepresentation(title: "Windsurf"),
        .zed: DisplayRepresentation(title: "Zed"),
        .perplexity: DisplayRepresentation(title: "Perplexity"),
        .mimo: DisplayRepresentation(title: "Xiaomi MiMo"),
        .doubao: DisplayRepresentation(title: "Doubao"),
        .sakana: DisplayRepresentation(title: "Sakana AI"),
        // Provider-specific by design: AppIntents requires literal catalog titles; snapshot data gates eligibility.
        .abacus: DisplayRepresentation(title: "Abacus AI"),
        .mistral: DisplayRepresentation(title: "Mistral"),
        .deepseek: DisplayRepresentation(title: "DeepSeek"),
        .deepinfra: DisplayRepresentation(title: "DeepInfra"),
        .codebuff: DisplayRepresentation(title: "Codebuff"),
        .venice: DisplayRepresentation(title: "Venice"),
        .commandcode: DisplayRepresentation(title: "Command Code"),
        .qoder: DisplayRepresentation(title: "Qoder"),
        .stepfun: DisplayRepresentation(title: "StepFun"),
        .bedrock: DisplayRepresentation(title: "AWS Bedrock"),
        .grok: DisplayRepresentation(title: "Grok"),
        .groq: DisplayRepresentation(title: "Groq"),
        .llmproxy: DisplayRepresentation(title: "LLM Proxy"),
        .litellm: DisplayRepresentation(title: "LiteLLM"),
        .bifrost: DisplayRepresentation(title: "Bifrost"),
        .aixy: DisplayRepresentation(title: "Aixy"),
        .deepgram: DisplayRepresentation(title: "Deepgram"),
        .poe: DisplayRepresentation(title: "Poe"),
        .chutes: DisplayRepresentation(title: "Chutes"),
        .neuralwatt: DisplayRepresentation(title: "Neuralwatt"),
        .helmcode: DisplayRepresentation(title: "Helmcode"),
        .clawrouter: DisplayRepresentation(title: "ClawRouter"),
        .longcat: DisplayRepresentation(title: "LongCat"),
        .sub2api: DisplayRepresentation(title: "sub2api"),
        .wayfinder: DisplayRepresentation(title: "Wayfinder"),
        .zenmux: DisplayRepresentation(title: "ZenMux"),
        .aiand: DisplayRepresentation(title: "ai&"),
        .zoommate: DisplayRepresentation(title: "ZoomMate"),
        .xai: DisplayRepresentation(title: "xAI"),
        .notion: DisplayRepresentation(title: "Notion AI"),
        .ibmbob: DisplayRepresentation(title: "IBM Bob"),
        .nous: DisplayRepresentation(title: "Nous Portal"),
        .muse: DisplayRepresentation(title: "Muse Code"),
        .coderabbit: DisplayRepresentation(title: "CodeRabbit"),
        .replicate: DisplayRepresentation(title: "Replicate"),
        .huggingface: DisplayRepresentation(title: "Hugging Face"),
        .raycast: DisplayRepresentation(title: "Raycast"),
        .pi: DisplayRepresentation(title: "Pi"),
        .v0: DisplayRepresentation(title: "v0"),
        .typesafe: DisplayRepresentation(title: "TypeSafe"),
        // Provider-specific by design: AppIntents requires literal catalog titles; snapshot data gates eligibility.
        .hyper: DisplayRepresentation(title: "Charm Hyper"),
        .gitkraken: DisplayRepresentation(title: "GitKraken AI"),
        .devpass: DisplayRepresentation(title: "DevPass"),
        .atlascloud: DisplayRepresentation(title: "Atlas Cloud"),
        .vercel: DisplayRepresentation(title: "Vercel AI Gateway"),
        .llmman: DisplayRepresentation(title: "llmman"),
        .xkiro: DisplayRepresentation(title: "xKiro"),
        .cline: DisplayRepresentation(title: "Cline"),
    ]

    var provider: UsageProvider {
        UsageProvider(rawValue: self.rawValue)!
    }
}

enum BurnWindowChoice: String, AppEnum {
    case session
    case weekly
    case primary
    case secondary
    case tertiary

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Usage window")

    static let caseDisplayRepresentations: [BurnWindowChoice: DisplayRepresentation] = [
        .session: DisplayRepresentation(title: "Session (5-hour)"),
        .weekly: DisplayRepresentation(title: "Weekly (7-day)"),
        .primary: DisplayRepresentation(title: "Primary quota"),
        .secondary: DisplayRepresentation(title: "Secondary quota"),
        .tertiary: DisplayRepresentation(title: "Third quota"),
    ]
}

struct BurnDownSelectionIntent: AppIntent, WidgetConfigurationIntent {
    // Provider-specific by design: the original burn-down widget defaults to Codex session usage.
    static let title: LocalizedStringResource = "Burn Down"
    static let description = IntentDescription("Select the provider and usage window to display.")

    @Parameter(title: "Provider", default: .codex, optionsProvider: BurnProviderOptions())
    var provider: BurnProviderChoice

    @Parameter(title: "Usage window", default: .session, optionsProvider: BurnWindowOptions())
    var window: BurnWindowChoice

    init() {
        self.provider = .codex
        self.window = .session
    }
}

struct BurnProviderSelectionIntent: AppIntent, WidgetConfigurationIntent {
    // Provider-specific by design: the provider-only burn-down widget also defaults to Codex.
    static let title: LocalizedStringResource = "Burn Down Provider"
    static let description = IntentDescription("Select the provider to display.")

    @Parameter(title: "Provider", default: .codex, optionsProvider: BurnProviderOptions(combined: true))
    var provider: BurnProviderChoice

    init() {
        self.provider = .codex
    }
}

struct BurnDownEntry: TimelineEntry {
    let date: Date
    let provider: UsageProvider
    let window: BurnWindowChoice
    let snapshot: WidgetSnapshot
}

struct CombinedBurnDownEntry: TimelineEntry {
    let date: Date
    let provider: UsageProvider
    let snapshot: WidgetSnapshot
}

struct BurnProviderOptions: DynamicOptionsProvider {
    var combined = false

    func results() async throws -> [BurnProviderChoice] {
        Self.choices(in: WidgetSnapshotStore.load(), combined: self.combined)
    }

    static func choices(in snapshot: WidgetSnapshot?, combined: Bool = false) -> [BurnProviderChoice] {
        guard let snapshot else { return [] }
        return BurnProviderChoice.allCases.filter { choice in
            guard snapshot.enabledProviders.contains(choice.provider.instanceID),
                  let state = BurnDownState(snapshot: snapshot, provider: choice.provider, selection: .primary)
            else { return false }
            let selections = combined ? state.combinedSelections : state.availableSelections
            return selections.contains { state.window(for: $0) != nil }
        }
    }
}

struct BurnWindowOptions: DynamicOptionsProvider {
    @IntentParameterDependency<BurnDownSelectionIntent>(\.$provider)
    var intent

    func results() async throws -> ItemCollection<BurnWindowChoice> {
        guard let provider = self.intent?.provider.provider,
              let snapshot = WidgetSnapshotStore.load(),
              let state = BurnDownState(snapshot: snapshot, provider: provider, selection: .primary)
        else { return .empty }
        return ItemCollection(sections: [.init(items: state.availableSelections.map { selection in
            IntentItem(selection, title: "\(state.title(for: selection))")
        })])
    }
}

struct BurnDownState {
    let entry: WidgetSnapshot.ProviderEntry
    let selection: BurnWindowChoice
    let now: Date

    init?(
        snapshot: WidgetSnapshot,
        provider: UsageProvider,
        selection: BurnWindowChoice,
        now: Date = Date())
    {
        guard let entry = snapshot.entries.first(where: { $0.provider == provider.instanceID }) else { return nil }
        self.entry = entry
        self.selection = selection
        self.now = now
    }

    static func isCompatible(_ window: RateWindow?) -> Bool {
        guard let window, window.usedPercent.isFinite, !window.isSyntheticPlaceholder,
              let minutes = window.windowMinutes, minutes > 0,
              let reset = window.resetsAt, reset.timeIntervalSince1970.isFinite else { return false }
        return true
    }

    /// Provider-specific by design: preserve the two original Combined intent lane identities on upgrade.
    var usesLegacyLanes: Bool {
        self.entry.provider == UsageProvider.codex.instanceID || self.entry.provider == UsageProvider.claude.instanceID
    }

    var availableSelections: [BurnWindowChoice] {
        let choices: [BurnWindowChoice] = self.combinedSelections == [.session, .weekly]
            ? [.session, .weekly, .tertiary] : [.primary, .secondary, .tertiary]
        return choices.filter { self.window(for: $0) != nil }
    }

    var combinedSelections: [BurnWindowChoice] {
        let legacyShape = [self.entry.primary, self.entry.secondary].compactMap(\.self).allSatisfy {
            $0.windowMinutes == nil || $0.windowMinutes == 300 || $0.windowMinutes == 10080
        }
        return self.usesLegacyLanes && legacyShape ? [.session, .weekly] : [.primary, .secondary]
    }

    func title(for selection: BurnWindowChoice) -> String {
        let metadata = self.entry.provider.firstPartyProvider.flatMap { ProviderDefaults.metadata[$0] }
        switch selection {
        case .session: return "Session"
        case .weekly: return "Weekly"
        case .primary, .secondary, .tertiary:
            return self.entry.usageRows?.first { $0.id == selection.rawValue }?.title
                ?? (selection == .primary ? metadata?.sessionLabel
                    : selection == .secondary ? metadata?.weeklyLabel : metadata?.opusLabel)
                ?? "Usage"
        }
    }

    var selectedTitle: String {
        self.title(for: self.selection)
    }

    var secondaryGloballyCapsPrimary: Bool {
        guard let provider = self.entry.provider.firstPartyProvider else { return false }
        return ProviderDescriptorRegistry.descriptor(for: provider).presentation.secondaryGloballyCapsPrimary
    }

    var secondaryExhausted: Bool {
        // A known exhausted cap still blocks usage when its reset is unavailable for charting.
        guard self.secondaryGloballyCapsPrimary, let secondary = self.sourceWindow(for: .weekly),
              secondary.usedPercent.isFinite, !secondary.isSyntheticPlaceholder else { return false }
        return secondary.remainingPercent <= 0 && (secondary.resetsAt.map { $0 > self.now } ?? true)
    }

    var primaryWindow: RateWindow? {
        self.window(for: .session)
    }

    var secondaryWindow: RateWindow? {
        self.rawWindow(for: .weekly)
    }

    var selectedWindow: RateWindow? {
        self.window(for: self.selection)
    }

    func blanksChart(for selection: BurnWindowChoice) -> Bool {
        guard selection == .session || selection == .primary,
              self.secondaryExhausted, let window = self.rawWindow(for: selection) else { return false }
        return window.windowMinutes != 10080
    }

    var blankPrimaryChart: Bool {
        self.blanksChart(for: self.selection)
    }

    var selectedResetOverride: Date? {
        self.blankPrimaryChart ? self.secondaryWindow?.resetsAt : nil
    }

    func window(for selection: BurnWindowChoice) -> RateWindow? {
        guard let window = self.rawWindow(for: selection) else { return nil }
        guard self.blanksChart(for: selection), window.remainingPercent > 0 else { return window }
        return RateWindow(
            usedPercent: 100,
            windowMinutes: window.windowMinutes,
            resetsAt: window.resetsAt,
            resetDescription: window.resetDescription,
            nextRegenPercent: window.nextRegenPercent)
    }

    private func rawWindow(for selection: BurnWindowChoice) -> RateWindow? {
        let window = self.sourceWindow(for: selection)
        return Self.isCompatible(window) ? window : nil
    }

    private func sourceWindow(for selection: BurnWindowChoice) -> RateWindow? {
        switch selection {
        case .session, .weekly:
            // Keep the persisted duration-based choices exact; never borrow a different lane.
            [self.entry.primary, self.entry.secondary].compactMap(\.self)
                .first { $0.windowMinutes == (selection == .session ? 300 : 10080) }
        case .primary: self.entry.primary
        case .secondary: self.entry.secondary
        case .tertiary: self.entry.tertiary
        }
    }
}

enum BurnDownRefreshSchedule {
    private static let minimumInterval: TimeInterval = 5 * 60
    private static let maximumInterval: TimeInterval = 30 * 60

    static func nextRefresh(
        snapshot: WidgetSnapshot,
        provider: UsageProvider,
        now: Date = Date()) -> Date
    {
        let fallback = now.addingTimeInterval(self.maximumInterval)
        guard let entry = snapshot.entries.first(where: { $0.provider == provider.instanceID }) else { return fallback }
        let nextReset = [entry.primary?.resetsAt, entry.secondary?.resetsAt, entry.tertiary?.resetsAt]
            .compactMap(\.self)
            .filter { $0 > now }
            .min()?
            .addingTimeInterval(1)
        if let nextReset {
            let target = min(fallback, nextReset)
            let minimumDate = now.addingTimeInterval(self.minimumInterval)
            return max(minimumDate, target)
        }
        return fallback
    }
}

struct BurnDownTimelineProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> BurnDownEntry {
        BurnDownEntry(
            date: Date(),
            provider: .codex,
            window: .session,
            snapshot: WidgetPreviewData.snapshot())
    }

    func snapshot(for configuration: BurnDownSelectionIntent, in context: Context) async -> BurnDownEntry {
        BurnDownEntry(
            date: Date(),
            provider: configuration.provider.provider,
            window: configuration.window,
            snapshot: WidgetSnapshotStore.load() ?? WidgetPreviewData.snapshot())
    }

    func timeline(
        for configuration: BurnDownSelectionIntent,
        in context: Context) async -> Timeline<BurnDownEntry>
    {
        let entry = BurnDownEntry(
            date: Date(),
            provider: configuration.provider.provider,
            window: configuration.window,
            snapshot: WidgetSnapshotStore.load() ?? WidgetPreviewData.emptySnapshot())
        let refresh = BurnDownRefreshSchedule.nextRefresh(snapshot: entry.snapshot, provider: entry.provider)
        return Timeline(entries: [entry], policy: .after(refresh))
    }
}

struct CombinedBurnDownTimelineProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> CombinedBurnDownEntry {
        CombinedBurnDownEntry(
            date: Date(),
            provider: .codex,
            snapshot: WidgetPreviewData.snapshot())
    }

    func snapshot(
        for configuration: BurnProviderSelectionIntent,
        in context: Context) async -> CombinedBurnDownEntry
    {
        CombinedBurnDownEntry(
            date: Date(),
            provider: configuration.provider.provider,
            snapshot: WidgetSnapshotStore.load() ?? WidgetPreviewData.snapshot())
    }

    func timeline(
        for configuration: BurnProviderSelectionIntent,
        in context: Context) async -> Timeline<CombinedBurnDownEntry>
    {
        let entry = CombinedBurnDownEntry(
            date: Date(),
            provider: configuration.provider.provider,
            snapshot: WidgetSnapshotStore.load() ?? WidgetPreviewData.emptySnapshot())
        let refresh = BurnDownRefreshSchedule.nextRefresh(snapshot: entry.snapshot, provider: entry.provider)
        return Timeline(entries: [entry], policy: .after(refresh))
    }
}
