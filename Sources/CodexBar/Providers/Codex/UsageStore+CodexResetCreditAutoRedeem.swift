import CodexBarCore
import Foundation

extension UsageStore {
    func scheduleCodexResetCreditAutoRedeem(
        snapshot: UsageSnapshot,
        expectedGuard: CodexAccountScopedRefreshGuard?)
    {
        guard self.settings.codexResetCreditAutoRedeemEnabled, self.isEnabled(.codex),
              let expectedGuard, case let .providerAccount(expectedAccountID) = expectedGuard.identity,
              let owner = Self.codexSessionQuotaOwnerKey(for: expectedGuard),
              self.shouldApplyCodexScopedNonUsageResult(expectedGuard: expectedGuard)
        else {
            self.codexResetCreditAutoRedeemer.cancel()
            return
        }
        let context = self.makeFetchContext(provider: .codex, override: nil)
        let env = context.env
        let workspaceID = context.codexWorkspaceID
        let sourceKey = switch expectedGuard.source {
        case .liveSystem: "live-system"
        case let .managedAccount(id): "managed:\(id.uuidString)"
        case let .profileHome(path): "profile:\(path)"
        }
        let authorized: @MainActor @Sendable () -> Bool = { [weak self] in
            guard let self else { return false }
            return self.settings.codexResetCreditAutoRedeemEnabled && self.isEnabled(.codex)
                && self.freshCodexAccountScopedRefreshGuard() == expectedGuard
        }
        self.codexResetCreditAutoRedeemer.update(
            enabled: true,
            owner: owner.rawValue + ":" + sourceKey + ":" + (expectedGuard.authFingerprint ?? ""),
            snapshot: snapshot.codexResetCredits,
            consume: { stableID, requestID in
                guard authorized() else { throw CancellationError() }
                let credentials = try CodexOAuthCredentialsStore.loadOAuthTokens(env: env)
                guard !credentials.needsRefresh else { throw CodexOAuthCredentialsError.nativeRefreshRequired }
                guard let accountID = workspaceID ?? credentials.accountId,
                      accountID == expectedAccountID
                else { throw CodexOAuthFetchError.invalidResponse }
                return try await CodexOAuthUsageFetcher.consumeExpiringRateLimitResetCredit(
                    stableCreditID: stableID,
                    redeemRequestID: requestID,
                    accessToken: credentials.accessToken,
                    accountId: accountID,
                    env: env,
                    isAuthorized: { await authorized() })
            },
            completed: { [weak self] result in
                guard let self, authorized() else { return }
                if result == .reset || result == .alreadyRedeemed {
                    AppNotifications.shared.post(
                        idPrefix: "codex-reset-credit-auto-redeem",
                        title: L("Codex reset credit used"),
                        body: L("An expiring reset credit was used automatically. Usage limits are being refreshed."),
                        identifier: "codex-reset-credit-auto-redeem:\(owner.rawValue)",
                        isCurrent: authorized)
                } else if result != .unavailable {
                    AppNotifications.shared.post(
                        idPrefix: "codex-reset-credit-auto-redeem-failed",
                        title: L("Codex reset credit could not be used"),
                        body: L("Automatic redemption did not complete. Check Codex before the credit expires."),
                        identifier: "codex-reset-credit-auto-redeem:\(owner.rawValue)",
                        isCurrent: authorized)
                }
                await self.refreshProvider(.codex, coalesceIfRefreshing: true)
            })
    }
}
