import CodexBarCore
import Foundation

struct HelmcodeProviderImplementation: ProviderImplementation {
    let id: UsageProvider = .helmcode

    @MainActor
    func settingsSnapshot(context: ProviderSettingsSnapshotContext) -> ProviderSettingsSnapshotContribution? {
        let cookies: CookieProviderSettings = context.settings.resolvedCookieSettings(
            provider: self.id, tokenOverride: context.tokenOverride)
        return .init(HelmcodeProviderSettings(
            cookieSource: cookies.cookieSource,
            manualCookieHeader: cookies.manualCookieHeader,
            manualTenant: context.settings.helmcodeManualTenant), for: HelmcodeProviderSettingsKey.self)
    }

    @MainActor
    func settingsPickers(context: ProviderSettingsContext) -> [ProviderSettingsPickerDescriptor] {
        [
            ProviderCookieSourceUI.picker(
                id: "helmcode-cookie-source",
                context: context,
                source: \.helmcodeCookieSource,
                allowsOff: true,
                subtitles: {
                    .init(
                        auto: "Imports Chrome sessions for Helmcode Cloud or NaN Builders; Cloud is preferred.",
                        manual: "Paste a Cookie header and select its tenant below.",
                        off: "Helmcode dashboard cookies are disabled.")
                }),
            ProviderSettingsPickerDescriptor(
                id: "helmcode-manual-tenant",
                title: "Manual cookie tenant",
                subtitle: "The pasted header is sent only to this tenant.",
                binding: context.binding(\.helmcodeManualTenant),
                options: [
                    .init(id: "helmcode", title: "Helmcode Cloud"),
                    .init(id: "nanBuilders", title: "NaN Builders"),
                ],
                isVisible: { context.settings.helmcodeCookieSource == .manual },
                onChange: nil),
        ]
    }

    @MainActor
    func settingsFields(context: ProviderSettingsContext) -> [ProviderSettingsFieldDescriptor] {
        [ProviderSettingsFieldDescriptor(
            id: "helmcode-cookie",
            title: "Cookie header",
            subtitle: "Copy the Cookie request header from your tenant's dashboard. cURL captures are not supported.",
            kind: .secure,
            placeholder: "Cookie: …",
            binding: context.binding(\.helmcodeCookieHeader),
            actions: [],
            isVisible: { context.settings.helmcodeCookieSource == .manual })]
    }
}

extension SettingsStore {
    var helmcodeCookieHeader: String {
        get { self[providerConfig: .helmcode, field: .cookieHeader] }
        set { self[providerConfig: .helmcode, field: .cookieHeader] = newValue }
    }

    var helmcodeCookieSource: ProviderCookieSource {
        get { self.resolvedCookieSource(provider: .helmcode, fallback: .auto) }
        set { self.setCookieSource(newValue, provider: .helmcode) }
    }

    var helmcodeManualTenant: String {
        get { self.configSnapshot.providerConfig(for: .helmcode)?.region == "nanBuilders" ? "nanBuilders" : "helmcode" }
        set { self.updateProviderConfig(provider: .helmcode) { $0.region = newValue } }
    }
}
