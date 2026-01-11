import AppKit
import CodexBarCore
import CodexBarMacroSupport
import Foundation
import SwiftUI

@ProviderImplementationRegistration
struct AmpProviderImplementation: ProviderImplementation {
    let id: UsageProvider = .amp

    @MainActor
    func settingsPickers(context: ProviderSettingsContext) -> [ProviderSettingsPickerDescriptor] {
        let cookieBinding = Binding(
            get: { context.settings.ampCookieSource.rawValue },
            set: { raw in
                context.settings.ampCookieSource = ProviderCookieSource(rawValue: raw) ?? .auto
            })
        let cookieOptions: [ProviderSettingsPickerOption] = [
            ProviderSettingsPickerOption(
                id: ProviderCookieSource.auto.rawValue,
                title: ProviderCookieSource.auto.displayName),
            ProviderSettingsPickerOption(
                id: ProviderCookieSource.manual.rawValue,
                title: ProviderCookieSource.manual.displayName),
        ]

        let cookieSubtitle: () -> String? = {
            switch context.settings.ampCookieSource {
            case .auto:
                "Automatic imports browser cookies."
            case .manual:
                "Paste a Cookie header or cURL capture from Amp settings."
            case .off:
                "Amp cookies are disabled."
            }
        }

        return [
            ProviderSettingsPickerDescriptor(
                id: "amp-cookie-source",
                title: "Cookie source",
                subtitle: "Automatic imports browser cookies.",
                dynamicSubtitle: cookieSubtitle,
                binding: cookieBinding,
                options: cookieOptions,
                isVisible: nil,
                onChange: nil),
        ]
    }

    @MainActor
    func settingsFields(context: ProviderSettingsContext) -> [ProviderSettingsFieldDescriptor] {
        [
            ProviderSettingsFieldDescriptor(
                id: "amp-cookie",
                title: "",
                subtitle: "",
                kind: .secure,
                placeholder: "Cookie: …",
                binding: context.stringBinding(\.ampCookieHeader),
                actions: [
                    ProviderSettingsActionDescriptor(
                        id: "amp-open-settings",
                        title: "Open Amp Settings",
                        style: .link,
                        isVisible: nil,
                        perform: {
                            if let url = URL(string: "https://ampcode.com/settings") {
                                NSWorkspace.shared.open(url)
                            }
                        }),
                ],
                isVisible: { context.settings.ampCookieSource == .manual },
                onActivate: { context.settings.ensureAmpCookieLoaded() }),
        ]
    }
}
