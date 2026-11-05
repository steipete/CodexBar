import CodexBarCore
import Foundation

struct QuotaFeedProviderImplementation: ProviderImplementation {
    let id: UsageProvider = .quotafeed

    @MainActor
    func presentation(context _: ProviderPresentationContext) -> ProviderPresentation {
        ProviderPresentation(showsVersionInSettings: false) { _ in "local file" }
    }

    @MainActor
    func observeSettings(_ settings: SettingsStore) { _ = settings.quotaFeedPath }

    @MainActor
    func settingsSnapshot(context: ProviderSettingsSnapshotContext) -> ProviderSettingsSnapshotContribution? {
        ProviderSettingsSnapshotContribution(
            QuotaFeedProviderSettings(path: context.settings.quotaFeedPath),
            for: QuotaFeedProviderSettingsKey.self)
    }

    @MainActor
    func settingsFields(context: ProviderSettingsContext) -> [ProviderSettingsFieldDescriptor] {
        [ProviderSettingsFieldDescriptor(
            id: "quota-feed-path",
            title: "File",
            subtitle: "Absolute path to a quota JSON file. Refresh the file every 15 minutes.",
            kind: .plain,
            placeholder: nil,
            binding: context.binding(\.quotaFeedPath),
            actions: [],
            isVisible: nil)]
    }
}

extension SettingsStore {
    var quotaFeedPath: String {
        get { self.providerConfig(for: .quotafeed)?.quotaFeedPath ?? "" }
        set { self.updateProviderConfig(provider: .quotafeed) { $0.quotaFeedPath = newValue } }
    }
}
