import Foundation

public struct CodexProviderSettings: Sendable {
    public let usageDataSource: CodexUsageDataSource
    public let cookieSource: ProviderCookieSource
    public let manualCookieHeader: String?
    public let managedAccountStoreUnreadable: Bool
    public let managedAccountTargetUnavailable: Bool
    public let profileAccountTargetUnavailable: Bool
    public let openAIWebCacheScope: CookieHeaderCache.Scope?
    public let dashboardAuthorityKnownOwners: [CodexDashboardKnownOwnerCandidate]
    public let allowExternalOAuthSources: Bool
    /// Selected workspace identity stored in CodexBar's managed-account metadata. It is sent as
    /// an account header without rewriting the Codex-owned auth.json.
    public let managedWorkspaceAccountID: String?

    public init(
        usageDataSource: CodexUsageDataSource,
        cookieSource: ProviderCookieSource,
        manualCookieHeader: String?,
        managedAccountStoreUnreadable: Bool = false,
        managedAccountTargetUnavailable: Bool = false,
        profileAccountTargetUnavailable: Bool = false,
        openAIWebCacheScope: CookieHeaderCache.Scope? = nil,
        dashboardAuthorityKnownOwners: [CodexDashboardKnownOwnerCandidate] = [],
        allowExternalOAuthSources: Bool = false,
        managedWorkspaceAccountID: String? = nil)
    {
        self.usageDataSource = usageDataSource
        self.cookieSource = cookieSource
        self.manualCookieHeader = manualCookieHeader
        self.managedAccountStoreUnreadable = managedAccountStoreUnreadable
        self.managedAccountTargetUnavailable = managedAccountTargetUnavailable
        self.profileAccountTargetUnavailable = profileAccountTargetUnavailable
        self.openAIWebCacheScope = openAIWebCacheScope
        self.dashboardAuthorityKnownOwners = dashboardAuthorityKnownOwners
        self.allowExternalOAuthSources = allowExternalOAuthSources
        self.managedWorkspaceAccountID = managedWorkspaceAccountID
    }
}

public enum CodexProviderSettingsKey: ProviderSettingsSectionKey {
    public static let providerID = ProviderInstanceID.codex
    public typealias Section = CodexProviderSettings
}

extension ProviderSettingsSnapshot {
    public typealias CodexProviderSettings = CodexBarCore.CodexProviderSettings
    public var codex: CodexProviderSettings? {
        self[CodexProviderSettingsKey.self]
    }

    public static func make(codex: CodexProviderSettings?) -> Self {
        self.make(codex, for: CodexProviderSettingsKey.self)
    }
}

extension ProviderSettingsSnapshotContribution {
    public static func codex(_ section: CodexProviderSettings) -> Self {
        Self(section, for: CodexProviderSettingsKey.self)
    }
}
