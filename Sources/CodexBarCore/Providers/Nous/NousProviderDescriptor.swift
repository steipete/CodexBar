import Foundation

public enum NousProviderDescriptor {
    public static let descriptor: ProviderDescriptor = Self.makeDescriptor()

    private static let credentials = ProviderCredentialAdapter(
        supportsAPIKeyOverride: false,
        requiresAPIKeyForAPISource: false,
        tokenResolver: { kind, environment, _ in
            guard kind == .primary, let credential = NousSettingsReader.credential(environment: environment) else {
                return nil
            }
            let source: ProviderTokenSource = credential.source == .environment ? .environment : .authFile
            return ProviderTokenResolution(token: credential.token, source: source)
        },
        authDetector: { environment, _ in
            NousSettingsReader.credential(environment: environment) == nil ? [] : ["api"]
        },
        missingCredentialMessage: { environment in
            NousSettingsReader.unavailableMessage(environment: environment)
        })

    static func makeDescriptor() -> ProviderDescriptor {
        ProviderDescriptor(
            id: .nous,
            menuBarMetrics: ProviderMenuBarMetricCapabilities(supported: [.automatic, .primary]),
            credentials: self.credentials,
            metadata: ProviderMetadata(
                id: .nous,
                displayName: "Nous Portal",
                shortDisplayName: "Nous",
                sessionLabel: "Monthly credits",
                weeklyLabel: "Weekly",
                opusLabel: nil,
                supportsOpus: false,
                supportsCredits: true,
                creditsHint: "Purchased credit balance from Nous Portal",
                toggleTitle: "Show Nous Portal usage",
                cliName: "nous",
                defaultEnabled: false,
                widgetSelectable: false,
                isPrimaryProvider: false,
                usesAccountFallback: false,
                dashboardURL: "https://portal.nousresearch.com/usage",
                subscriptionDashboardURL: "https://portal.nousresearch.com/manage-subscription",
                statusPageURL: nil),
            branding: ProviderBranding(
                iconStyle: .init(provider: .nous),
                iconResourceName: "ProviderIcon-nous",
                color: ProviderColor(red: 214 / 255, green: 165 / 255, blue: 92 / 255),
                confettiPalette: [
                    ProviderColor(hex: 0xD6A55C),
                    ProviderColor(hex: 0x1C1B1A),
                    ProviderColor(hex: 0xF3EADB),
                ]),
            tokenCost: ProviderTokenCostConfig(
                supportsTokenCost: false,
                noDataMessage: { "Nous Portal cost summary is not available." }),
            presentation: ProviderUsagePresentation(
                planRow: ProviderPlanRowPresentation(label: "Plan")),
            fetchPlan: ProviderFetchPlan(
                sourceModes: [.auto, .api],
                pipeline: ProviderFetchPipeline(resolveStrategies: { _ in [NousAPIFetchStrategy()] })),
            cli: ProviderCLIConfig(
                name: "nous",
                aliases: ["nous-portal", "hermes"],
                versionDetector: nil))
    }
}

struct NousAPIFetchStrategy: ProviderFetchStrategy {
    let id = "nous.api"
    let kind: ProviderFetchKind = .apiToken
    private let transport: any ProviderHTTPTransport

    init(transport: any ProviderHTTPTransport = ProviderHTTPClient.shared) {
        self.transport = transport
    }

    /// Available whenever some Nous credential exists, even an expired one, so the fetch surfaces the specific
    /// expiry or trust error instead of a bare "unavailable".
    func isAvailable(_ context: ProviderFetchContext) async -> Bool {
        do {
            _ = try NousSettingsReader.resolveCredential(environment: context.env)
            return true
        } catch NousUsageError.missingCredentials {
            return false
        } catch {
            return true
        }
    }

    func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        // Credits ride along in the same account response, so attach them regardless of `includeCredits`
        // (the app only sets that flag for Codex's separate credits request).
        let credential = try NousSettingsReader.resolveCredential(environment: context.env)
        let account = try await NousUsageFetcher.fetchAccount(credential: credential, transport: self.transport)
        // The app renders `diagnostic` as a warning line, so only emit it when there is something to warn about
        // (an ignored stored host) or when the caller asked for a verbose trace.
        var diagnostic: String?
        if credential.rejectedPortalHost != nil || context.verbose {
            var note = "portal=\(credential.portalBaseURL.host ?? "?") credential=\(credential.source.label)"
            if let rejected = credential.rejectedPortalHost {
                note += " rejectedStoredHost=\(rejected)"
            }
            diagnostic = note
        }
        return self.makeResult(
            usage: account.toUsageSnapshot(),
            credits: account.toCreditsSnapshot(),
            sourceLabel: "api",
            diagnostic: diagnostic)
    }

    func shouldFallback(on _: Error, context _: ProviderFetchContext) -> Bool {
        false
    }
}
