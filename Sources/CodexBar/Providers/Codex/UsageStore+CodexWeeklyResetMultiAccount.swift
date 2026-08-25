import CodexBarCore
import Foundation

extension UsageStore {
    struct CodexAccountFetchResult {
        let index: Int
        let account: CodexVisibleAccount
        let outcome: ProviderFetchOutcome?
        let limitResetOwnerKey: CodexLimitResetOwnerKey?
        let pendingWeeklyResetCandidate: CodexWeeklyResetPublicationCandidate?
    }

    struct CodexAccountFetchRequest {
        let index: Int
        let account: CodexVisibleAccount
        let previousSnapshot: UsageSnapshot?
        let previousSourceLabel: String?
        let missingWindowBackfillSnapshot: UsageSnapshot?
        let limitResetOwnerKey: CodexLimitResetOwnerKey?
        let pendingWeeklyResetCandidate: CodexWeeklyResetPublicationCandidate?
        let descriptor: ProviderDescriptor
        let context: ProviderFetchContext
        let resetCreditsFetcher: CodexResetCreditsFetcher
    }

    static func codexSnapshotsRetainingCandidate(
        _ prior: CodexAccountUsageSnapshot?,
        candidate: CodexWeeklyResetPublicationCandidate?) -> [CodexAccountUsageSnapshot]
    {
        guard let prior else { return [] }
        return [CodexAccountUsageSnapshot(
            account: prior.account,
            snapshot: prior.snapshot,
            error: prior.error,
            sourceLabel: prior.sourceLabel,
            credits: prior.credits,
            weeklyResetCandidate: candidate)]
    }
}
