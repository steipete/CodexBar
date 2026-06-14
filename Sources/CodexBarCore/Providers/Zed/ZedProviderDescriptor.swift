import CodexBarMacroSupport
import Foundation

@ProviderDescriptorRegistration
@ProviderDescriptorDefinition
public enum ZedProviderDescriptor {
    static func makeDescriptor() -> ProviderDescriptor {
        ProviderDescriptor(
            id: .zed,
            metadata: ProviderMetadata(
                id: .zed,
                displayName: "Zed",
                sessionLabel: "Edit predictions",
                weeklyLabel: "Billing cycle",
                opusLabel: nil,
                supportsOpus: false,
                supportsCredits: false,
                creditsHint: "",
                toggleTitle: "Show Zed usage",
                cliName: "zed",
                defaultEnabled: false,
                isPrimaryProvider: false,
                usesAccountFallback: false,
                browserCookieOrder: ProviderBrowserCookieDefaults.zedCookieImportOrder,
                dashboardURL: "https://dashboard.zed.dev",
                subscriptionDashboardURL: "https://dashboard.zed.dev",
                statusPageURL: nil),
            branding: ProviderBranding(
                iconStyle: .zed,
                iconResourceName: "ProviderIcon-zed",
                color: ProviderColor(red: 8 / 255, green: 78 / 255, blue: 255 / 255)),
            tokenCost: ProviderTokenCostConfig(
                supportsTokenCost: false,
                noDataMessage: { "Zed cost summary is not supported." }),
            fetchPlan: ProviderFetchPlan(
                sourceModes: [.auto, .api],
                pipeline: ProviderFetchPipeline(resolveStrategies: { _ in
                    [ZedLocalFetchStrategy()]
                })),
            cli: ProviderCLIConfig(
                name: "zed",
                versionDetector: nil))
    }
}

struct ZedLocalFetchStrategy: ProviderFetchStrategy {
    let id: String = "zed.local"
    let kind: ProviderFetchKind = .localProbe

    func isAvailable(_: ProviderFetchContext) async -> Bool {
        true
    }

    func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        let probe = ZedStatusProbe()
        let snapshot = try await probe.fetch()
        let cookieSource = context.settings?.zed?.cookieSource ?? .off
        let billing = try await self.fetchBilling(context: context)
        let usage = snapshot.toUsageSnapshot(
            tokenBilling: billing.snapshot,
            dashboardCookieSource: cookieSource,
            billingError: billing.errorMessage)
        let sourceLabel = if billing.snapshot != nil {
            "local+zed-dashboard"
        } else if cookieSource != .off, billing.errorMessage != nil {
            "local (dashboard auth failed)"
        } else {
            "local"
        }
        return self.makeResult(usage: usage, sourceLabel: sourceLabel)
    }

    func shouldFallback(on _: Error, context _: ProviderFetchContext) -> Bool {
        false
    }

    private struct BillingFetchOutcome {
        let snapshot: ZedTokenBillingSnapshot?
        let errorMessage: String?
    }

    private func fetchBilling(context: ProviderFetchContext) async throws -> BillingFetchOutcome {
        let settings = context.settings?.zed
        let cookieSource = settings?.cookieSource ?? .off
        guard cookieSource != .off else {
            return BillingFetchOutcome(snapshot: nil, errorMessage: nil)
        }

        do {
            let snapshot = try await ZedDashboardBillingFetcher.fetch(
                browserDetection: context.browserDetection,
                cookieSource: cookieSource,
                manualCookieHeader: settings?.manualCookieHeader,
                timeout: context.webTimeout,
                logger: context.verbose ? { print($0) } : nil)
            return BillingFetchOutcome(snapshot: snapshot, errorMessage: nil)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            if context.verbose {
                print("[zed-dashboard] Billing enrichment failed: \(message)")
            }
            return BillingFetchOutcome(snapshot: nil, errorMessage: message)
        }
    }
}
