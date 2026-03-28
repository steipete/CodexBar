import AppIntents
import CodexBariOSShared
import WidgetKit

private let widgetRefreshInterval: TimeInterval = 15 * 60
private let widgetTimelineRefreshTimeout: UInt64 = 8_000_000_000
private let widgetSkipRefreshWindow: TimeInterval = 3

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
        WidgetTimelineInteractionStore.markSkippingNetworkRefresh()
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
        let snapshot = await WidgetTimelineRefreshCoordinator.snapshotForTimeline(source: .usageWidget)
        let entry = UsageWidgetEntry(
            date: Date(),
            provider: configuration.provider?.provider ?? .codex,
            snapshot: snapshot)
        return Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(widgetRefreshInterval)))
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
        let completionBox = SwitcherTimelineCompletionBox(completion: completion)
        Task {
            let snapshot = await WidgetTimelineRefreshCoordinator.snapshotForTimeline(source: .switcherWidget)
            completionBox.completion(Timeline(
                entries: [self.makeEntry(snapshot: snapshot)],
                policy: .after(Date().addingTimeInterval(widgetRefreshInterval))))
        }
    }

    private func makeEntry(snapshot: WidgetSnapshot = WidgetSnapshotStore.load() ?? WidgetPreviewData.snapshot())
        -> SwitcherWidgetEntry
    {
        let providers = snapshot.enabledProviders.isEmpty ? [.codex, .claude] : snapshot.enabledProviders
        let selected = WidgetSelectionStore.loadSelectedProvider() ?? providers.first ?? .codex
        return SwitcherWidgetEntry(
            date: Date(),
            provider: providers.contains(selected) ? selected : providers.first ?? .codex,
            availableProviders: providers,
            snapshot: snapshot)
    }
}

private final class SwitcherTimelineCompletionBox: @unchecked Sendable {
    let completion: (Timeline<SwitcherWidgetEntry>) -> Void

    init(completion: @escaping (Timeline<SwitcherWidgetEntry>) -> Void) {
        self.completion = completion
    }
}

private enum WidgetTimelineRefreshCoordinator {
    private static let refreshService = UsageRefreshService()

    static func snapshotForTimeline(source: WidgetRefreshDiagnostics.Source) async -> WidgetSnapshot {
        let triggeredAt = Date()
        let requestCount = (WidgetRefreshDiagnosticsStore.load()?.requestCount ?? 0) + 1
        let cachedSnapshot = WidgetSnapshotStore.load() ?? WidgetPreviewData.snapshot()
        guard !WidgetTimelineInteractionStore.shouldSkipNetworkRefresh else {
            WidgetRefreshDiagnosticsStore.save(.init(
                requestCount: requestCount,
                triggeredAt: triggeredAt,
                completedAt: Date(),
                source: source,
                result: .skipped,
                networkAttempted: false,
                message: "Provider switch reused the current snapshot.",
                snapshotGeneratedAt: cachedSnapshot.generatedAt))
            return cachedSnapshot
        }

        return await withTaskGroup(of: WidgetTimelineFetchResult?.self) { group in
            group.addTask {
                let outcome = await Self.refreshService.refreshAll()
                return WidgetTimelineFetchResult(snapshot: outcome.snapshot, errors: outcome.errors)
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: widgetTimelineRefreshTimeout)
                return nil
            }

            let result = await group.next() ?? nil
            group.cancelAll()
            guard let result else {
                WidgetRefreshDiagnosticsStore.save(.init(
                    requestCount: requestCount,
                    triggeredAt: triggeredAt,
                    completedAt: Date(),
                    source: source,
                    result: .cached,
                    networkAttempted: true,
                    message: "Widget refresh timed out and kept the cached snapshot.",
                    snapshotGeneratedAt: cachedSnapshot.generatedAt))
                return cachedSnapshot
            }

            let diagnostics = Self.makeDiagnostics(
                requestCount: requestCount,
                triggeredAt: triggeredAt,
                source: source,
                cachedSnapshot: cachedSnapshot,
                result: result)
            WidgetRefreshDiagnosticsStore.save(diagnostics)
            return result.snapshot
        }
    }

    private static func makeDiagnostics(
        requestCount: Int,
        triggeredAt: Date,
        source: WidgetRefreshDiagnostics.Source,
        cachedSnapshot: WidgetSnapshot,
        result: WidgetTimelineFetchResult) -> WidgetRefreshDiagnostics
    {
        let didRefreshSnapshot = result.snapshot.generatedAt != cachedSnapshot.generatedAt
            || result.snapshot.entries != cachedSnapshot.entries
        let message: String?

        if result.errors.isEmpty {
            message = didRefreshSnapshot
                ? "Widget fetched fresh usage data."
                : "Widget refresh finished, but the snapshot contents did not change."
        } else {
            let errorSummary = result.errors
                .sorted { $0.key.rawValue < $1.key.rawValue }
                .map { "\($0.key.displayName): \($0.value)" }
                .joined(separator: " | ")
            message = didRefreshSnapshot
                ? "Widget updated with partial errors. \(errorSummary)"
                : "Widget kept cached data. \(errorSummary)"
        }

        return WidgetRefreshDiagnostics(
            requestCount: requestCount,
            triggeredAt: triggeredAt,
            completedAt: Date(),
            source: source,
            result: didRefreshSnapshot ? .refreshed : .cached,
            networkAttempted: true,
            message: message,
            snapshotGeneratedAt: result.snapshot.generatedAt)
    }
}

private struct WidgetTimelineFetchResult: Sendable {
    let snapshot: WidgetSnapshot
    let errors: [UsageProvider: String]
}

private enum WidgetTimelineInteractionStore {
    private static let skipUntilKey = "skipWidgetNetworkRefreshUntil"

    static var shouldSkipNetworkRefresh: Bool {
        guard let defaults = self.sharedDefaults else { return false }
        let skipUntil = defaults.double(forKey: self.skipUntilKey)
        if skipUntil <= Date().timeIntervalSince1970 {
            defaults.removeObject(forKey: self.skipUntilKey)
            return false
        }
        return true
    }

    static func markSkippingNetworkRefresh() {
        guard let defaults = self.sharedDefaults else { return }
        defaults.set(Date().addingTimeInterval(widgetSkipRefreshWindow).timeIntervalSince1970, forKey: self.skipUntilKey)
    }

    private static var sharedDefaults: UserDefaults? {
        guard let groupID = Bundle.main.object(
            forInfoDictionaryKey: WidgetSnapshotStore.appGroupInfoKey) as? String
        else {
            return nil
        }
        return UserDefaults(suiteName: groupID)
    }
}
