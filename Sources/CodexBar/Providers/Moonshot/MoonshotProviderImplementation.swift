import AppKit
import CodexBarCore
import CodexBarMacroSupport
import Foundation
import SwiftUI

@ProviderImplementationRegistration
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
                subtitle: "Choose the Moonshot/Kimi API host for international or China mainland accounts.",
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
                subtitle: "Stored in ~/.codexbar/config.json.",
                kind: .secure,
                placeholder: "sk-...",
                binding: context.stringBinding(\.moonshotAPIToken),
                actions: [
                    ProviderSettingsActionDescriptor(
                        id: "moonshot-open-dashboard",
                        title: "Open Moonshot Console",
                        style: .link,
                        isVisible: nil,
                        perform: {
                            if let url = URL(string: "https://platform.moonshot.ai/console/account") {
                                NSWorkspace.shared.open(url)
                            }
                        }),
                ],
                isVisible: nil,
                onActivate: { context.settings.ensureMoonshotAPITokenLoaded() }),
        ]
    }
}
