import CodexBarCore
import CodexBarMacroSupport
import Foundation
import SwiftUI

@ProviderImplementationRegistration
struct WindsurfProviderImplementation: ProviderImplementation {
    let id: UsageProvider = .windsurf

    @MainActor
    func observeSettings(_ settings: SettingsStore) {
        _ = settings.windsurfUsageDataSource
        _ = settings.windsurfCookieSource
        _ = settings.windsurfCookieHeader
    }

    @MainActor
    func settingsSnapshot(context: ProviderSettingsSnapshotContext) -> ProviderSettingsSnapshotContribution? {
        .windsurf(context.settings.windsurfSettingsSnapshot(tokenOverride: context.tokenOverride))
    }

    @MainActor
    func sourceMode(context: ProviderSourceModeContext) -> ProviderSourceMode {
        switch context.settings.windsurfUsageDataSource {
        case .auto: .auto
        case .web: .web
        case .cli: .cli
        }
    }

    @MainActor
    func settingsPickers(context: ProviderSettingsContext) -> [ProviderSettingsPickerDescriptor] {
        // Usage source picker
        let usageBinding = Binding(
            get: { context.settings.windsurfUsageDataSource.rawValue },
            set: { raw in
                context.settings.windsurfUsageDataSource = WindsurfUsageDataSource(rawValue: raw) ?? .auto
            })
        let usageOptions = WindsurfUsageDataSource.allCases.map {
            ProviderSettingsPickerOption(id: $0.rawValue, title: $0.displayName)
        }

        // Cookie source picker
        let cookieBinding = Binding(
            get: { context.settings.windsurfCookieSource.rawValue },
            set: { raw in
                context.settings.windsurfCookieSource = ProviderCookieSource(rawValue: raw) ?? .auto
            })
        let cookieOptions = ProviderCookieSourceUI.options(
            allowsOff: true,
            keychainDisabled: context.settings.debugDisableKeychainAccess)

        let cookieSubtitle: () -> String? = {
            ProviderCookieSourceUI.subtitle(
                source: context.settings.windsurfCookieSource,
                keychainDisabled: context.settings.debugDisableKeychainAccess,
                auto: "Automatic imports Windsurf session data from Chromium browser localStorage.",
                manual: "Paste the Windsurf session JSON bundle from localStorage.",
                off: "Windsurf web API access is disabled.")
        }

        return [
            ProviderSettingsPickerDescriptor(
                id: "windsurf-usage-source",
                title: "Usage source",
                subtitle: "Auto falls back to the next source if the preferred one fails.",
                binding: usageBinding,
                options: usageOptions,
                isVisible: nil,
                onChange: nil,
                trailingText: {
                    guard context.settings.windsurfUsageDataSource == .auto else { return nil }
                    let label = context.store.sourceLabel(for: .windsurf)
                    return label == "auto" ? nil : label
                }),
            ProviderSettingsPickerDescriptor(
                id: "windsurf-cookie-source",
                title: "Cookie source",
                subtitle: "Automatic imports Windsurf session data from Chromium browser localStorage.",
                dynamicSubtitle: cookieSubtitle,
                binding: cookieBinding,
                options: cookieOptions,
                isVisible: nil,
                onChange: nil,
                trailingText: nil),
        ]
    }

    @MainActor
    func settingsFields(context: ProviderSettingsContext) -> [ProviderSettingsFieldDescriptor] {
        [
            ProviderSettingsFieldDescriptor(
                id: "windsurf-cookie-header",
                title: "",
                subtitle: "",
                kind: .secure,
                placeholder: "Windsurf session JSON bundle",
                binding: context.stringBinding(\.windsurfCookieHeader),
                actions: [],
                isVisible: {
                    context.settings.windsurfCookieSource == .manual
                },
                onActivate: nil),
        ]
    }
}
