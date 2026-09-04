import AppKit
import CodexBarCore
import Foundation
import SwiftUI

struct HelmcodeProviderImplementation: ProviderImplementation {
    let id: UsageProvider = .helmcode

    @MainActor
    func presentation(context _: ProviderPresentationContext) -> ProviderPresentation {
        ProviderPresentation { context in
            context.store.sourceLabel(for: context.provider)
        }
    }

    @MainActor
    func observeSettings(_ settings: SettingsStore) {
        _ = settings.helmcodeCookieSource
        _ = settings.helmcodeCookieHeader
        _ = settings.helmcodeDeployment
    }

    @MainActor
    func settingsSnapshot(context: ProviderSettingsSnapshotContext) -> ProviderSettingsSnapshotContribution? {
        .helmcode(context.settings.helmcodeSettingsSnapshot(tokenOverride: context.tokenOverride))
    }

    @MainActor
    func settingsPickers(context: ProviderSettingsContext) -> [ProviderSettingsPickerDescriptor] {
        let deployment = context.settings.helmcodeDeployment
        let deploymentBinding = Binding(
            get: { context.settings.helmcodeDeployment.rawValue },
            set: { raw in
                context.settings.helmcodeDeployment = HelmcodeDeployment(rawValue: raw) ?? .helmcode
            })
        let deploymentOptions = HelmcodeDeployment.allCases.map {
            ProviderSettingsPickerOption(id: $0.rawValue, title: $0.displayName)
        }
        let cookieBinding = Binding(
            get: { context.settings.helmcodeCookieSource.rawValue },
            set: { raw in
                context.settings.helmcodeCookieSource = ProviderCookieSource(rawValue: raw) ?? .auto
            })
        let cookieOptions = ProviderCookieSourceUI.options(
            allowsOff: true,
            keychainDisabled: context.settings.debugDisableKeychainAccess)
        let subtitle: () -> String? = {
            ProviderCookieSourceUI.subtitle(
                source: context.settings.helmcodeCookieSource,
                keychainDisabled: context.settings.debugDisableKeychainAccess,
                auto: "Automatic imports \(deployment.dashboardHost) cookies from Chrome.",
                manual: "Paste a Cookie header or cURL capture from the \(deployment.displayName) dashboard.",
                off: "Helmcode dashboard cookies are disabled.")
        }

        return [
            ProviderSettingsPickerDescriptor(
                id: "helmcode-deployment",
                title: "Deployment",
                subtitle: "Helmcode Cloud is the enterprise dashboard. NaN Builders is the community " +
                    "dashboard with the same usage APIs.",
                binding: deploymentBinding,
                options: deploymentOptions,
                isVisible: nil,
                onChange: nil),
            ProviderSettingsPickerDescriptor(
                id: "helmcode-cookie-source",
                title: "Cookie source",
                subtitle: "Automatic imports Helmcode dashboard cookies from Chrome.",
                dynamicSubtitle: subtitle,
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
                id: "helmcode-cookie",
                title: "",
                subtitle: "",
                kind: .secure,
                placeholder: "Cookie: …",
                binding: context.stringBinding(\.helmcodeCookieHeader),
                actions: [
                    ProviderSettingsActionDescriptor(
                        id: "helmcode-open-dashboard",
                        title: "Open Dashboard",
                        style: .link,
                        isVisible: nil,
                        perform: {
                            let url = context.settings.helmcodeDeployment.dashboardCreditsURL
                            NSWorkspace.shared.open(url)
                        }),
                ],
                isVisible: { context.settings.helmcodeCookieSource == .manual },
                onActivate: { context.settings.ensureHelmcodeCookieLoaded() }),
        ]
    }
}
