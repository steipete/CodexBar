import AppKit
import CodexBarCore
import CodexBarMacroSupport
import Foundation
import SwiftUI

@ProviderImplementationRegistration
struct KimiProviderImplementation: ProviderImplementation {
    let id: UsageProvider = .kimi

    @MainActor
    func observeSettings(_ settings: SettingsStore) {
        _ = settings.kimiUsageDataSource
        _ = settings.kimiAPIToken
    }

    @MainActor
    func settingsSnapshot(context: ProviderSettingsSnapshotContext) -> ProviderSettingsSnapshotContribution? {
        .kimi(context.settings.kimiSettingsSnapshot(tokenOverride: context.tokenOverride))
    }

    @MainActor
    func defaultSourceLabel(context: ProviderSourceLabelContext) -> String? {
        context.settings.kimiUsageDataSource.rawValue
    }

    @MainActor
    func sourceMode(context: ProviderSourceModeContext) -> ProviderSourceMode {
        switch context.settings.kimiUsageDataSource {
        case .auto: .auto
        case .oauth: .oauth
        case .api: .api
        }
    }

    @MainActor
    func settingsPickers(context: ProviderSettingsContext) -> [ProviderSettingsPickerDescriptor] {
        let usageBinding = Binding(
            get: { context.settings.kimiUsageDataSource.rawValue },
            set: { raw in
                context.settings.kimiUsageDataSource = KimiUsageDataSource(rawValue: raw) ?? .auto
            })

        return [
            ProviderSettingsPickerDescriptor(
                id: "kimi-usage-source",
                title: "Usage source",
                subtitle: "Auto prefers the official Kimi CLI OAuth session, then falls back to KIMI_API_KEY.",
                binding: usageBinding,
                options: KimiUsageDataSource.allCases.map {
                    ProviderSettingsPickerOption(id: $0.rawValue, title: $0.displayName)
                },
                isVisible: nil,
                onChange: nil,
                trailingText: {
                    guard context.settings.kimiUsageDataSource == .auto else { return nil }
                    let label = context.store.sourceLabel(for: .kimi)
                    return label == "auto" ? nil : label
                }),
        ]
    }

    @MainActor
    func settingsFields(context: ProviderSettingsContext) -> [ProviderSettingsFieldDescriptor] {
        [
            ProviderSettingsFieldDescriptor(
                id: "kimi-api-key",
                title: "API key",
                subtitle: "Optional. Auto mode uses ~/.kimi/credentials/kimi-code.json first, then this key.",
                kind: .secure,
                placeholder: "sk-...",
                binding: context.stringBinding(\.kimiAPIToken),
                actions: [
                    ProviderSettingsActionDescriptor(
                        id: "kimi-open-docs",
                        title: "Open Kimi Code Docs",
                        style: .link,
                        isVisible: nil,
                        perform: {
                            if let url = URL(string: "https://www.kimi.com/code/docs/en/") {
                                NSWorkspace.shared.open(url)
                            }
                        }),
                ],
                isVisible: nil,
                onActivate: { context.settings.ensureKimiAPIKeyLoaded() }),
        ]
    }
}
