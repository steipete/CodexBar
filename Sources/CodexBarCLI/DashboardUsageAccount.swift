import CodexBarCore
import Crypto
import Foundation

/// Account presentation metadata travels beside usage, including failed fetches.
/// Never derive public IDs from cacheAccountKey, email, or authFingerprint.
struct DashboardUsageAccount: Sendable {
    let id: String
    let label: String
    let active: Bool

    static func token(_ account: ProviderTokenAccount, active: Bool) -> Self {
        Self(id: "token:\(account.id.uuidString.lowercased())", label: account.label, active: active)
    }

    static func codex(_ account: CodexVisibleAccount) -> Self {
        // Hash only durable source metadata. Separate profile homes remain separate even
        // when they use the same workspace; token refreshes and email changes do not churn IDs.
        let source: String = switch account.selectionSource {
        case .liveSystem:
            // Promotion to the live source preserves the managed account UUID.
            account.storedAccountID.map { "stored:\($0.uuidString.lowercased())" }
                ?? "system:\(account.workspaceAccountID ?? "default")"
        case let .managedAccount(id):
            "stored:\(id.uuidString.lowercased())"
        case let .profileHome(path):
            "profile:\(CodexHomeScope.normalizedHomePath(path) ?? path)"
        }
        let digest = SHA256.hash(data: Data(source.utf8)).map { String(format: "%02x", $0) }.joined()
        return Self(id: "codex:\(digest)", label: account.displayName, active: account.isActive)
    }
}

extension UsageCommandOutput {
    mutating func attachDashboardAccount(_ account: DashboardUsageAccount?, inventoryIncomplete: Bool = false) {
        for index in self.payload.indices {
            if let account { self.payload[index].dashboardAccount = account }
            self.payload[index].dashboardAccountsIncomplete = self.payload[index].dashboardAccountsIncomplete
                || inventoryIncomplete
        }
    }
}
