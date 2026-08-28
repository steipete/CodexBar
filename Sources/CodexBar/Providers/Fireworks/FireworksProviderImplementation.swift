import AppKit
import CodexBarCore
import Foundation
import SwiftUI

struct FireworksProviderImplementation: ProviderImplementation {
    let id: UsageProvider = .fireworks

    @MainActor
    func presentation(context _: ProviderPresentationContext) -> ProviderPresentation {
        ProviderPresentation { _ in "api" }
    }

    @MainActor
    func observeSettings(_ settings: SettingsStore) {
        _ = settings.fireworksAPIToken
        _ = settings.fireworksAccountSlug
    }

    @MainActor
    func settingsSnapshot(context: ProviderSettingsSnapshotContext)
        -> ProviderSettingsSnapshotContribution?
    {
        .fireworks(context.settings.fireworksSettingsSnapshot())
    }

    @MainActor
    func isAvailable(context: ProviderAvailabilityContext) -> Bool {
        if FireworksSettingsReader.apiKey(environment: context.environment) != nil {
            return true
        }
        return context.settings.hasFireworksCredentials
    }

    @MainActor
    func settingsFields(context: ProviderSettingsContext) -> [ProviderSettingsFieldDescriptor] {
        [
            ProviderSettingsFieldDescriptor(
                id: "fireworks-api-key",
                title: "API key",
                subtitle: "Create a key at app.fireworks.ai/settings. The same key authorizes billing reads.",
                kind: .secure,
                placeholder: "fw_...",
                binding: context.stringBinding(\.fireworksAPIToken),
                actions: [],
                isVisible: nil,
                onActivate: nil),
            ProviderSettingsFieldDescriptor(
                id: "fireworks-account-slug",
                title: "Account slug",
                subtitle: "Optional when the API key can access one account; CodexBar discovers it automatically. "
                    + "For multiple accounts, find the slug in the app.fireworks.ai home account switcher or run "
                    + "firectl whoami.",
                kind: .plain,
                placeholder: "x0mh0x",
                binding: context.stringBinding(\.fireworksAccountSlug),
                actions: [
                    ProviderSettingsActionDescriptor(
                        id: "fireworks-open-billing",
                        title: "Open Fireworks",
                        style: .link,
                        isVisible: nil,
                        perform: {
                            NSWorkspace.shared.open(FireworksURLs.home)
                        }),
                ],
                isVisible: nil,
                onActivate: nil),
        ]
    }
}

enum FireworksURLs {
    static let home = URL(string: "https://app.fireworks.ai")!
}
