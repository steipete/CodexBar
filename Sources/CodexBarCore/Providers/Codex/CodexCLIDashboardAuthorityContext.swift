import Foundation

public enum CodexCLIDashboardAuthorityContext {
    public static func makeLiveWebInput(
        dashboard: OpenAIDashboardSnapshot,
        context: ProviderFetchContext,
        routingTargetEmail: String?) -> CodexDashboardAuthorityInput
    {
        let auth = context.fetcher.loadAuthBackedCodexAccount()
        return CodexDashboardAuthorityInput(
            sourceKind: .liveWeb,
            proof: CodexDashboardOwnershipProofContext(
                currentIdentity: auth.identity,
                expectedScopedEmail: auth.email,
                trustedCurrentUsageEmail: nil,
                dashboardSignedInEmail: dashboard.signedInEmail,
                knownOwners: context.settings?.codex?.dashboardAuthorityKnownOwners ?? []),
            routing: CodexDashboardRoutingHints(
                targetEmail: CodexIdentityResolver.normalizeEmail(routingTargetEmail),
                lastKnownDashboardRoutingEmail: nil))
    }

    public static func makeCachedDashboardInput(
        dashboard: OpenAIDashboardSnapshot,
        cachedAccountEmail: String,
        usage: UsageSnapshot,
        sourceLabel: String,
        context: ProviderFetchContext) -> CodexDashboardAuthorityInput
    {
        let auth = context.fetcher.loadAuthBackedCodexAccount()
        let trustedCurrentUsageEmail = Self.shouldTrustUsageEmail(sourceLabel: sourceLabel)
            ? usage.accountEmail(for: .codex)
            : nil
        return CodexDashboardAuthorityInput(
            sourceKind: .cachedDashboard,
            proof: CodexDashboardOwnershipProofContext(
                currentIdentity: auth.identity,
                expectedScopedEmail: auth.email,
                trustedCurrentUsageEmail: trustedCurrentUsageEmail,
                dashboardSignedInEmail: dashboard.signedInEmail,
                knownOwners: context.settings?.codex?.dashboardAuthorityKnownOwners ?? []),
            routing: CodexDashboardRoutingHints(
                targetEmail: auth.email,
                lastKnownDashboardRoutingEmail: cachedAccountEmail))
    }

    public static func attachmentEmail(from input: CodexDashboardAuthorityInput) -> String? {
        CodexIdentityResolver.normalizeEmail(
            input.proof.expectedScopedEmail ??
                input.proof.trustedCurrentUsageEmail ??
                input.proof.dashboardSignedInEmail)
    }

    public static func shouldTrustUsageEmail(sourceLabel: String) -> Bool {
        switch sourceLabel.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "codex-cli", "oauth":
            true
        default:
            false
        }
    }
}
