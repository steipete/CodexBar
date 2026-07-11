import CodexBarCore
import Foundation

extension UsageStore {
    func activeCodexVisibleAccountForLimitResetDetection() -> CodexVisibleAccount? {
        let projection = self.settings.codexVisibleAccountProjection
        guard let activeID = projection.activeVisibleAccountID else { return nil }
        return projection.visibleAccounts.first { $0.id == activeID }
    }

    func limitResetAccountIdentifier(
        provider: UsageProvider,
        account: ProviderTokenAccount?,
        snapshot: UsageSnapshot,
        accountKey: String?,
        codexVisibleAccount: CodexVisibleAccount?) -> String
    {
        let identity = snapshot.identity(for: provider)
        if let account {
            return account.id.uuidString.lowercased()
        }
        if provider == .codex,
           let codexIdentifier = self.codexLimitResetDetectorAccountIdentifier(
               snapshot: snapshot,
               accountKey: accountKey,
               visibleAccount: codexVisibleAccount)
        {
            return codexIdentifier
        }
        return accountKey
            ?? identity?.accountEmail
            ?? identity?.accountOrganization
            ?? provider.rawValue
    }

    func codexLimitResetDetectorAccountIdentifier(
        snapshot: UsageSnapshot,
        accountKey: String?,
        visibleAccount: CodexVisibleAccount?) -> String?
    {
        let ownership = if let visibleAccount {
            self.codexOwnershipContext(forVisibleAccount: visibleAccount)
        } else {
            self.codexOwnershipContext(snapshot: snapshot, includeDashboardFallback: false)
        }
        if let canonicalKey = ownership.canonicalKey,
           CodexHistoryOwnership.isCanonicalProviderAccountKey(canonicalKey)
        {
            return canonicalKey
        }

        if let visibleAccount,
           let accountKey = ownership.canonicalKey ?? accountKey,
           let workspaceDiscriminator = Self.codexLimitResetWorkspaceDiscriminator(visibleAccount)
        {
            return Self.sha256Hex(
                "codex:limit-reset:\(accountKey):workspace:\(workspaceDiscriminator)")
        }

        return ownership.canonicalKey ?? accountKey
    }

    private nonisolated static func codexLimitResetWorkspaceDiscriminator(
        _ account: CodexVisibleAccount) -> String?
    {
        if let storedAccountID = account.storedAccountID {
            return "managed:\(storedAccountID.uuidString.lowercased())"
        }
        if case let .profileHome(path) = account.selectionSource {
            return "profile:\(path)"
        }
        let workspaceLabel = account.workspaceLabel?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let workspaceLabel, !workspaceLabel.isEmpty {
            return "workspace-label:\(workspaceLabel.lowercased())"
        }
        return CodexAuthFingerprint.normalize(account.authFingerprint).map { "auth:\($0)" }
    }
}
