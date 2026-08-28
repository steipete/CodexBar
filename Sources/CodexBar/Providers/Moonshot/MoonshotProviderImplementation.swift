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
        let region = context.settings.moonshotRegion
        if MoonshotSettingsReader.apiKey(for: region, environment: context.environment) != nil {
            return true
        }
        context.settings.ensureMoonshotAPITokenLoaded()
        return context.settings.hasMoonshotAPIToken(for: region)
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
                subtitle: "Open-platform balance only. Keys are bound to the selected regional host and cannot be " +
                    "sent to the other region.",
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
                title: "Open Platform API key",
                subtitle: "Use a key issued for the selected region. Changing regions leaves the other key " +
                    "unavailable until you switch back or replace it.",
                kind: .secure,
                placeholder: "sk-...",
                binding: context.stringBinding(\.moonshotAPIToken),
                actions: [
                    ProviderSettingsActionDescriptor(
                        id: "moonshot-open-dashboard",
                        title: "Open regional console",
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
