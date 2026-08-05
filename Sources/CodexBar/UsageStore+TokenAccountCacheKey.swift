import CodexBarCore
import CryptoKit
import Foundation

extension UsageStore {
    func tokenAccountSnapshotCacheKey(provider: UsageProvider, account: ProviderTokenAccount) -> String {
        var config = self.settings.configSnapshot.providerConfig(for: provider.instanceID)
            ?? ProviderConfig(id: provider.instanceID)
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
