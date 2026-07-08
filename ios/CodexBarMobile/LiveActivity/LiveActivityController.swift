import ActivityKit
import Foundation
import OSLog

/// Starts, updates, and ends usage Live Activities. Off by default — only reachable when the user
/// enables Live Activities in Settings and toggles one on from a provider's detail screen.
///
/// Without a push server we cannot update a Live Activity remotely via APNs, so activities refresh
/// locally: whenever the app ingests a new snapshot (foreground or background wake), `refreshAll`
/// pushes the latest state into any running activity.
@MainActor
final class LiveActivityController {
    static let shared = LiveActivityController()
    private let log = Logger(subsystem: "com.steipete.codexbar.ios", category: "LiveActivity")

    private init() {}

    private var areEnabled: Bool {
        ActivityAuthorizationInfo().areActivitiesEnabled
    }

    func isRunning(for provider: UsageProvider) -> Bool {
        Activity<UsageActivityAttributes>.activities
            .contains { $0.attributes.providerRawValue == provider.rawValue }
    }

    func start(for entry: WidgetSnapshot.ProviderEntry) {
        guard self.areEnabled else {
            self.log.error("Live Activities not authorized")
            return
        }
        guard !self.isRunning(for: entry.provider) else { return }
        let attributes = UsageActivityAttributes(providerRawValue: entry.provider.rawValue)
        let state = Self.contentState(for: entry)
        do {
            _ = try Activity.request(
                attributes: attributes,
                content: .init(state: state, staleDate: Date().addingTimeInterval(60 * 60)),
                pushType: nil)
            self.log.info("started Live Activity for \(entry.provider.rawValue, privacy: .public)")
        } catch {
            self.log.error("failed to start activity: \(error.localizedDescription, privacy: .public)")
        }
    }

    nonisolated func stop(for provider: UsageProvider) async {
        let matches = Activity<UsageActivityAttributes>.activities
            .filter { $0.attributes.providerRawValue == provider.rawValue }
        for activity in matches {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }

    /// Push the freshest state into every running activity after a new snapshot arrives.
    nonisolated func refreshAll(from snapshot: WidgetSnapshot) async {
        for activity in Activity<UsageActivityAttributes>.activities {
            guard let entry = snapshot.entries.first(where: {
                $0.provider.rawValue == activity.attributes.providerRawValue
            }) else { continue }
            let content = ActivityContent(
                state: Self.contentState(for: entry),
                staleDate: Date().addingTimeInterval(60 * 60))
            await activity.update(content)
        }
    }

    private nonisolated static func contentState(
        for entry: WidgetSnapshot.ProviderEntry) -> UsageActivityAttributes.ContentState
    {
        let headlineRow = entry.displayRows.min { ($0.percentLeft ?? 100) < ($1.percentLeft ?? 100) }
        return UsageActivityAttributes.ContentState(
            providerRawValue: entry.provider.rawValue,
            providerDisplayName: entry.provider.displayName,
            remainingPercent: headlineRow?.percentLeft ?? entry.headlineRemainingPercent ?? 0,
            windowLabel: headlineRow?.title ?? "Usage",
            resetsAt: entry.primary?.resetsAt,
            updatedAt: entry.updatedAt)
    }
}
