import CodexBarCore
import Foundation
import SwiftUI

struct KiroProviderImplementation: ProviderImplementation {
    let id: UsageProvider = .kiro
    let supportsLoginFlow: Bool = true

    @MainActor
    func runLoginFlow(context: ProviderLoginContext) async -> Bool {
        await context.controller.runKiroLoginFlow()
        return true
    }

    @MainActor
    func settingsActions(context: ProviderSettingsContext) -> [ProviderSettingsActionsDescriptor] {
        [
            ProviderSettingsActionsDescriptor(
                id: "kiro-cli-login",
                title: L("kiro_reauthenticate_title"),
                subtitle: L("kiro_reauthenticate_subtitle"),
                actions: [
                    ProviderSettingsActionDescriptor(
                        id: "kiro-cli-login-reauthenticate",
                        title: L("Re-authenticate"),
                        style: .bordered,
                        isVisible: nil,
                        perform: {
                            await context.runLoginFlow()
                        }),
                ],
                isVisible: nil),
        ]
    }

    func settingsPickers(context: ProviderSettingsContext) -> [ProviderSettingsPickerDescriptor] {
        [
            ProviderSettingsPickerDescriptor(
                id: "kiroMenuBarDisplay",
                title: L("Kiro menu bar value"),
                subtitle: L("Show or hide Kiro credits, percent, or both next to the menu bar icon."),
                placement: .menuBar,
                binding: Binding(
                    get: { context.settings.kiroMenuBarDisplayMode.rawValue },
                    set: { rawValue in
                        guard let mode = KiroMenuBarDisplayMode(rawValue: rawValue) else { return }
                        context.settings.kiroMenuBarDisplayMode = mode
                    }),
                options: KiroMenuBarDisplayMode.allCases.map {
                    ProviderSettingsPickerOption(id: $0.rawValue, title: $0.label)
                },
                isVisible: { true },
                onChange: nil),
        ]
    }
}
