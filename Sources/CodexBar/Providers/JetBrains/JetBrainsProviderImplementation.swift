import CodexBarCore
import CodexBarMacroSupport
import Foundation
import SwiftUI

@ProviderImplementationRegistration
struct JetBrainsProviderImplementation: ProviderImplementation {
    let id: UsageProvider = .jetbrains

    @MainActor
    func settingsSnapshot(context: ProviderSettingsSnapshotContext) -> ProviderSettingsSnapshotContribution? {
        _ = context
        return .jetbrains(context.settings.jetbrainsSettingsSnapshot())
    }

    @MainActor
    func settingsPickers(context: ProviderSettingsContext) -> [ProviderSettingsPickerDescriptor] {
        let detectedIDEs = JetBrainsIDEDetector.detectInstalledIDEs(includeMissingQuota: true)
        guard !detectedIDEs.isEmpty else { return [] }

        var options: [ProviderSettingsPickerOption] = [
            ProviderSettingsPickerOption(id: "", title: String(localized: "Auto-detect")),
        ]
        for ide in detectedIDEs {
            options.append(ProviderSettingsPickerOption(id: ide.basePath, title: ide.displayName))
        }

        return [
            ProviderSettingsPickerDescriptor(
                id: "jetbrains.ide",
                title: String(localized: "JetBrains IDE"),
                subtitle: String(localized: "Select the IDE to monitor"),
                binding: context.stringBinding(\.jetbrainsIDEBasePath),
                options: options,
                isVisible: nil,
                onChange: nil,
                trailingText: {
                    if context.settings.jetbrainsIDEBasePath.isEmpty {
                        if let latest = JetBrainsIDEDetector.detectLatestIDE() {
                            return latest.displayName
                        }
                    }
                    return nil
                }),
        ]
    }

    @MainActor
    func settingsFields(context: ProviderSettingsContext) -> [ProviderSettingsFieldDescriptor] {
        [
            ProviderSettingsFieldDescriptor(
                id: "jetbrains.customPath",
                title: String(localized: "Custom Path"),
                subtitle: String(localized: "Override auto-detection with a custom IDE base path"),
                kind: .plain,
                placeholder: String(localized: "~/Library/Application Support/JetBrains/IntelliJIdea2024.3"),
                binding: context.stringBinding(\.jetbrainsIDEBasePath),
                actions: [],
                isVisible: {
                    let detectedIDEs = JetBrainsIDEDetector.detectInstalledIDEs()
                    return detectedIDEs.isEmpty || !context.settings.jetbrainsIDEBasePath.isEmpty
                },
                onActivate: nil),
        ]
    }

    @MainActor
    func runLoginFlow(context: ProviderLoginContext) async -> Bool {
        await context.controller.runJetBrainsLoginFlow()
        return false
    }
}
