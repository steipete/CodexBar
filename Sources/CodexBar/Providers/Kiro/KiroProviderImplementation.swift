import CodexBarCore
import Foundation
import SwiftUI

struct KiroProviderImplementation: ProviderImplementation {
    let id: UsageProvider = .kiro

    func settingsPickers(context: ProviderSettingsContext) -> [ProviderSettingsPickerDescriptor] {
        [
            ProviderSettingsPickerDescriptor(
                id: "kiroMenuBarDisplay",
                title: "Kiro menu bar value",
                subtitle: "Show or hide Kiro credits, percent, or both next to the menu bar icon.",
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
