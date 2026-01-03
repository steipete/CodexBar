import AppKit
import CodexBarCore
import CodexBarMacroSupport
import Foundation
import SwiftUI

@ProviderImplementationRegistration
struct AugmentProviderImplementation: ProviderImplementation {
    let id: UsageProvider = .augment

    @MainActor
    func settingsPickers(context: ProviderSettingsContext) -> [ProviderSettingsPickerDescriptor] {
        let cookieBinding = Binding(
            get: { context.settings.augmentCookieSource.rawValue },
            set: { raw in
                context.settings.augmentCookieSource = ProviderCookieSource(rawValue: raw) ?? .auto
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
            switch context.settings.augmentCookieSource {
            case .auto:
                "Automatic imports browser cookies."
            case .manual:
                "Paste a Cookie header or cURL capture from the Augment dashboard."
            case .off:
                "Augment cookies are disabled."
            }
        }

        return [
            ProviderSettingsPickerDescriptor(
                id: "augment-cookie-source",
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
                id: "augment-cookie",
                title: "",
                subtitle: "",
                kind: .secure,
                placeholder: "Cookie: …",
                binding: context.stringBinding(\.augmentCookieHeader),
                actions: [
                    ProviderSettingsActionDescriptor(
                        id: "augment-open-dashboard",
                        title: "Open Augment",
                        style: .link,
                        isVisible: nil,
                        perform: {
                            if let url = URL(string: "https://augmentcode.com") {
                                NSWorkspace.shared.open(url)
                            }
                        }),
                ],
                isVisible: { context.settings.augmentCookieSource == .manual },
                onActivate: { context.settings.ensureAugmentCookieLoaded() }),
        ]
    }
}

