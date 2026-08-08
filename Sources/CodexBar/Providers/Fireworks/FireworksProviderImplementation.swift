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
        if FireworksSettingsReader.apiKey(environment: context.environment) != nil,
           FireworksSettingsReader.accountSlug(environment: context.environment) != nil
        {
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
                subtitle: "The segment after /accounts/ in your app.fireworks.ai URLs, e.g. x0mh0x for "
                    + "app.fireworks.ai/accounts/x0mh0x. Required because Fireworks has no whoami endpoint.",
                kind: .plain,
                placeholder: "x0mh0x",
                binding: context.stringBinding(\.fireworksAccountSlug),
                actions: [
                    ProviderSettingsActionDescriptor(
                        id: "fireworks-open-billing",
                        title: "Open Fireworks billing",
                        style: .link,
                        isVisible: nil,
                        perform: {
                            NSWorkspace.shared.open(
                                FireworksURLs.billing(
                                    accountSlug: context.settings.fireworksAccountSlug))
                        }),
                ],
                isVisible: nil,
                onActivate: nil),
        ]
    }
}

enum FireworksURLs {
    static func billing(accountSlug: String) -> URL {
        let slug = accountSlug.trimmingCharacters(in: .whitespacesAndNewlines)
        if slug.isEmpty {
            return URL(string: "https://app.fireworks.ai")!
        }
        return URL(string: "https://app.fireworks.ai/accounts/\(slug)/settings/billing")!
    }
}
