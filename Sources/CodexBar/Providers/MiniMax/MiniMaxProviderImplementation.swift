import AppKit
import CodexBarCore
import CodexBarMacroSupport
import Foundation
import SwiftUI

@ProviderImplementationRegistration
struct MiniMaxProviderImplementation: ProviderImplementation {
    let id: UsageProvider = .minimax

    @MainActor
    func settingsPickers(context: ProviderSettingsContext) -> [ProviderSettingsPickerDescriptor] {
        let cookieBinding = Binding(
            get: { context.settings.minimaxCookieSource.rawValue },
            set: { raw in
                context.settings.minimaxCookieSource = ProviderCookieSource(rawValue: raw) ?? .auto
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
            switch context.settings.minimaxCookieSource {
            case .auto:
                "Automatic imports browser cookies and local storage tokens."
            case .manual:
                "Paste a Cookie header or cURL capture from the Coding Plan page."
            case .off:
                "MiniMax cookies are disabled."
            }
        }

        let regionBinding = Binding(
            get: { context.settings.minimaxAPIRegion.rawValue },
            set: { raw in
                context.settings.minimaxAPIRegion = MiniMaxAPIRegion(rawValue: raw) ?? .global
            })
        let regionOptions = MiniMaxAPIRegion.allCases.map {
            ProviderSettingsPickerOption(id: $0.rawValue, title: $0.displayName)
        }

        return [
            ProviderSettingsPickerDescriptor(
                id: "minimax-cookie-source",
                title: "Cookie source",
                subtitle: "Automatic imports browser cookies and local storage tokens.",
                dynamicSubtitle: cookieSubtitle,
                binding: cookieBinding,
                options: cookieOptions,
                isVisible: nil,
                onChange: nil),
            ProviderSettingsPickerDescriptor(
                id: "minimax-region",
                title: "API region",
                subtitle: "Choose the MiniMax host (global .io or China mainland .com).",
                binding: regionBinding,
                options: regionOptions,
                isVisible: nil,
                onChange: nil),
        ]
    }

    @MainActor
    func settingsFields(context: ProviderSettingsContext) -> [ProviderSettingsFieldDescriptor] {
        [
            ProviderSettingsFieldDescriptor(
                id: "minimax-cookie",
                title: "",
                subtitle: "",
                kind: .secure,
                placeholder: "Cookie: …",
                binding: context.stringBinding(\.minimaxCookieHeader),
                actions: [
                    ProviderSettingsActionDescriptor(
                        id: "minimax-open-dashboard",
                        title: "Open Coding Plan",
                        style: .link,
                        isVisible: nil,
                        perform: {
                            let url = context.settings.minimaxAPIRegion.codingPlanURL
                            NSWorkspace.shared.open(url)
                        }),
                ],
                isVisible: { context.settings.minimaxCookieSource == .manual },
                onActivate: { context.settings.ensureMiniMaxCookieLoaded() }),
        ]
    }
}
