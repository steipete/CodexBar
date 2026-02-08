import CodexBarCore
import CodexBarMacroSupport
import Foundation
import SwiftUI

@ProviderImplementationRegistration
struct AntigravityProviderImplementation: ProviderImplementation {
    let id: UsageProvider = .antigravity
    let supportsLoginFlow: Bool = true

    @MainActor
    func presentation(context _: ProviderPresentationContext) -> ProviderPresentation {
        ProviderPresentation { context in
            let sourceLabel = context.store.sourceLabel(for: .antigravity)
            switch sourceLabel.lowercased() {
            case "oauth", "manual":
                return "oauth"
            case "local server":
                return "local"
            default:
                return "not detected"
            }
        }
    }

    func detectVersion(context _: ProviderVersionContext) async -> String? {
        await AntigravityStatusProbe.detectVersion()
    }

    @MainActor
    func settingsSnapshot(context: ProviderSettingsSnapshotContext) -> ProviderSettingsSnapshotContribution? {
        .antigravity(context.settings.antigravitySettingsSnapshot(tokenOverride: context.tokenOverride))
    }

    @MainActor
    func runLoginFlow(context: ProviderLoginContext) async -> Bool {
        await context.controller.runAntigravityLoginFlow()
    }

    @MainActor
    func sourceMode(context: ProviderSourceModeContext) -> ProviderSourceMode {
        switch context.settings.antigravityUsageSource {
        case .auto: .auto
        case .authorized: .oauth
        case .local: .cli
        }
    }

    @MainActor
    func settingsPickers(context: ProviderSettingsContext) -> [ProviderSettingsPickerDescriptor] {
        let usageBinding = Binding<String>(
            get: { context.settings.antigravityUsageSource.rawValue },
            set: {
                if let source = AntigravityUsageSource(rawValue: $0) {
                    context.settings.antigravityUsageSource = source
                }
            })

        let usageOptions = AntigravityUsageSource.allCases.map {
            ProviderSettingsPickerOption(id: $0.rawValue, title: $0.displayName)
        }

        return [
            ProviderSettingsPickerDescriptor(
                id: "antigravity-usage-source",
                title: "Usage source",
                subtitle: "Choose how to fetch Antigravity usage data.",
                dynamicSubtitle: {
                    switch context.settings.antigravityUsageSource {
                    case .auto:
                        "Auto: Try OAuth/manual first, fallback to local server"
                    case .authorized:
                        "OAuth: Use OAuth account or manual tokens only"
                    case .local:
                        "Local: Use Antigravity local server only"
                    }
                },
                binding: usageBinding,
                options: usageOptions,
                isVisible: nil,
                onChange: nil,
                trailingText: {
                    let label = context.store.sourceLabel(for: .antigravity)
                    return label.isEmpty ? nil : label
                }),
        ]
    }

    @MainActor
    func tokenAccountsVisibility(context _: ProviderSettingsContext, support _: TokenAccountSupport) -> Bool {
        true
    }
}
