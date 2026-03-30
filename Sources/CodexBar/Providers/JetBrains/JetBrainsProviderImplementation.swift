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
            ProviderSettingsPickerOption(id: "", title: AppStrings.tr("Auto-detect")),
        ]
        for ide in detectedIDEs {
            options.append(ProviderSettingsPickerOption(id: ide.basePath, title: ide.displayName))
        }

        return [
            ProviderSettingsPickerDescriptor(
                id: "jetbrains.ide",
                title: AppStrings.tr("JetBrains IDE"),
                subtitle: AppStrings.tr("Select the IDE to monitor"),
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
                title: AppStrings.tr("Custom Path"),
                subtitle: AppStrings.tr("Override auto-detection with a custom IDE base path"),
                kind: .plain,
                placeholder: "~/Library/Application Support/JetBrains/IntelliJIdea2024.3",
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
