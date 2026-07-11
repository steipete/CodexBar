import CodexBarCore

extension UsageStore {
    func limitResetAccountIdentifier(
        provider: UsageProvider,
        account: ProviderTokenAccount?,
        snapshot: UsageSnapshot,
        accountKey: String?,
        codexLimitResetOwnerKey: CodexLimitResetOwnerKey?) -> String?
    {
        if provider == .codex {
            return codexLimitResetOwnerKey?.rawValue
        }
        let identity = snapshot.identity(for: provider)
        return account?.id.uuidString.lowercased()
            ?? accountKey
            ?? identity?.accountEmail
            ?? identity?.accountOrganization
            ?? provider.rawValue
    }

    func limitResetAccountLabel(
        provider: UsageProvider,
        account: ProviderTokenAccount?,
        snapshot: UsageSnapshot) -> String?
    {
        let identity = snapshot.identity(for: provider)
        return account?.label
            ?? identity?.accountEmail
            ?? identity?.accountOrganization
    }
}
