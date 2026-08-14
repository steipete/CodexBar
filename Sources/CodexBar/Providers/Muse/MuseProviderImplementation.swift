import AppKit
import CodexBarCore
import Foundation
import SwiftUI

struct MuseProviderImplementation: ProviderImplementation {
    let id: UsageProvider = .muse

    @MainActor
    func presentation(context _: ProviderPresentationContext) -> ProviderPresentation {
        ProviderPresentation { _ in "api" }
    }

    @MainActor
    func observeSettings(_ settings: SettingsStore) {
        _ = settings.museAPIToken
        _ = settings.museBaseURL
    }

    @MainActor
    func settingsSnapshot(context: ProviderSettingsSnapshotContext)
        -> ProviderSettingsSnapshotContribution?
    {
        .muse(context.settings.museSettingsSnapshot())
    }

    @MainActor
    func isAvailable(context: ProviderAvailabilityContext) -> Bool {
        if MuseSettingsReader.apiKey(environment: context.environment) != nil {
            return true
        }
        context.settings.ensureMuseAPITokenLoaded()
        return context.settings.hasMuseAPIToken
    }

    @MainActor
    func settingsFields(context: ProviderSettingsContext) -> [ProviderSettingsFieldDescriptor] {
        [
            ProviderSettingsFieldDescriptor(
                id: "muse-api-key",
                title: "Meta Muse API key",
                subtitle: "API key from ai.developer.meta.com. Also accepts META_API_KEY.",
                kind: .secure,
                placeholder: "sk-...",
                binding: context.stringBinding(\.museAPIToken),
                actions: [
                    ProviderSettingsActionDescriptor(
                        id: "muse-open-dashboard",
                        title: "Open Meta developer console",
                        style: .link,
                        isVisible: nil,
                        perform: {
                            NSWorkspace.shared.open(URL(string: "https://ai.developer.meta.com/")!)
                        }),
                ],
                isVisible: nil,
                onActivate: { context.settings.ensureMuseAPITokenLoaded() }),
            ProviderSettingsFieldDescriptor(
                id: "muse-base-url",
                title: "API base URL (optional)",
                subtitle: "Override for self-hosted or proxy. Default: https://api.meta.ai",
                kind: .plain,
                placeholder: "https://api.meta.ai",
                binding: context.stringBinding(\.museBaseURL),
                actions: [],
                isVisible: nil,
                onActivate: nil),
        ]
    }
}
