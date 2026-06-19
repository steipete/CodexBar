import AppIntents
import CodexBarCore
import WidgetKit

enum BurnProviderChoice: String, AppEnum {
    case codex
    case claude

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Provider")

    static let caseDisplayRepresentations: [BurnProviderChoice: DisplayRepresentation] = [
        .codex: DisplayRepresentation(title: "Codex"),
        .claude: DisplayRepresentation(title: "Claude"),
    ]

    var provider: UsageProvider {
        switch self {
        case .codex: .codex
        case .claude: .claude
        }
    }
}

enum BurnWindowChoice: String, AppEnum {
    case session
    case weekly

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Usage window")

    static let caseDisplayRepresentations: [BurnWindowChoice: DisplayRepresentation] = [
        .session: DisplayRepresentation(title: "Session (5-hour)"),
        .weekly: DisplayRepresentation(title: "Weekly (7-day)"),
    ]
}

struct BurnDownSelectionIntent: AppIntent, WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Burn Down"
    static let description = IntentDescription("Select the provider and usage window to display.")

    @Parameter(title: "Provider", default: .codex)
    var provider: BurnProviderChoice

    @Parameter(title: "Usage window", default: .session)
    var window: BurnWindowChoice

    init() {
        self.provider = .codex
        self.window = .session
    }
}

struct BurnProviderSelectionIntent: AppIntent, WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Burn Down Provider"
    static let description = IntentDescription("Select the provider to display.")

    @Parameter(title: "Provider", default: .codex)
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

struct BurnDownState {
    private static let sessionWindowMinutes = 5 * 60
    private static let weeklyWindowMinutes = 7 * 24 * 60

    let entry: WidgetSnapshot.ProviderEntry
    let selection: BurnWindowChoice
    let now: Date

    init?(
        snapshot: WidgetSnapshot,
        provider: UsageProvider,
        selection: BurnWindowChoice,
        now: Date = Date())
    {
        guard let entry = snapshot.entries.first(where: { $0.provider == provider }) else { return nil }
        self.entry = entry
        self.selection = selection
        self.now = now
    }

    var secondaryGloballyCapsPrimary: Bool {
        switch self.entry.provider {
        case .codex, .claude: true
        default: false
        }
    }

    var secondaryExhausted: Bool {
        guard self.secondaryGloballyCapsPrimary, let secondary = self.secondaryWindow else { return false }
        guard secondary.remainingPercent <= 0 else { return false }
        return secondary.resetsAt.map { $0 > self.now } ?? true
    }

    var primaryWindow: RateWindow? {
        guard let primary = self.window(minutes: Self.sessionWindowMinutes) else { return nil }
        guard self.secondaryExhausted, primary.remainingPercent > 0 else { return primary }
        return RateWindow(
            usedPercent: 100,
            windowMinutes: primary.windowMinutes,
            resetsAt: primary.resetsAt,
            resetDescription: primary.resetDescription,
            nextRegenPercent: primary.nextRegenPercent)
    }

    var secondaryWindow: RateWindow? {
        self.window(minutes: Self.weeklyWindowMinutes)
    }

    var selectedWindow: RateWindow? {
        switch self.selection {
        case .session: self.primaryWindow
        case .weekly: self.secondaryWindow
        }
    }

    var blankPrimaryChart: Bool {
        self.selection == .session
            && self.secondaryExhausted
            && self.window(minutes: Self.sessionWindowMinutes) != nil
    }

    var selectedResetOverride: Date? {
        self.blankPrimaryChart ? self.secondaryWindow?.resetsAt : nil
    }

    private func window(minutes: Int) -> RateWindow? {
        [self.entry.primary, self.entry.secondary]
            .compactMap(\.self)
            .first { $0.windowMinutes == minutes }
    }
}

enum BurnDownRefreshSchedule {
    private static let maximumInterval: TimeInterval = 30 * 60

    static func nextRefresh(
        snapshot: WidgetSnapshot,
        provider: UsageProvider,
        now: Date = Date()) -> Date
    {
        let fallback = now.addingTimeInterval(self.maximumInterval)
        guard let entry = snapshot.entries.first(where: { $0.provider == provider }) else { return fallback }
        let nextReset = [entry.primary?.resetsAt, entry.secondary?.resetsAt]
            .compactMap(\.self)
            .filter { $0 > now }
            .min()?
            .addingTimeInterval(1)
        return min(fallback, nextReset ?? fallback)
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
