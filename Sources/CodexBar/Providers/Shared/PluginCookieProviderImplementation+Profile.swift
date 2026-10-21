import CodexBarCore
import Foundation
import SweetCookieKit
import SwiftUI

extension PluginCookieProviderImplementation {
    @MainActor
    func browserPicker(browsers: [String], context: ProviderSettingsContext) -> ProviderSettingsPickerDescriptor {
        var options = browsers.map {
            ProviderSettingsPickerOption(id: $0, title: Browser(rawValue: $0)?.displayName ?? $0)
        }
        if let saved = context.settings.providerConfig(for: self.id)?.browserID, !browsers.contains(saved) {
            options.append(.init(id: saved, title: saved))
        }
        return ProviderSettingsPickerDescriptor(
            id: "browser",
            title: L("Browser"),
            subtitle: "",
            binding: Binding(
                get: {
                    let config = context.settings.providerConfig(for: self.id)
                    return ProviderBrowserProfile.selected(in: config, browsers: browsers)?.browserID ?? config?
                        .browserID ?? ""
                },
                set: { value in
                    guard browsers.contains(value),
                          value != ProviderBrowserProfile.selected(
                              in: context.settings.providerConfig(for: self.id), browsers: browsers)?.browserID
                    else { return }
                    context.store.clearProviderState(self.id)
                    context.settings.updateProviderConfig(provider: self.id) {
                        $0.browserID = value
                        $0.browserProfileID = nil
                    }
                }),
            options: options,
            isVisible: nil,
            onChange: nil)
    }

    @MainActor
    func browserProfilePicker(
        browser: String,
        context: ProviderSettingsContext,
        profiles: [BrowserProfile]? = nil) -> ProviderSettingsPickerDescriptor
    {
        let browser = Browser(rawValue: browser)
        let profiles = profiles ?? browser.flatMap { try? BrowserCookieClient().codexBarStores(for: $0) }?
            .compactMap(ProviderBrowserProfile.selectableProfile) ?? []
        var seen = Set<String>()
        var options = [ProviderSettingsPickerOption(id: "", title: L("Select profile…"))]
        options += profiles.filter { seen.insert($0.id).inserted }.map {
            ProviderSettingsPickerOption(id: $0.id, title: $0.name)
        }
        if let saved = context.settings.providerConfig(for: self.id)?.browserProfileID,
           !saved.isEmpty, !seen.contains(saved)
        {
            options.append(.init(
                id: saved,
                title: L("Unavailable profile: %@", URL(fileURLWithPath: saved).lastPathComponent)))
        }
        return ProviderSettingsPickerDescriptor(
            id: "browser-profile",
            title: L("Browser profile"),
            subtitle: L(
                "Read only the selected %@ profile. Accounts are never selected automatically.",
                browser?.displayName ?? "browser"),
            binding: Binding(
                get: { context.settings.providerConfig(for: self.id)?.browserProfileID ?? "" },
                set: { value in
                    guard let browsers = self.spec.webSource?.settingsSection?.selectedProfileBrowsers,
                          let selected = ProviderBrowserProfile.selected(
                              in: context.settings.providerConfig(for: self.id), browsers: browsers),
                          selected.browserID == browser?.rawValue
                    else { return }
                    context.store.clearProviderState(self.id)
                    context.settings.updateProviderConfig(provider: self.id) {
                        $0.browserProfileID = value.isEmpty ? nil : value
                    }
                }),
            options: options,
            isVisible: nil,
            onChange: nil,
            trailingActions: [ProviderCookieRefreshAction.descriptor(
                provider: self.id, cookieSource: { .auto }, context: context)])
    }
}
