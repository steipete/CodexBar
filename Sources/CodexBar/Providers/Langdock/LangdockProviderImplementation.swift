import CodexBarCore
import Foundation
import SwiftUI

struct LangdockProviderImplementation: ProviderImplementation {
    let id: UsageProvider = .langdock

    @MainActor
    func presentation(context _: ProviderPresentationContext) -> ProviderPresentation {
        ProviderPresentation { _ in "Edge" }
    }

    @MainActor
    func observeSettings(_ settings: SettingsStore) {
        _ = settings.providerConfig(for: .langdock)?.langdockEdgeProfileID
    }

    @MainActor
    func settingsSnapshot(context: ProviderSettingsSnapshotContext) -> ProviderSettingsSnapshotContribution? {
        .langdock(LangdockProviderSettings(
            edgeProfileID: context.settings.providerConfig(for: .langdock)?.langdockEdgeProfileID))
    }

    @MainActor
    func settingsFields(context: ProviderSettingsContext) -> [ProviderSettingsFieldDescriptor] {
        let profileID = Binding<String>(
            get: { context.settings.providerConfig(for: .langdock)?.langdockEdgeProfileID ?? "" },
            set: { value in
                let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
                guard normalized != context.settings.providerConfig(for: .langdock)?.langdockEdgeProfileID else {
                    return
                }
                context.store.clearProviderState(.langdock)
                context.settings.updateProviderConfig(provider: .langdock) { entry in
                    entry.langdockEdgeProfileID = normalized.isEmpty ? nil : normalized
                }
            })
        return [
            ProviderSettingsFieldDescriptor(
                id: "langdock-edge-profile-id",
                title: "Edge profile ID",
                subtitle: "Enter the Edge profile directory path for your Langdock account. " +
                    "CodexBar reads only that profile and never switches accounts automatically.",
                kind: .plain,
                placeholder: "/Users/…/Library/Application Support/Microsoft Edge/Profile 1",
                binding: profileID,
                actions: [
                    ProviderSettingsActionDescriptor.openURL(
                        id: "langdock-open-usage",
                        title: "Open Langdock Usage",
                        url: URL(string: "https://app.langdock.com/settings/account/usage")),
                ],
                isVisible: nil),
        ]
    }
}
