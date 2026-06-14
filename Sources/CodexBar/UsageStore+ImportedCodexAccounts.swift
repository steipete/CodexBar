import CodexBarCore
import Foundation

struct ImportedCodexAccountUsageSnapshot: Identifiable {
    let id: String
    let account: BorrowedCodexAccount
    let snapshot: UsageSnapshot?
    let error: String?
    let sourceLabel: String?

    init(account: BorrowedCodexAccount, snapshot: UsageSnapshot?, error: String?, sourceLabel: String?) {
        self.id = account.id
        self.account = account
        self.snapshot = snapshot
        self.error = error
        self.sourceLabel = sourceLabel
    }
}

private struct ImportedCodexAccountFetchResult {
    let index: Int
    let account: BorrowedCodexAccount
    let sourceLabel: String?
    let result: Result<ProviderFetchResult, Error>
}

private struct ImportedCodexLoadedAccount: Sendable {
    let account: BorrowedCodexAccount
    let sourceLabel: String?
}

extension UsageStore {
    typealias ImportedCodexUsageFetchOverride = @Sendable (BorrowedCodexAccount) async throws -> ProviderFetchResult

    func refreshImportedCodexAccounts(now: Date = Date()) async {
        let sources = self.settings.importedCodexCredentialSources
        guard !sources.isEmpty else {
            self.importedCodexAccountSnapshots = []
            return
        }

        let loadedAccounts = await self.loadImportedCodexAccounts(sources: sources, now: now)
        guard !loadedAccounts.isEmpty else {
            self.importedCodexAccountSnapshots = []
            return
        }

        let results = await self.fetchImportedCodexAccountResults(accounts: loadedAccounts, updatedAt: now)
        self.importedCodexAccountSnapshots = results.map { result in
            switch result.result {
            case let .success(fetchResult):
                ImportedCodexAccountUsageSnapshot(
                    account: result.account,
                    snapshot: fetchResult.usage.scoped(to: .codex),
                    error: nil,
                    sourceLabel: result.sourceLabel ?? fetchResult.sourceLabel)
            case let .failure(error):
                ImportedCodexAccountUsageSnapshot(
                    account: result.account,
                    snapshot: nil,
                    error: self.tokenAccountSnapshotErrorMessage(error),
                    sourceLabel: result.sourceLabel)
            }
        }
    }

    private nonisolated func loadImportedCodexAccounts(
        sources: [ImportedCredentialSource],
        now: Date) async -> [ImportedCodexLoadedAccount]
    {
        await withTaskGroup(
            of: [ImportedCodexLoadedAccount].self,
            returning: [ImportedCodexLoadedAccount].self)
        { group in
            for source in sources {
                group.addTask {
                    let label = source.label?.trimmingCharacters(in: .whitespacesAndNewlines)
                    let sourceLabel = label?.isEmpty == false ? label : nil
                    return CLIProxyCodexAdapter.loadAccounts(from: source.path, now: now).map { account in
                        ImportedCodexLoadedAccount(account: account, sourceLabel: sourceLabel)
                    }
                }
            }

            var accounts: [ImportedCodexLoadedAccount] = []
            for await result in group {
                accounts.append(contentsOf: result)
            }
            let sortedAccounts = accounts.sorted { lhs, rhs in
                if lhs.account.email != rhs.account.email { return lhs.account.email < rhs.account.email }
                return lhs.account.id < rhs.account.id
            }
            var seenIDs = Set<String>()
            return sortedAccounts.filter { seenIDs.insert($0.account.id).inserted }
        }
    }

    private func fetchImportedCodexAccountResults(
        accounts: [ImportedCodexLoadedAccount],
        updatedAt: Date) async -> [ImportedCodexAccountFetchResult]
    {
        let override = self._test_importedCodexUsageFetchOverride
        return await withTaskGroup(
            of: ImportedCodexAccountFetchResult.self,
            returning: [ImportedCodexAccountFetchResult].self)
        { group in
            for (index, loadedAccount) in accounts.enumerated() {
                group.addTask {
                    let account = loadedAccount.account
                    do {
                        let result = if let override {
                            try await override(account)
                        } else {
                            try await BorrowedCodexUsageFetcher.fetchUsage(account: account, updatedAt: updatedAt)
                        }
                        return ImportedCodexAccountFetchResult(
                            index: index,
                            account: account,
                            sourceLabel: loadedAccount.sourceLabel,
                            result: .success(result))
                    } catch {
                        return ImportedCodexAccountFetchResult(
                            index: index,
                            account: account,
                            sourceLabel: loadedAccount.sourceLabel,
                            result: .failure(error))
                    }
                }
            }

            var results: [ImportedCodexAccountFetchResult] = []
            results.reserveCapacity(accounts.count)
            for await result in group {
                results.append(result)
            }
            return results.sorted { $0.index < $1.index }
        }
    }
}
