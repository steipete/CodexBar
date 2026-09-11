import AppKit
import CodexBarCore
import Foundation

struct DevinProviderImplementation: ProviderImplementation {
    let id: UsageProvider = .devin
    let supportsLoginFlow: Bool = true

    @MainActor
    func presentation(context _: ProviderPresentationContext) -> ProviderPresentation {
        ProviderPresentation { context in
            context.store.sourceLabel(for: context.provider)
        }
    }

    @MainActor
    func observeSettings(_ settings: SettingsStore) {
        _ = settings.devinCookieSource
        _ = settings.devinBearerToken
        _ = settings.devinOrganization
        _ = settings.devinAPIHost
    }

    @MainActor
    func settingsSnapshot(context: ProviderSettingsSnapshotContext) -> ProviderSettingsSnapshotContribution? {
        .devin(context.settings.devinSettingsSnapshot(tokenOverride: context.tokenOverride))
    }

    @MainActor
    func settingsPickers(context: ProviderSettingsContext) -> [ProviderSettingsPickerDescriptor] {
        [
            ProviderCookieSourceUI.picker(
                id: "devin-cookie-source",
                context: context,
                source: \.devinCookieSource,
                allowsOff: false,
                subtitles: {
                    .init(
                        auto: L("Automatically imports the app.devin.ai session from Chrome."),
                        manual: L("Paste an Authorization Bearer token from app.devin.ai."),
                        off: L("Paste an Authorization Bearer token from app.devin.ai."))
                },
                title: "Auth source"),
        ]
    }

    @MainActor
    func settingsFields(context: ProviderSettingsContext) -> [ProviderSettingsFieldDescriptor] {
        [
            ProviderSettingsFieldDescriptor(
                id: "devin-organization",
                title: "Organization",
                subtitle: "Optional for automatic auth. Use a slug, URL, or internal org-... / org_... ID. " +
                    "Manual auth may need the x-cog-org-id header from a successful Devin quota request.",
                kind: .plain,
                placeholder: "org/example-org",
                binding: context.binding(\.devinOrganization),
                actions: [
                    ProviderSettingsActionDescriptor.openURL(
                        id: "devin-open-usage",
                        title: "Open Devin Usage",
                        url: Self.usageURL(
                            organization: context.settings.devinOrganization,
                            enterpriseHost: context.settings.devinAPIHost)),
                ],
                isVisible: nil),
            ProviderSettingsFieldDescriptor(
                id: "devin-bearer-token",
                title: "Bearer token",
                subtitle: "Paste the Authorization header value from app.devin.ai.",
                kind: .secure,
                placeholder: "Bearer eyJ...",
                binding: context.binding(\.devinBearerToken),
                actions: [],
                isVisible: { context.settings.devinCookieSource == .manual }),
            ProviderSettingsFieldDescriptor(
                id: "devin-enterprise-host",
                title: "Enterprise host",
                subtitle: "Optional. For Devin Enterprise deployments, enter your host " +
                    "(e.g. your-team.devinenterprise.com) to track your personal monthly ACU cycle.",
                kind: .plain,
                placeholder: "your-team.devinenterprise.com",
                binding: context.binding(\.devinAPIHost),
                actions: [],
                isVisible: nil),
        ]
    }

    @MainActor
    func loginMenuAction(context: ProviderMenuLoginContext)
        -> (label: String, action: MenuDescriptor.MenuAction)?
    {
        (
            "Open Devin...",
            .loginToProvider(url: Self.usageURL(
                organization: nil,
                enterpriseHost: context.settings.devinAPIHost).absoluteString))
    }

    @MainActor
    func runLoginFlow(context: ProviderLoginContext) async -> Bool {
        let organization = context.controller.settings.devinOrganization
        NSWorkspace.shared.open(Self.usageURL(
            organization: organization,
            enterpriseHost: context.controller.settings.devinAPIHost))
        return false
    }

    private static func usageURL(organization: String?, enterpriseHost: String? = nil) -> URL {
        // Enterprise deployments expose the user's personal ACU cycle on the My analytics page.
        if let host = DevinUsageFetcher.customHost(enterpriseHost) {
            return host.appending(path: "settings/my-analytics")
        }
        let normalized = DevinUsageFetcher.normalizedOrganization(organization)
        let urlString: String
        if let normalized, normalized.hasPrefix("org/") {
            let slug = String(normalized.dropFirst(4))
            urlString = "https://app.devin.ai/org/\(slug)/settings/usage"
        } else {
            urlString = "https://app.devin.ai/settings/usage"
        }
        return URL(string: urlString) ?? URL(string: "https://app.devin.ai")!
    }

    @MainActor
    func appendUsageMenuEntries(context: ProviderMenuUsageContext, entries: inout [ProviderMenuEntry]) {
        guard context.settings.showOptionalCreditsAndExtraUsage,
              let cost = context.snapshot?.providerCost,
              cost.period == "Extra usage balance"
        else { return }

        let balance = UsageFormatter.convertedCostString(
            cost.used,
            preferredCurrency: context.settings.preferredCurrencyCode,
            providerCurrency: cost.currencyCode)
        entries.append(.text(L("Extra usage balance: %@", balance), .primary))
    }
}
