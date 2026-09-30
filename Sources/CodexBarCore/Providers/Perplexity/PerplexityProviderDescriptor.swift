import Foundation

public enum PerplexityProviderDescriptor {
    public static let descriptor: ProviderDescriptor = Self.spec.makeDescriptor(credentials: Self.credentials)
    public static let spec = PluginProviderSpec(
        id: .perplexity,
        displayName: "Perplexity",
        shortDisplayName: "Pplx",
        sessionLabel: "Credits",
        weeklyLabel: "Bonus credits",
        opusLabel: "Purchased",
        sharePlanLabels: ["pro": "Pro", "max": "Max"],
        usesDetailBackedWindow: true,
        dashboardURL: "https://www.perplexity.ai/account/usage",
        statusLinkURL: "https://status.perplexity.com/",
        color: ProviderColor(hex: 0x20B2AA),
        confetti: [0x016A71, 0x313131, 0xFDFBFA],
        noDataMessage: "Perplexity cost tracking is not supported.",
        menuBarMetrics: ProviderMenuBarMetricCapabilities(
            supported: [.automatic, .primary, .secondary, .tertiary]),
        presentation: ProviderUsagePresentation(
            iconWindowResolver: { context in
                let windows = context.snapshot.orderedPerplexityDisplayWindows()
                return ProviderUsageWindowPair(primary: windows.first, secondary: windows.dropFirst().first)
            },
            semanticWindowResolver: { snapshot in
                ProviderSemanticWindows(session: snapshot.primary, weekly: snapshot.secondary)
            },
            menuBarLayoutSecondaryLabel: "Bonus credits",
            requestedMenuBarLaneOrders: [
                .primary: [.primary, .secondary, .tertiary],
                .secondary: [.secondary, .tertiary, .primary],
                .tertiary: [.tertiary, .secondary, .primary],
            ],
            automaticSelectionPrioritizesExhaustedWindow: false,
            menuBarWindowResolver: { context in
                guard context.metric == .automatic else { return .unhandled }
                return .resolved(context.snapshot.automaticPerplexityWindow())
            },
            menu: ProviderMenuDescriptorPresentation(
                secondaryDescriptionMode: .resetOverride,
                tertiaryDescriptionOverridesReset: true)),
        webSource: .init(
            settingsSection: .init(
                PerplexityProviderSettingsKey.self,
                cookieSettings: PerplexityProviderSettings.self),
            resolveValues: { context in
                guard context.settings?.perplexity?.cookieSource != .off else { return nil }
                let cookie = PerplexitySettingsReader.sessionCookieOverride(environment: context.env)
                let value = cookie.map {
                    $0.requestCookieNames.count > 1 ? $0.token : "\($0.name)=\($0.token)"
                }
                return .init(secrets: value.map { ["SESSION_COOKIE": $0] } ?? [:])
            },
            field: .init(
                id: "perplexity-cookie",
                title: "",
                subtitle: "",
                placeholder: "Cookie: \u{2026}\n\nor paste the __Secure-next-auth.session-token value",
                action: (
                    id: "perplexity-open-usage",
                    title: "Open Usage Page",
                    url: "https://www.perplexity.ai/account/usage")),
            picker: .init(
                id: "perplexity-cookie-source",
                allowsOff: true,
                auto: .localized("Automatically imports browser session cookie."),
                manual: .localized(
                    "Paste a full cookie header or the %@ value.",
                    argument: "__Secure-next-auth.session-token"),
                off: .localized("%@ cookies are disabled.", argument: "Perplexity")),
            detailLine: "web",
            loginURL: "https://www.perplexity.ai/"))

    private static let credentials = ProviderCredentialAdapter(
        tokenResolver: { kind, environment, _ in
            guard kind == .primary, let token = Self.resolveSessionToken(environment: environment) else {
                return nil
            }
            return ProviderTokenResolution(token: token, source: .environment)
        },
        authDetector: { environment, _ in
            PerplexitySettingsReader.sessionToken(environment: environment) == nil ? [] : ["web"]
        },
        missingCredentialMessage: { _ in PerplexityAPIError.missingToken.errorDescription })

    private static func resolveSessionToken(environment: [String: String]) -> String? {
        if let token = PerplexitySettingsReader.sessionToken(environment: environment) {
            return token
        }
        #if os(macOS)
        return try? PerplexityCookieImporter.importSession().sessionToken
        #else
        return nil
        #endif
    }
}
