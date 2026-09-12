import CodexBarCore
import Foundation

struct AlibabaCodingPlanProviderImplementation: ProviderImplementation {
    let id: UsageProvider = .alibaba

    @MainActor
    func presentation(context _: ProviderPresentationContext) -> ProviderPresentation {
        ProviderPresentation { context in
            context.store.sourceLabel(for: context.provider)
        }
    }

    @MainActor
    func observeSettings(_ settings: SettingsStore) {
        _ = settings.alibabaCodingPlanAPIToken
        _ = settings.alibabaCodingPlanCookieSource
        _ = settings.alibabaCodingPlanCookieHeader
        _ = settings.alibabaCodingPlanAPIRegion
    }

    @MainActor
    func settingsSnapshot(context: ProviderSettingsSnapshotContext) -> ProviderSettingsSnapshotContribution? {
        _ = context
        return .alibaba(context.settings.alibabaCodingPlanSettingsSnapshot())
    }

    @MainActor
    func settingsPickers(context: ProviderSettingsContext) -> [ProviderSettingsPickerDescriptor] {
        let binding = context.rawValueBinding(\.alibabaCodingPlanAPIRegion, fallback: .international)
        let options = AlibabaCodingPlanAPIRegion.allCases.map {
            ProviderSettingsPickerOption(id: $0.rawValue, title: $0.displayName)
        }

        return [
            ProviderCookieSourceUI.picker(
                id: "alibaba-coding-plan-cookie-source",
                context: context,
                source: \.alibabaCodingPlanCookieSource,
                allowsOff: false,
                subtitles: {
                    .init(
                        auto: "Automatic imports browser cookies from Model Studio/Bailian.",
                        manual: "Paste a Cookie header from modelstudio.console.alibabacloud.com.",
                        off: "Alibaba cookies are disabled.")
                },
                trailingText: {
                    ProviderCookieSourceUI.cachedTrailingText(provider: .alibaba)
                }),
            ProviderSettingsPickerDescriptor(
                id: "alibaba-coding-plan-region",
                title: "Gateway region",
                subtitle: "Use international or China mainland console gateways for quota fetches.",
                binding: binding,
                options: options,
                isVisible: nil,
                onChange: nil),
        ]
    }

    @MainActor
    func settingsFields(context: ProviderSettingsContext) -> [ProviderSettingsFieldDescriptor] {
        [
            ProviderSettingsFieldDescriptor(
                id: "alibaba-coding-plan-api-key",
                title: "API key",
                subtitle: "Stored in ~/.codexbar/config.json. Paste your Coding Plan API key from Model Studio.",
                kind: .secure,
                placeholder: "cpk-...",
                binding: context.binding(\.alibabaCodingPlanAPIToken),
                actions: [
                    ProviderSettingsActionDescriptor.openURL(
                        id: "alibaba-coding-plan-open-dashboard",
                        title: "Open Coding Plan",
                        url: context.settings.alibabaCodingPlanAPIRegion.dashboardURL),
                ],
                isVisible: nil),
            ProviderSettingsFieldDescriptor(
                id: "alibaba-coding-plan-cookie",
                title: "Cookie header",
                subtitle: "",
                kind: .secure,
                placeholder: "Cookie: ...",
                binding: context.binding(\.alibabaCodingPlanCookieHeader),
                actions: [
                    ProviderSettingsActionDescriptor.openURL(
                        id: "alibaba-coding-plan-open-dashboard-cookie",
                        title: "Open Coding Plan",
                        url: context.settings.alibabaCodingPlanAPIRegion.dashboardURL),
                ],
                isVisible: {
                    context.settings.alibabaCodingPlanCookieSource == .manual
                }),
        ]
    }
}
