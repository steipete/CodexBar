import AppKit
import CodexBarCore
import CodexBarMacroSupport
import Foundation
import SwiftUI

@ProviderImplementationRegistration
struct MistralProviderImplementation: ProviderImplementation {
    let id: UsageProvider = .mistral

    @MainActor
    func presentation(context _: ProviderPresentationContext) -> ProviderPresentation {
        ProviderPresentation { context in
            context.store.sourceLabel(for: context.provider)
        }
    }

    @MainActor
    func observeSettings(_ settings: SettingsStore) {
        _ = settings.mistralAPIToken
        _ = settings.mistralCookieSource
        _ = settings.mistralManualCookieHeader
    }

    @MainActor
    func settingsSnapshot(context: ProviderSettingsSnapshotContext) -> ProviderSettingsSnapshotContribution? {
        .mistral(context.settings.mistralSettingsSnapshot(tokenOverride: context.tokenOverride))
    }

    @MainActor
    func isAvailable(context: ProviderAvailabilityContext) -> Bool {
        if MistralSettingsReader.apiKey(environment: context.environment) != nil {
            return true
        }
        if !context.settings.mistralAPIToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return true
        }
        if context.settings.mistralCookieSource != .off {
            return true
        }
        if !context.settings.mistralManualCookieHeader.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return true
        }
        return false
    }

    @MainActor
    func defaultSourceLabel(context: ProviderSourceLabelContext) -> String? {
        context.settings.mistralCookieSource == .off ? "api" : "auto"
    }

    @MainActor
    func settingsPickers(context: ProviderSettingsContext) -> [ProviderSettingsPickerDescriptor] {
        let cookieBinding = Binding(
            get: { context.settings.mistralCookieSource.rawValue },
            set: { raw in
                context.settings.mistralCookieSource = ProviderCookieSource(rawValue: raw) ?? .auto
            })
        let options = ProviderCookieSourceUI.options(
            allowsOff: true,
            keychainDisabled: context.settings.debugDisableKeychainAccess)
        let subtitle: () -> String? = {
            ProviderCookieSourceUI.subtitle(
                source: context.settings.mistralCookieSource,
                keychainDisabled: context.settings.debugDisableKeychainAccess,
                auto: "Recommended. Sign into Mistral AI Studio in Chrome, open the usage page once, and CodexBar will pick up billing automatically.",
                manual: "Advanced. Paste a full Cookie header captured from Mistral AI Studio.",
                off: "API only. Uses your API key for model access while billing stays in Mistral AI Studio.")
        }

        return [
            ProviderSettingsPickerDescriptor(
                id: "mistral-cookie-source",
                title: "Usage source",
                subtitle: "Recommended. Sign into Mistral AI Studio in Chrome, open the usage page once, and CodexBar will pick up billing automatically.",
                dynamicSubtitle: subtitle,
                binding: cookieBinding,
                options: options,
                isVisible: nil,
                onChange: nil,
                trailingText: {
                    guard let entry = CookieHeaderCache.load(provider: .mistral) else { return nil }
                    let when = entry.storedAt.relativeDescription()
                    return "Cached: \(entry.sourceLabel) • \(when)"
                },
                actions: [
                    ProviderSettingsActionDescriptor(
                        id: "mistral-open-ai-studio-picker",
                        title: "Open AI Studio",
                        style: .link,
                        isVisible: nil,
                        perform: {
                            if let url = URL(string: "https://console.mistral.ai/usage") {
                                NSWorkspace.shared.open(url)
                            }
                        }),
                ]),
        ]
    }

    @MainActor
    func settingsFields(context: ProviderSettingsContext) -> [ProviderSettingsFieldDescriptor] {
        let apiKeyField = ProviderSettingsFieldDescriptor(
            id: "mistral-api-key",
            title: "API key (Optional)",
            subtitle: "Used for public API access, model discovery, and API-only fallback when web billing data is unavailable.",
            kind: .secure,
            placeholder: "Paste API key…",
            binding: context.stringBinding(\.mistralAPIToken),
            actions: [],
            isVisible: nil,
            onActivate: { context.settings.ensureMistralAPITokenLoaded() })

        let cookieField = ProviderSettingsFieldDescriptor(
            id: "mistral-cookie-header",
            title: "Cookie header (Advanced)",
            subtitle: "Paste the Cookie header from Mistral AI Studio. It should include an ory_session_* cookie and usually csrftoken.",
            kind: .secure,
            placeholder: "ory_session_…=…; csrftoken=…",
            binding: context.stringBinding(\.mistralManualCookieHeader),
            actions: [
                ProviderSettingsActionDescriptor(
                    id: "mistral-open-admin-usage",
                    title: "Open Usage Page",
                    style: .link,
                    isVisible: nil,
                    perform: {
                        if let url = URL(string: "https://console.mistral.ai/usage") {
                            NSWorkspace.shared.open(url)
                        }
                    }),
            ],
            isVisible: { context.settings.mistralCookieSource == .manual },
            onActivate: { context.settings.ensureMistralCookieLoaded() })

        return [
            apiKeyField,
            cookieField,
        ]
    }

    @MainActor
    func appendUsageMenuEntries(context: ProviderMenuUsageContext, entries: inout [ProviderMenuEntry]) {
        guard let summary = context.snapshot?.mistralUsage, summary.sourceKind == .web else { return }

        if let spendLine = self.mistralSpendLine(summary) {
            entries.append(.text(spendLine, .primary))
        }

        if let tokenLine = summary.tokenSummaryLine, !tokenLine.isEmpty {
            entries.append(.text(tokenLine, .secondary))
        }

        if summary.modelCount > 0 {
            let label = summary.modelCount == 1 ? "1 billed model" : "\(summary.modelCount) billed models"
            entries.append(.text(label, .secondary))
        }
        if let workspaceLine = summary.workspaceLine, !workspaceLine.isEmpty {
            entries.append(.text(workspaceLine, .secondary))
        }
    }

    private func mistralSpendLine(_ summary: MistralUsageSummarySnapshot) -> String? {
        guard let totalCost = summary.totalCost else { return nil }
        let amount: String
        if let currencyCode = summary.currencyCode {
            amount = UsageFormatter.currencyString(totalCost, currencyCode: currencyCode)
        } else if let currencySymbol = summary.currencySymbol {
            amount = currencySymbol + String(format: "%.4f", totalCost)
        } else {
            amount = String(format: "%.4f", totalCost)
        }
        if let period = summary.billingPeriodLabel {
            return "\(amount) in \(period)"
        }
        return amount
    }
}
