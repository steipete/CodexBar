import AppKit
import CodexBarCore
import SwiftUI

struct PluginCookieProviderImplementation: ProviderImplementation {
    let spec: PluginProviderSpec
    var fieldActions: (@MainActor @Sendable (ProviderSettingsContext) -> [ProviderSettingsActionDescriptor])?
    var trailingText: (@MainActor @Sendable () -> String?)?
    var id: UsageProvider {
        self.spec.id
    }

    private var web: PluginProviderSpec.WebSource {
        self.spec.webSource!
    }

    var supportsLoginFlow: Bool {
        self.web.loginURL != nil
    }

    @MainActor
    func presentation(context _: ProviderPresentationContext) -> ProviderPresentation {
        ProviderPresentation(showsVersionInSettings: self.web.showsVersionInSettings) { context in
            self.web.detailLine ?? ProviderPresentation.standardDetailLine(context: context)
        }
    }

    @MainActor
    func runLoginFlow(context _: ProviderLoginContext) async -> Bool {
        if let url = self.web.loginURL.flatMap(URL.init(string:)) { NSWorkspace.shared.open(url) }
        return false
    }

    @MainActor
    func observeSettings(_ settings: SettingsStore) {
        if self.web.settingsSection?.selectedProfileBrowsers != nil {
            _ = settings.providerConfig(for: self.id)?.browserID
            _ = settings.providerConfig(for: self.id)?.browserProfileID
        }
        _ = settings.resolvedCookieSource(provider: self.id, fallback: .auto)
        _ = settings[providerConfig: self.id, field: .cookieHeader]
        if self.spec.apiKeyField != nil { _ = settings[providerConfig: self.id, field: .apiKey] }
    }

    @MainActor
    func settingsSnapshot(context: ProviderSettingsSnapshotContext) -> ProviderSettingsSnapshotContribution? {
        let section = ProviderDescriptorRegistry.descriptor(for: self.id).settingsSection
        if section.selectedProfileBrowsers != nil {
            return section.credentialContribution(context: ProviderCredentialSettingsContext(
                config: context.settings.providerConfig(for: self.id), account: nil))
        }
        return section.cookieContribution?(context.settings.resolvedCookieSettings(
            provider: self.id, tokenOverride: context.tokenOverride)) ?? section.defaultContribution
    }

    @MainActor
    func isAvailable(context: ProviderAvailabilityContext) -> Bool {
        self.web.availability(context.environment)
    }

    @MainActor
    func tokenAccountsVisibility(context: ProviderSettingsContext, support: TokenAccountSupport) -> Bool {
        !support.requiresManualCookieSource || self.source(context.settings) == .manual
            || !context.settings.tokenAccounts(for: self.id).isEmpty
    }

    @MainActor
    func applyTokenAccountCookieSource(settings: SettingsStore) {
        guard ProviderDescriptorRegistry.descriptor(for: self.id).credentials?
            .tokenAccountSupport?.requiresManualCookieSource == true, self.source(settings) != .manual else { return }
        settings.setCookieSource(.manual, provider: self.id)
    }

    @MainActor
    private func source(_ settings: SettingsStore) -> ProviderCookieSource {
        settings.resolvedCookieSource(provider: self.id, fallback: .auto)
    }

    @MainActor
    private var cookieBrowserHint: String {
        L(
            "Supported browsers: %@. Use Manual for other browsers.",
            BrowserCookieImportSupport.browserNames(for: self.id))
    }

    @MainActor
    func settingsPickers(context: ProviderSettingsContext) -> [ProviderSettingsPickerDescriptor] {
        if let browsers = self.web.settingsSection?.selectedProfileBrowsers {
            let profile = ProviderBrowserProfile.selected(
                in: context.settings.providerConfig(for: self.id),
                browsers: browsers)
            return [
                self.browserPicker(browsers: browsers, context: context),
                self.browserProfilePicker(browser: profile?.browserID ?? "", context: context),
            ]
        }
        guard let picker = self.web.picker else { return [] }
        return [ProviderSettingsPickerDescriptor(
            id: picker.id,
            title: "Cookie source",
            subtitle: picker.auto.localized + " " + self.cookieBrowserHint,
            dynamicSubtitle: {
                ProviderCookieSourceUI.subtitle(
                    source: self.source(context.settings),
                    keychainDisabled: context.settings.debugDisableKeychainAccess,
                    auto: picker.auto.localized + " " + self.cookieBrowserHint,
                    manual: picker.manual.localized,
                    off: picker.off.localized)
            },
            binding: Binding(
                get: { self.source(context.settings).rawValue },
                set: { context.settings.setCookieSource(ProviderCookieSource(rawValue: $0) ?? .auto, provider: self.id)
                }),
            options: ProviderCookieSourceUI.options(
                allowsOff: picker.allowsOff, keychainDisabled: context.settings.debugDisableKeychainAccess),
            isVisible: nil,
            onChange: nil,
            trailingText: self.trailingText ?? (picker.showsRefreshAction ? {
                ProviderCookieRefreshAction.trailingText(
                    provider: self.id, cookieSource: self.source(context.settings), context: context)
            } : nil),
            trailingActions: picker.showsRefreshAction ? [ProviderCookieRefreshAction.descriptor(
                provider: self.id, cookieSource: { self.source(context.settings) }, context: context)] : [])]
    }

    @MainActor
    func settingsFields(context: ProviderSettingsContext) -> [ProviderSettingsFieldDescriptor] {
        if self.web.settingsSection?.selectedProfileBrowsers != nil { return [] }
        let field = self.web.field
        return [ProviderSettingsFieldDescriptor(
            id: field.id,
            title: field.title,
            subtitle: field.subtitle,
            kind: .secure,
            placeholder: field.placeholder,
            binding: context.providerConfigBinding(.cookieHeader),
            actions: self.fieldActions?(context) ?? field.action.map {
                [.openURL(id: $0.id, title: $0.title, url: URL(string: $0.url))]
            } ?? [],
            isVisible: self.web.picker == nil ? nil : { self.source(context.settings) == .manual })]
            + PluginAPIKeyProviderImplementation(spec: self.spec).settingsFields(context: context)
    }
}

extension PluginProviderSpec.CookiePicker.Text {
    @MainActor
    fileprivate var localized: String {
        switch self {
        case let .literal(text): text
        case let .localized(key, argument): argument.map { L(key, $0) } ?? L(key)
        }
    }
}
