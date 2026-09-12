import AppKit
import CodexBarCore
import Foundation

struct GrokProviderImplementation: ProviderImplementation {
    let id: UsageProvider = .grok

    @MainActor
    func observeSettings(_ settings: SettingsStore) {
        _ = settings.grokUsageDataSource
        _ = settings.grokCookieSource
        _ = settings.grokCookieHeader
    }

    @MainActor
    func sourceMode(context: ProviderSourceModeContext) -> ProviderSourceMode {
        context.settings.grokUsageDataSource
    }

    @MainActor
    func openTokenFile(context _: ProviderSettingsContext) -> Bool {
        let url = GrokCredentialsStore.tokenFileURLToOpen()
        try? FileManager.default.createDirectory(
            at: GrokCredentialsStore.grokHomeURL(),
            withIntermediateDirectories: true)
        NSWorkspace.shared.open(url)
        return true
    }

    @MainActor
    func settingsSnapshot(context: ProviderSettingsSnapshotContext)
        -> ProviderSettingsSnapshotContribution?
    {
        .grok(context.settings.grokSettingsSnapshot(tokenOverride: context.tokenOverride))
    }

    @MainActor
    func settingsPickers(context: ProviderSettingsContext) -> [ProviderSettingsPickerDescriptor] {
        let sourceBinding = context.rawValueBinding(\.grokUsageDataSource, fallback: .auto)
        let sourceOptions: [ProviderSettingsPickerOption] = [
            ProviderSettingsPickerOption(id: ProviderSourceMode.auto.rawValue, title: "Auto"),
            ProviderSettingsPickerOption(id: ProviderSourceMode.cli.rawValue, title: "Grok CLI"),
            ProviderSettingsPickerOption(
                id: ProviderSourceMode.oauth.rawValue,
                title: "SuperGrok OAuth"),
            ProviderSettingsPickerOption(
                id: ProviderSourceMode.web.rawValue, title: "Browser cookies"),
        ]
        return [
            ProviderSettingsPickerDescriptor(
                id: "grok-usage-source",
                title: "Usage source",
                subtitle:
                "Auto tries the Grok CLI, SuperGrok OAuth, browser cookies, then bearer gRPC.",
                binding: sourceBinding,
                options: sourceOptions,
                isVisible: nil,
                onChange: nil),
            ProviderCookieSourceUI.picker(
                id: "grok-cookie-source",
                context: context,
                source: \.grokCookieSource,
                allowsOff: true,
                subtitles: {
                    .init(
                        auto: "Automatic imports grok.com cookies from Chrome.",
                        manual: "Paste a Cookie header from a grok.com request.",
                        off: "Grok cookies are disabled.")
                },
                isVisible: {
                    context.settings.grokUsageDataSource == .auto
                        || context.settings.grokUsageDataSource == .web
                },
                onChange: nil),
        ]
    }

    @MainActor
    func settingsFields(context: ProviderSettingsContext) -> [ProviderSettingsFieldDescriptor] {
        [
            ProviderSettingsFieldDescriptor(
                id: "grok-cookie",
                title: "",
                subtitle: "",
                kind: .secure,
                placeholder: "Cookie: …",
                binding: context.binding(\.grokCookieHeader),
                actions: [
                    ProviderSettingsActionDescriptor.openURL(
                        id: "grok-open-usage",
                        title: "Open grok.com usage",
                        url: URL(string: "https://grok.com/?_s=usage")),
                ],
                isVisible: {
                    (context.settings.grokUsageDataSource == .auto
                        || context.settings.grokUsageDataSource == .web)
                        && context.settings.grokCookieSource == .manual
                }),
        ]
    }
}
