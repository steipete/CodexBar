import CodexBarCore
import Foundation

struct Sub2APIProviderImplementation: ProviderImplementation {
    let id: UsageProvider = .sub2api

    @MainActor
    func presentation(context _: ProviderPresentationContext) -> ProviderPresentation {
        ProviderPresentation { _ in "api" }
    }

    @MainActor
    func observeSettings(_ settings: SettingsStore) {
        _ = settings.sub2APIAPIKey
        _ = settings.sub2APIBaseURL
        _ = settings.tokenAccountsData(for: .sub2api)
    }

    @MainActor
    func isAvailable(context: ProviderAvailabilityContext) -> Bool {
        Sub2APISettingsReader.apiKey(environment: context.environment) != nil &&
            Sub2APISettingsReader.baseURL(environment: context.environment) != nil
    }

    @MainActor
    func settingsFields(context: ProviderSettingsContext) -> [ProviderSettingsFieldDescriptor] {
        [
            ProviderSettingsFieldDescriptor(
                id: "sub2api-api-key",
                title: "Fallback API key",
                subtitle: "Used when no group API key account is selected.",
                kind: .secure,
                placeholder: "sk-…",
                binding: context.stringBinding(\.sub2APIAPIKey),
                actions: [],
                isVisible: nil,
                onActivate: nil),
            ProviderSettingsFieldDescriptor(
                id: "sub2api-base-url",
                title: "Base URL",
                subtitle: "Base URL of your sub2api instance. HTTPS is required except for local loopback testing.",
                kind: .plain,
                placeholder: "https://sub2api.example.com",
                binding: context.stringBinding(\.sub2APIBaseURL),
                actions: [],
                isVisible: nil,
                onActivate: nil),
        ]
    }

    @MainActor
    func appendUsageMenuEntries(context: ProviderMenuUsageContext, entries: inout [ProviderMenuEntry]) {
        guard let usage = context.snapshot?.sub2APIUsage else { return }
        if let balance = usage.balance {
            let balanceText = UsageFormatter.convertedCostString(
                balance,
                preferredCurrency: context.settings.preferredCurrencyCode,
                providerCurrency: usage.unit)
            entries.append(.text("\(L("Balance")): \(balanceText)", .primary))
        }
        if let today = usage.today {
            let totals = self.totalsText(
                today,
                unit: usage.unit,
                preferredCurrencyCode: context.settings.preferredCurrencyCode)
            entries.append(.text("\(L("Today")): \(totals)", .secondary))
        }
        if let total = usage.total {
            let totals = self.totalsText(
                total,
                unit: usage.unit,
                preferredCurrencyCode: context.settings.preferredCurrencyCode)
            entries.append(.text("\(L("Total")): \(totals)", .secondary))
        }
    }

    private func totalsText(
        _ totals: Sub2APIUsageDetails.Totals,
        unit: String,
        preferredCurrencyCode: String) -> String
    {
        "\(UsageFormatter.tokenCountString(totals.requests)) \(L("requests")) · " +
            "\(UsageFormatter.tokenCountString(totals.totalTokens)) \(L("tokens")) · " +
            UsageFormatter.convertedCostString(
                totals.actualCostUSD,
                preferredCurrency: preferredCurrencyCode,
                providerCurrency: unit)
    }
}
