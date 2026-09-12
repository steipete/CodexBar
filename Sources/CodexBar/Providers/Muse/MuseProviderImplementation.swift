import AppKit
import CodexBarCore
import Foundation

struct MuseProviderImplementation: ProviderImplementation {
    let id: UsageProvider = .muse

    @MainActor
    func presentation(context _: ProviderPresentationContext) -> ProviderPresentation {
        ProviderPresentation { _ in "local" }
    }

    @MainActor
    func observeSettings(_ settings: SettingsStore) {
        _ = settings[providerConfig: .muse, field: .apiKey]
    }

    @MainActor
    func isAvailable(context: ProviderAvailabilityContext) -> Bool {
        if MuseSettingsReader.apiKey(environment: context.environment) != nil {
            return true
        }
        if !context.settings[providerConfig: .muse, field: .apiKey]
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            return true
        }
        let probe = MuseStatusProbe.probe(environment: context.environment)
        return probe.isInstalled || probe.hasConfig || probe.hasSessions
    }

    @MainActor
    func settingsFields(context: ProviderSettingsContext) -> [ProviderSettingsFieldDescriptor] {
        [
            ProviderSettingsFieldDescriptor(
                id: "muse-api-key",
                title: "API key",
                subtitle: "Optional. Stored in ~/.codexbar/config.json or META_API_KEY / MUSE_API_KEY. "
                    + "Usage and cost are read from local Muse session logs.",
                kind: .secure,
                placeholder: "Meta API key...",
                binding: context.providerConfigBinding(.apiKey),
                actions: [
                    Self.linkAction(
                        id: "muse-docs",
                        title: "Open Meta AI Developer Docs",
                        url: "https://developer.meta.com/ai"),
                    Self.linkAction(
                        id: "muse-blog",
                        title: "Open Muse Code Plans",
                        url: "https://developer.meta.com/ai/resources/blog/muse-code-new-plans-and-features/"),
                ],
                isVisible: nil,
                onActivate: nil),
        ]
    }

    @MainActor
    private static func linkAction(id: String, title: String, url: String) -> ProviderSettingsActionDescriptor {
        ProviderSettingsActionDescriptor(
            id: id,
            title: title,
            style: .link,
            isVisible: nil,
            perform: {
                guard let target = URL(string: url) else { return }
                NSWorkspace.shared.open(target)
            })
    }
}
