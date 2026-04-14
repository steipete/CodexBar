import AppKit
import CodexBarCore
import CodexBarMacroSupport
import Foundation
import SwiftUI

@ProviderImplementationRegistration
struct MoonshotProviderImplementation: ProviderImplementation {
    let id: UsageProvider = .moonshot

    @MainActor
    func observeSettings(_ settings: SettingsStore) {
        _ = settings.moonshotAPIToken
        _ = settings.moonshotRegion
    }

    @MainActor
    func settingsSnapshot(context: ProviderSettingsSnapshotContext) -> ProviderSettingsSnapshotContribution? {
        _ = context
        return .moonshot(context.settings.moonshotSettingsSnapshot())
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
                id: "moonshot-region",
                title: "Region",
                subtitle: "Choose the official Moonshot API host for your account.",
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
                subtitle: "Stored in ~/.codexbar/config.json. Generate one in the Moonshot console.",
                kind: .secure,
                placeholder: "Paste API key…",
                binding: context.stringBinding(\.moonshotAPIToken),
                actions: [
                    ProviderSettingsActionDescriptor(
                        id: "moonshot-open-api-keys",
                        title: "Open API Keys",
                        style: .link,
                        isVisible: nil,
                        perform: {
                            if let url = URL(string: "https://platform.moonshot.ai/console/api-keys") {
                                NSWorkspace.shared.open(url)
                            }
                        }),
                ],
                isVisible: nil,
                onActivate: { context.settings.ensureMoonshotAPITokenLoaded() }),
        ]
    }
}
