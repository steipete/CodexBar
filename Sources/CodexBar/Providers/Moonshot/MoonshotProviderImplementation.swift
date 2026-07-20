import AppKit
import CodexBarCore
import Foundation
import SwiftUI

struct MoonshotProviderImplementation: ProviderImplementation {
    let id: UsageProvider = .moonshot

    @MainActor
    func presentation(context _: ProviderPresentationContext) -> ProviderPresentation {
        ProviderPresentation { _ in "api" }
    }

    @MainActor
    func observeSettings(_ settings: SettingsStore) {
        _ = settings.moonshotAPIToken
        _ = settings.moonshotRegion
    }

    @MainActor
    func settingsSnapshot(context: ProviderSettingsSnapshotContext)
        -> ProviderSettingsSnapshotContribution?
    {
        .moonshot(context.settings.moonshotSettingsSnapshot())
    }

    @MainActor
    func isAvailable(context: ProviderAvailabilityContext) -> Bool {
        if MoonshotSettingsReader.apiKey(environment: context.environment) != nil {
            return true
        }
        context.settings.ensureMoonshotAPITokenLoaded()
        return !context.settings.moonshotAPIToken.trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty
    }

    @MainActor
    func settingsPickers(context: ProviderSettingsContext) -> [ProviderSettingsPickerDescriptor] {
        let binding = Binding(
            get: { context.settings.moonshotRegion.rawValue },
            set: { raw in
                context.settings.moonshotRegion = MoonshotRegion(rawValue: raw) ?? .international
            })
        let options = MoonshotRegion.allCases.map {
            ProviderSettingsPickerOption(id: $0.rawValue, title: $0.displayName)
        }

        return [
            ProviderSettingsPickerDescriptor(
                id: "moonshot-api-region",
                title: "API region",
                subtitle: "Open-platform pay-as-you-go balance only. " +
                    "China mainland uses api.moonshot.cn (platform.kimi.com keys). " +
                    "International uses api.moonshot.ai. " +
                    "Kimi Code weekly subscription is a different product under Kimi Code.",
                binding: binding,
                options: options,
                isVisible: nil,
                onChange: nil),
        ]
    }

    @MainActor
    func settingsFields(context: ProviderSettingsContext) -> [ProviderSettingsFieldDescriptor] {
        [
            ProviderSettingsFieldDescriptor(
                id: "moonshot-api-key",
                title: "API key",
                subtitle: "Open-platform key for the selected region. Stored in ~/.codexbar/config.json " +
                    "(or MOONSHOT_API_KEY). Do not paste a Kimi Code subscription key here.",
                kind: .secure,
                placeholder: "sk-...",
                binding: context.stringBinding(\.moonshotAPIToken),
                actions: [
                    ProviderSettingsActionDescriptor(
                        id: "moonshot-open-dashboard",
                        title: "Open console",
                        style: .link,
                        isVisible: nil,
                        perform: {
                            NSWorkspace.shared.open(context.settings.moonshotRegion.consoleURL)
                        }),
                ],
                isVisible: nil,
                onActivate: { context.settings.ensureMoonshotAPITokenLoaded() }),
        ]
    }
}
