import CodexBarCore
import Foundation

extension UsageStore {
    struct CodexAccountFetchResult {
        let index: Int
        let account: CodexVisibleAccount
        let outcome: ProviderFetchOutcome?
        let limitResetOwnerKey: CodexLimitResetOwnerKey?
        let pendingWeeklyResetCandidate: CodexWeeklyResetPublicationCandidate?
        let withheldSuccess: ProviderFetchResult?
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

    static func codexAccountSnapshots(
        _ snapshots: [CodexAccountUsageSnapshot],
        reconciledWith projection: CodexVisibleAccountProjection) -> [CodexAccountUsageSnapshot]
    {
        snapshots.compactMap { snapshot in
            guard let currentAccount = currentCodexVisibleAccount(
                matching: snapshot.account,
                projection: projection,
                allowProviderAccountAuthFingerprintMismatch: snapshot.error == nil)
            else { return nil }
            guard currentAccount != snapshot.account else { return snapshot }
            return CodexAccountUsageSnapshot(
                account: currentAccount,
                snapshot: codexVisibleAccountSnapshotRelabeledForCurrentProjection(
                    snapshot.snapshot,
                    account: currentAccount),
                error: snapshot.error,
                sourceLabel: snapshot.sourceLabel,
                credits: snapshot.credits,
                weeklyResetCandidate: snapshot.weeklyResetCandidate)
        }
    }
}
