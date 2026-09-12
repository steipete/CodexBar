import Foundation

/// Maps Codex extra credits onto the shared Extra usage cost snapshot.
///
/// Team/Business monthly caps expose used vs limit. Purchased extra credits that sit
/// beside that cap are the remaining balance, matching Claude extra usage + prepaid
/// balance and Cursor on-demand used vs limit.
public enum CodexExtraUsageCost {
    public static let currencyCode = "Credits"

    public static func providerCost(from credits: CreditsSnapshot?) -> ProviderCostSnapshot? {
        guard let credits else { return nil }
        let extraBalance = self.purchasedExtraCreditsBalance(from: credits)
        // Explicit hidden pools are observations too; cap-only refreshes and preservation placeholders are not.
        let balanceIsUnavailable = !credits.balanceReadSucceeded && credits.creditsAvailable == true
        let balanceUpdatedAt = credits.balanceReadSucceeded || balanceIsUnavailable ? credits.updatedAt : nil
        let limit = credits.codexCreditLimit.flatMap { $0.limit > 0 ? $0 : nil }
        guard limit != nil || balanceUpdatedAt != nil else { return nil }
        var cost = ProviderCostSnapshot(
            used: limit?.used ?? 0,
            limit: limit?.limit ?? 0,
            currencyCode: Self.currencyCode,
            period: limit?.title ?? "Extra usage",
            resetsAt: limit?.resetsAt,
            balance: extraBalance,
            balanceUpdatedAt: balanceUpdatedAt,
            balanceIsWorkspace: credits.hasWorkspaceBalance ? true : nil,
            // The cap ages on its own, even when preserved beside a newer balance fetch.
            updatedAt: limit?.updatedAt ?? credits.updatedAt)
        cost.balanceIsUnavailable = balanceIsUnavailable ? true : nil
        return cost
    }

    public static func attaching(to snapshot: UsageSnapshot, credits: CreditsSnapshot?) -> UsageSnapshot {
        let cost = self.resolving(liveCredits: credits, attached: snapshot.providerCost)
        guard cost != snapshot.providerCost else { return snapshot }
        return snapshot.with(providerCost: cost)
    }

    /// An authorized dashboard attaches its monthly cap to the paired usage snapshot without overwriting
    /// already-known credits, so either side can hold the cap and either side can be the stale one.
    /// Take the fresher cap and the fresher purchased balance. Live credits are the whole snapshot rather
    /// than its cost because the two age apart there: a preserved cap is older than the fetch carrying it.
    public static func resolving(
        liveCredits: CreditsSnapshot?,
        attached: ProviderCostSnapshot?) -> ProviderCostSnapshot?
    {
        self.resolving(liveCost: self.providerCost(from: liveCredits), attached: attached)
    }

    public static func resolving(
        liveCost: ProviderCostSnapshot?,
        attached: ProviderCostSnapshot?) -> ProviderCostSnapshot?
    {
        guard let live = liveCost else { return attached }
        guard live.currencyCode == Self.currencyCode else { return live }
        // Reconcile only the account-paired Codex cost, never a different provider or dashboard.
        guard let attached, attached.currencyCode == Self.currencyCode else { return live }
        let liveBalanceDate = self.balanceDate(live)
        let attachedBalanceDate = self.balanceDate(attached)
        // A successful observation wins a tie; only a strictly newer hidden response invalidates it.
        let balanceSource: ProviderCostSnapshot = if let liveBalanceDate,
                                                     liveBalanceDate > (attachedBalanceDate ?? .distantPast)
                                                     || (liveBalanceDate == attachedBalanceDate
                                                         && live.balanceIsUnavailable != true)
        {
            live
        } else {
            attached
        }
        let capSource: ProviderCostSnapshot = if attached.limit > 0,
                                                 live.limit <= 0 || attached.updatedAt > live.updatedAt
        {
            attached
        } else {
            live
        }
        return capSource.replacing(
            balance: balanceSource.balance,
            balanceUpdatedAt: self.balanceDate(balanceSource),
            balanceIsWorkspace: balanceSource.balanceIsWorkspace,
            balanceIsUnavailable: balanceSource.balanceIsUnavailable)
    }

    /// The legacy Credits row and menu-bar fallback must use the same account-paired observations.
    /// This is a display copy; it never replaces the stored transport snapshot or its history.
    public static func creditsForDisplay(
        _ credits: CreditsSnapshot?, attached: ProviderCostSnapshot?) -> CreditsSnapshot?
    {
        guard let credits,
              let cost = self.resolving(liveCredits: credits, attached: attached),
              cost.currencyCode == Self.currencyCode
        else { return credits }
        let balanceDate = self.balanceDate(cost)
        let replaceBalance = balanceDate.map { !credits.balanceReadSucceeded || $0 > credits.updatedAt } ?? false
        var limit = credits.codexCreditLimit
        if cost.limit > 0, cost.updatedAt > (limit?.updatedAt ?? .distantPast) {
            limit = CodexCreditLimitSnapshot(
                title: cost.period ?? "Monthly credit limit",
                used: cost.used,
                limit: cost.limit,
                remainingPercent: max(0, 100 - cost.used / cost.limit * 100),
                resetsAt: cost.resetsAt,
                updatedAt: cost.updatedAt)
        }
        guard replaceBalance || limit != credits.codexCreditLimit else { return credits }
        return CreditsSnapshot(
            remaining: replaceBalance ? cost.balance ?? 0 : credits.remaining,
            events: credits.events,
            updatedAt: replaceBalance ? balanceDate ?? credits.updatedAt : credits.updatedAt,
            codexCreditLimit: limit,
            balanceReadSucceeded: replaceBalance ? cost.balanceIsUnavailable != true : credits.balanceReadSucceeded,
            creditsAvailable: replaceBalance && cost.balanceIsUnavailable == true ? true : credits.creditsAvailable,
            balanceIsWorkspace: replaceBalance ? cost.balanceIsWorkspace == true : credits.balanceIsWorkspace)
    }

    private static func balanceDate(_ cost: ProviderCostSnapshot) -> Date? {
        // Persisted snapshots predating balance provenance only prove positive balances.
        cost.balanceUpdatedAt ?? (cost.balance != nil ? cost.updatedAt : nil)
    }

    /// Purchased extra credits that are distinct from the monthly included/assigned cap.
    public static func purchasedExtraCreditsBalance(from credits: CreditsSnapshot) -> Double? {
        guard credits.balanceReadSucceeded else { return nil }
        // An independently fetched workspace pool can happen to equal the personal cap's remainder.
        if credits.hasWorkspaceBalance { return credits.remaining > 0 ? credits.remaining : nil }
        if let monthly = credits.codexCreditLimit {
            guard abs(credits.remaining - monthly.remaining) > 0.000_1, credits.remaining > 0 else {
                return nil
            }
            return credits.remaining
        }
        return credits.remaining > 0 ? credits.remaining : nil
    }
}
