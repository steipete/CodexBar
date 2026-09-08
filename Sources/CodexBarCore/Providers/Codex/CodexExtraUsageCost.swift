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
        let balanceUpdatedAt = credits.balanceReadSucceeded ? credits.updatedAt : nil
        if let limit = credits.codexCreditLimit, limit.limit > 0 {
            return ProviderCostSnapshot(
                used: limit.used,
                limit: limit.limit,
                currencyCode: Self.currencyCode,
                period: limit.title,
                resetsAt: limit.resetsAt,
                balance: extraBalance,
                balanceUpdatedAt: balanceUpdatedAt,
                // The cap ages on its own: a preserved limit rides along with a newer balance fetch,
                // so stamping it with `credits.updatedAt` would overstate how fresh the cap is.
                updatedAt: limit.updatedAt)
        }
        guard balanceUpdatedAt != nil || extraBalance != nil else { return nil }
        return ProviderCostSnapshot(
            used: 0,
            limit: 0,
            currencyCode: Self.currencyCode,
            period: "Extra usage",
            balance: extraBalance,
            balanceUpdatedAt: balanceUpdatedAt,
            updatedAt: credits.updatedAt)
    }

    public static func attaching(to snapshot: UsageSnapshot, credits: CreditsSnapshot?) -> UsageSnapshot {
        guard let cost = self.resolving(liveCredits: credits, attached: snapshot.providerCost) else { return snapshot }
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
        let live = self.providerCost(from: liveCredits)
        guard let live else { return attached }
        // Reconcile only the account-paired Codex cost, never a different provider or dashboard.
        guard let attached, attached.currencyCode == Self.currencyCode else { return live }
        let liveBalanceDate = self.balanceDate(live)
        let attachedBalanceDate = self.balanceDate(attached)
        let balanceSource: ProviderCostSnapshot = if let liveBalanceDate,
                                                     liveBalanceDate >= (attachedBalanceDate ?? .distantPast)
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
            balanceUpdatedAt: self.balanceDate(balanceSource))
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
            balanceReadSucceeded: replaceBalance || credits.balanceReadSucceeded)
    }

    private static func balanceDate(_ cost: ProviderCostSnapshot) -> Date? {
        // Persisted snapshots predating balance provenance only prove positive balances.
        cost.balanceUpdatedAt ?? (cost.balance != nil ? cost.updatedAt : nil)
    }

    /// Purchased extra credits that are distinct from the monthly included/assigned cap.
    public static func purchasedExtraCreditsBalance(from credits: CreditsSnapshot) -> Double? {
        guard credits.balanceReadSucceeded else { return nil }
        if let monthly = credits.codexCreditLimit {
            guard abs(credits.remaining - monthly.remaining) > 0.000_1, credits.remaining > 0 else {
                return nil
            }
            return credits.remaining
        }
        return credits.remaining > 0 ? credits.remaining : nil
    }
}
