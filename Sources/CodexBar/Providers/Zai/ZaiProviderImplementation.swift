import AppKit
import CodexBarCore
import CodexBarMacroSupport
import Foundation
import SwiftUI

@ProviderImplementationRegistration
struct ZaiProviderImplementation: ProviderImplementation {
    let id: UsageProvider = .zai

    @MainActor
    func settingsPickers(context: ProviderSettingsContext) -> [ProviderSettingsPickerDescriptor] {
        let binding = Binding(
            get: { context.settings.zaiAPIRegion.rawValue },
            set: { raw in
                context.settings.zaiAPIRegion = ZaiAPIRegion(rawValue: raw) ?? .global
            })
        let options = ZaiAPIRegion.allCases.map {
            ProviderSettingsPickerOption(id: $0.rawValue, title: $0.displayName)
        }

        return [
            ProviderSettingsPickerDescriptor(
                id: "zai-api-region",
                title: "API region",
                subtitle: "Use BigModel for the China mainland endpoints (open.bigmodel.cn).",
                binding: binding,
                options: options,
                isVisible: nil,
                onChange: nil),
        ]
    }

    @MainActor
    func settingsFields(context: ProviderSettingsContext) -> [ProviderSettingsFieldDescriptor] {
        _ = context
        return []
    }
}
