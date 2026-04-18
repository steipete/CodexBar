import AppKit
import CodexBarCore
import CodexBarMacroSupport
import Foundation
import SwiftUI

@ProviderImplementationRegistration
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
        let binding = Binding(
            get: { context.settings.alibabaCodingPlanAPIRegion.rawValue },
            set: { raw in
                context.settings
                    .alibabaCodingPlanAPIRegion = AlibabaCodingPlanAPIRegion(rawValue: raw) ?? .international
            })
        let options = AlibabaCodingPlanAPIRegion.allCases.map {
            ProviderSettingsPickerOption(id: $0.rawValue, title: $0.displayName)
        }

        let cookieBinding = Binding(
            get: { context.settings.alibabaCodingPlanCookieSource.rawValue },
            set: { raw in
                context.settings.alibabaCodingPlanCookieSource = ProviderCookieSource(rawValue: raw) ?? .auto
            })
        let cookieOptions = ProviderCookieSourceUI.options(
            allowsOff: false,
            keychainDisabled: context.settings.debugDisableKeychainAccess)
        let cookieSubtitle: () -> String? = {
            ProviderCookieSourceUI.subtitle(
                source: context.settings.alibabaCodingPlanCookieSource,
                keychainDisabled: context.settings.debugDisableKeychainAccess,
                auto: "Automatic imports browser cookies from Model Studio/Bailian.",
                manual: "Paste a Cookie header from modelstudio.console.alibabacloud.com.",
                off: "Alibaba cookies are disabled.")
        }

        return [
            ProviderSettingsPickerDescriptor(
                id: "alibaba-coding-plan-cookie-source",
                title: "Cookie source",
                subtitle: "Automatic imports browser cookies from Model Studio/Bailian.",
                dynamicSubtitle: cookieSubtitle,
                binding: cookieBinding,
                options: cookieOptions,
                isVisible: nil,
                onChange: nil,
                trailingText: {
                    guard let entry = CookieHeaderCache.load(provider: .alibaba) else { return nil }
                    let when = entry.storedAt.relativeDescription()
                    return "Cached: \(entry.sourceLabel) • \(when)"
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
                binding: context.stringBinding(\.alibabaCodingPlanAPIToken),
                actions: [
                    ProviderSettingsActionDescriptor(
                        id: "alibaba-coding-plan-open-dashboard",
                        title: "Open Coding Plan",
                        style: .link,
                        isVisible: nil,
                        perform: {
                            NSWorkspace.shared.open(context.settings.alibabaCodingPlanAPIRegion.dashboardURL)
                        }),
                ],
                isVisible: nil,
                onActivate: { context.settings.ensureAlibabaCodingPlanAPITokenLoaded() }),
            ProviderSettingsFieldDescriptor(
                id: "alibaba-coding-plan-cookie",
                title: "Cookie header",
                subtitle: "",
                kind: .secure,
                placeholder: "Cookie: ...",
                binding: context.stringBinding(\.alibabaCodingPlanCookieHeader),
                actions: [
                    ProviderSettingsActionDescriptor(
                        id: "alibaba-coding-plan-open-dashboard-cookie",
                        title: "Open Coding Plan",
                        style: .link,
                        isVisible: nil,
                        perform: {
                            NSWorkspace.shared.open(context.settings.alibabaCodingPlanAPIRegion.dashboardURL)
                        }),
                ],
                isVisible: {
                    context.settings.alibabaCodingPlanCookieSource == .manual
                },
                onActivate: nil),
        ]
    }
}
