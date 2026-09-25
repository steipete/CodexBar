import CodexBarCore
import CryptoKit
import Foundation

struct TokenAccountUsageSnapshot: Identifiable {
    let id: UUID
    let account: ProviderTokenAccount
    let snapshot: UsageSnapshot?
    let error: String?
    let sourceLabel: String?
    let cacheKey: String
    let fetchError: (any Error)?

    init(
        account: ProviderTokenAccount,
        snapshot: UsageSnapshot?,
        error: String?,
        sourceLabel: String?,
        cacheKey: String,
        fetchError: (any Error)? = nil)
    {
        self.id = account.id
        self.account = account
        self.snapshot = snapshot
        self.error = error
        self.sourceLabel = sourceLabel
        self.cacheKey = cacheKey
        self.fetchError = fetchError
    }
}

extension UsageStore {
    func tokenAccountSnapshotCacheKey(provider: UsageProvider, account: ProviderTokenAccount) -> String {
        var config = (self.settings.configSnapshot.providerConfig(for: provider.instanceID)
            ?? ProviderConfig(id: provider.instanceID)).fetchIdentityConfig
        // Active selection and sibling accounts must not invalidate a valid per-account snapshot.
        config.tokenAccounts = nil
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var material = Data(provider.rawValue.utf8)
        material.append((try? encoder.encode(config)) ?? Data())
        material.append((try? encoder.encode(account)) ?? Data())
        if Self.tokenCostRequiresProviderSnapshot(provider) {
            material.append(Data(self.tokenSnapshotScopeSignature(for: provider).utf8))
        }
        return SHA256.hash(data: material).map { String(format: "%02x", $0) }.joined()
    }
}
