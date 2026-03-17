import AppKit
import CodexBarCore
import CodexBarMacroSupport
import Foundation
import SwiftUI

@ProviderImplementationRegistration
struct KimiProviderImplementation: ProviderImplementation {
    let id: UsageProvider = .kimi

    @MainActor
    func presentation(context _: ProviderPresentationContext) -> ProviderPresentation {
        ProviderPresentation { _ in AppStrings.tr("web") }
    }

    @MainActor
    func observeSettings(_ settings: SettingsStore) {
        _ = settings.kimiCookieSource
        _ = settings.kimiManualCookieHeader
    }

    @MainActor
    func settingsSnapshot(context: ProviderSettingsSnapshotContext) -> ProviderSettingsSnapshotContribution? {
        .kimi(context.settings.kimiSettingsSnapshot(tokenOverride: context.tokenOverride))
    }

    @MainActor
    func settingsPickers(context: ProviderSettingsContext) -> [ProviderSettingsPickerDescriptor] {
        let cookieBinding = Binding(
            get: { context.settings.kimiCookieSource.rawValue },
            set: { raw in
                context.settings.kimiCookieSource = ProviderCookieSource(rawValue: raw) ?? .auto
            })
        let options = ProviderCookieSourceUI.options(
            allowsOff: true,
            keychainDisabled: context.settings.debugDisableKeychainAccess)

        let subtitle: () -> String? = {
            ProviderCookieSourceUI.subtitle(
                source: context.settings.kimiCookieSource,
                keychainDisabled: context.settings.debugDisableKeychainAccess,
                auto: AppStrings.tr("Automatic imports browser cookies."),
                manual: AppStrings.tr("Paste a cookie header or the kimi-auth token value."),
                off: AppStrings.tr("Kimi cookies are disabled."))
        }

        return [
            ProviderSettingsPickerDescriptor(
                id: "kimi-cookie-source",
                title: AppStrings.tr("Cookie source"),
                subtitle: AppStrings.tr("Automatic imports browser cookies."),
                dynamicSubtitle: subtitle,
                binding: cookieBinding,
                options: options,
                isVisible: nil,
                onChange: nil),
        ]
    }

    @MainActor
    func settingsFields(context: ProviderSettingsContext) -> [ProviderSettingsFieldDescriptor] {
        [
            ProviderSettingsFieldDescriptor(
                id: "kimi-cookie",
                title: "",
                subtitle: "",
                kind: .secure,
                placeholder: AppStrings.tr("Cookie: …\n\nor paste the kimi-auth token value"),
                binding: context.stringBinding(\.kimiManualCookieHeader),
                actions: [
                    ProviderSettingsActionDescriptor(
                        id: "kimi-open-console",
                        title: AppStrings.tr("Open Console"),
                        style: .link,
                        isVisible: nil,
                        perform: {
                            if let url = URL(string: "https://www.kimi.com/code/console") {
                                NSWorkspace.shared.open(url)
                            }
                        }),
                ],
                isVisible: { context.settings.kimiCookieSource == .manual },
                onActivate: { context.settings.ensureKimiAuthTokenLoaded() }),
        ]
    }
}
