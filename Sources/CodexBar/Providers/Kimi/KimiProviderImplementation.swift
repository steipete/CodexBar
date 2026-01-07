import AppKit
import CodexBarCore
import CodexBarMacroSupport
import Foundation
import SwiftUI

@ProviderImplementationRegistration
struct KimiProviderImplementation: ProviderImplementation {
    let id: UsageProvider = .kimi

    @MainActor
    func settingsPickers(context: ProviderSettingsContext) -> [ProviderSettingsPickerDescriptor] {
        let cookieBinding = Binding(
            get: { context.settings.kimiCookieSource.rawValue },
            set: { raw in
                context.settings.kimiCookieSource = ProviderCookieSource(rawValue: raw) ?? .auto
            })
        let options: [ProviderSettingsPickerOption] = [
            ProviderSettingsPickerOption(
                id: ProviderCookieSource.auto.rawValue,
                title: ProviderCookieSource.auto.displayName),
            ProviderSettingsPickerOption(
                id: ProviderCookieSource.manual.rawValue,
                title: ProviderCookieSource.manual.displayName),
            ProviderSettingsPickerOption(
                id: ProviderCookieSource.off.rawValue,
                title: ProviderCookieSource.off.displayName),
        ]

        let subtitle: () -> String? = {
            switch context.settings.kimiCookieSource {
            case .auto:
                "Automatic imports browser cookies."
            case .manual:
                "Paste a cookie header or the kimi-auth token value."
            case .off:
                "Kimi cookies are disabled."
            }
        }

        return [
            ProviderSettingsPickerDescriptor(
                id: "kimi-cookie-source",
                title: "Cookie source",
                subtitle: "Automatic imports browser cookies.",
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
                placeholder: "Cookie: \u{2026}\n\nor paste the kimi-auth token value",
                binding: context.stringBinding(\.kimiManualCookieHeader),
                actions: [
                    ProviderSettingsActionDescriptor(
                        id: "kimi-open-console",
                        title: "Open Console",
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
