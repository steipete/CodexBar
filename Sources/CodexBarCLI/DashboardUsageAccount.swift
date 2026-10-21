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
        let id: String = switch account.selectionSource {
        case .liveSystem:
            account.storedAccountID.map { "codex-managed:\($0.uuidString.lowercased())" }
                ?? self.opaqueCodexID("system:\(account.workspaceAccountID ?? "default")")
        case let .managedAccount(id):
            "codex-managed:\(id.uuidString.lowercased())"
        case let .profileHome(path):
            self.opaqueCodexID("profile:\(CodexHomeScope.normalizedHomePath(path) ?? path)")
        }
        return Self(id: id, label: account.displayName, active: account.isActive)
    }

    private static func opaqueCodexID(_ source: String) -> String {
        let digest = SHA256.hash(data: Data(source.utf8)).map { String(format: "%02x", $0) }.joined()
        return "codex:\(digest)"
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
