import Foundation

public struct CodexProviderSettingsBuilderInput: Sendable {
    public let usageDataSource: CodexUsageDataSource
    public let cookieSource: ProviderCookieSource
    public let manualCookieHeader: String?
    public let reconciliationSnapshot: CodexAccountReconciliationSnapshot
    public let resolvedActiveSource: CodexResolvedActiveSource

    public init(
        usageDataSource: CodexUsageDataSource,
        cookieSource: ProviderCookieSource,
        manualCookieHeader: String?,
        reconciliationSnapshot: CodexAccountReconciliationSnapshot,
        resolvedActiveSource: CodexResolvedActiveSource)
    {
        self.usageDataSource = usageDataSource
        self.cookieSource = cookieSource
        self.manualCookieHeader = manualCookieHeader
        self.reconciliationSnapshot = reconciliationSnapshot
        self.resolvedActiveSource = resolvedActiveSource
    }
}

public enum CodexKnownOwnerCatalog {
    public static func candidates(
        from snapshot: CodexAccountReconciliationSnapshot) -> [CodexDashboardKnownOwnerCandidate]
    {
        var candidates = snapshot.storedAccounts.map { account in
            CodexDashboardKnownOwnerCandidate(
                identity: snapshot.runtimeIdentity(for: account),
                normalizedEmail: CodexIdentityResolver.normalizeEmail(snapshot.runtimeEmail(for: account)))
        }

        if let liveSystemAccount = snapshot.liveSystemAccount {
            candidates.append(CodexDashboardKnownOwnerCandidate(
                identity: snapshot.runtimeIdentity(for: liveSystemAccount),
                normalizedEmail: CodexIdentityResolver.normalizeEmail(liveSystemAccount.email)))
        }

        return candidates
    }
}

public enum CodexProviderSettingsBuilder {
    public static func make(input: CodexProviderSettingsBuilderInput) -> ProviderSettingsSnapshot
    .CodexProviderSettings {
        let snapshot = input.reconciliationSnapshot
        let persistedSource = input.resolvedActiveSource.persistedSource
        let managedSourceSelected = switch persistedSource {
        case .liveSystem:
            false
        case .managedAccount:
            true
        }

        return ProviderSettingsSnapshot.CodexProviderSettings(
            usageDataSource: input.usageDataSource,
            cookieSource: input.cookieSource,
            manualCookieHeader: input.manualCookieHeader,
            managedAccountStoreUnreadable: managedSourceSelected && snapshot.hasUnreadableAddedAccountStore,
            managedAccountTargetUnavailable: managedSourceSelected
                && snapshot.hasUnreadableAddedAccountStore == false
                && snapshot.activeStoredAccount == nil,
            dashboardAuthorityKnownOwners: CodexKnownOwnerCatalog.candidates(from: snapshot))
    }
}
