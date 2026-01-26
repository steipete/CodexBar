import CodexBarCore
import CodexBarMacroSupport
import Foundation
import SwiftUI

@ProviderImplementationRegistration
struct QwenCodeProviderImplementation: ProviderImplementation {
    let id: UsageProvider = .qwencode

    @MainActor
    func presentation(context _: ProviderPresentationContext) -> ProviderPresentation {
        ProviderPresentation { _ in "local" }
    }

    @MainActor
    func observeSettings(_ settings: SettingsStore) {
        _ = settings.qwenCodeDailyRequestLimit
    }

    @MainActor
    func settingsSnapshot(context: ProviderSettingsSnapshotContext) -> ProviderSettingsSnapshotContribution? {
        .qwencode(context.settings.qwencodeSettingsSnapshot())
    }

    @MainActor
    func settingsFields(context: ProviderSettingsContext) -> [ProviderSettingsFieldDescriptor] {
        [
            ProviderSettingsFieldDescriptor(
                id: "qwencode-daily-request-limit",
                title: "Daily request limit",
                subtitle: "Used to compute the daily usage percentage.",
                kind: .plain,
                placeholder: "2000",
                binding: context.stringBinding(\.qwenCodeDailyRequestLimit),
                actions: [],
                isVisible: nil,
                onActivate: nil),
        ]
    }
}
