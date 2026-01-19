import CodexBarCore
import CodexBarMacroSupport
import Foundation
import SwiftUI

@ProviderImplementationRegistration
struct FactoryProviderImplementation: ProviderImplementation {
    let id: UsageProvider = .factory
    let supportsLoginFlow: Bool = true

    @MainActor
    func settingsPickers(context: ProviderSettingsContext) -> [ProviderSettingsPickerDescriptor] {
        let cookieBinding = Binding(
            get: { context.settings.factoryCookieSource.rawValue },
            set: { raw in
                context.settings.factoryCookieSource = ProviderCookieSource(rawValue: raw) ?? .auto
            })
        let cookieOptions = ProviderCookieSourceUI.options(
            allowsOff: false,
            keychainDisabled: context.settings.debugDisableKeychainAccess)

        let cookieSubtitle: () -> String? = {
            ProviderCookieSourceUI.subtitle(
                source: context.settings.factoryCookieSource,
                keychainDisabled: context.settings.debugDisableKeychainAccess,
                auto: "Automatic imports browser cookies and WorkOS tokens.",
                manual: "Paste a Cookie header from app.factory.ai.",
                off: "Factory cookies are disabled.")
        }

        return [
            ProviderSettingsPickerDescriptor(
                id: "factory-cookie-source",
                title: "Cookie source",
                subtitle: "Automatic imports browser cookies and WorkOS tokens.",
                dynamicSubtitle: cookieSubtitle,
                binding: cookieBinding,
                options: cookieOptions,
                isVisible: nil,
                onChange: nil,
                trailingText: {
                    guard let entry = CookieHeaderCache.load(provider: .factory) else { return nil }
                    let when = entry.storedAt.relativeDescription()
                    return "Cached: \(entry.sourceLabel) • \(when)"
                }),
        ]
    }

    @MainActor
    func settingsFields(context: ProviderSettingsContext) -> [ProviderSettingsFieldDescriptor] {
        _ = context
        return []
    }

    @MainActor
    func runLoginFlow(context: ProviderLoginContext) async -> Bool {
        await context.controller.runFactoryLoginFlow()
        return true
    }
}
