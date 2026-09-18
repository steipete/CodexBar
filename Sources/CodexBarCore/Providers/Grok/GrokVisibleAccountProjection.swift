import Foundation

public struct GrokVisibleAccount: Equatable, Identifiable, Sendable {
    public static let liveAccountID = "live"

    public let id: String
    public let email: String
    public let storedAccountID: UUID?
    public let selectionSource: GrokActiveSource
    public let managedHomePath: String?
    public let isActive: Bool
    public let isLive: Bool
    public let canReauthenticate: Bool
    public let canRemove: Bool

    public init(
        id: String,
        email: String,
        storedAccountID: UUID?,
        selectionSource: GrokActiveSource,
        managedHomePath: String?,
        isActive: Bool,
        isLive: Bool,
        canReauthenticate: Bool,
        canRemove: Bool)
    {
        self.id = id
        self.email = email
        self.storedAccountID = storedAccountID
        self.selectionSource = selectionSource
        self.managedHomePath = managedHomePath
        self.isActive = isActive
        self.isLive = isLive
        self.canReauthenticate = canReauthenticate
        self.canRemove = canRemove
    }

    public var displayName: String {
        self.email
    }
}

public struct GrokVisibleAccountProjection: Equatable, Sendable {
    public let visibleAccounts: [GrokVisibleAccount]
    public let activeVisibleAccountID: String?
    public let liveVisibleAccountID: String?
    public let hasUnreadableAddedAccountStore: Bool

    public init(
        visibleAccounts: [GrokVisibleAccount],
        activeVisibleAccountID: String?,
        liveVisibleAccountID: String?,
        hasUnreadableAddedAccountStore: Bool)
    {
        self.visibleAccounts = visibleAccounts
        self.activeVisibleAccountID = activeVisibleAccountID
        self.liveVisibleAccountID = liveVisibleAccountID
        self.hasUnreadableAddedAccountStore = hasUnreadableAddedAccountStore
    }

    public func source(forVisibleAccountID id: String) -> GrokActiveSource? {
        self.visibleAccounts.first { $0.id == id }?.selectionSource
    }

    public func account(id: String) -> GrokVisibleAccount? {
        self.visibleAccounts.first { $0.id == id }
    }
}

public enum GrokActiveSourceResolver {
    public static func resolve(
        persistedSource: GrokActiveSource,
        liveAccount: GrokVisibleAccount?,
        managedAccounts: [ManagedGrokAccount]) -> GrokActiveSource
    {
        switch persistedSource {
        case .liveSystem:
            if liveAccount != nil { return .liveSystem }
            if let first = managedAccounts.first { return .managedAccount(id: first.id) }
            return .liveSystem
        case let .managedAccount(id):
            if managedAccounts.contains(where: { $0.id == id }) {
                return .managedAccount(id: id)
            }
            if liveAccount != nil { return .liveSystem }
            if let first = managedAccounts.first { return .managedAccount(id: first.id) }
            return .liveSystem
        }
    }
}

public enum GrokVisibleAccountProjectionFactory {
    public static func make(
        liveEmail: String?,
        liveHomePath: String?,
        managedAccounts: [ManagedGrokAccount],
        persistedSource: GrokActiveSource,
        hasUnreadableAddedAccountStore: Bool) -> GrokVisibleAccountProjection
    {
        let liveAccount: GrokVisibleAccount? = {
            guard let email = liveEmail?.trimmingCharacters(in: .whitespacesAndNewlines), !email.isEmpty else {
                return nil
            }
            return GrokVisibleAccount(
                id: GrokVisibleAccount.liveAccountID,
                email: ManagedGrokAccount.normalizeEmail(email),
                storedAccountID: nil,
                selectionSource: .liveSystem,
                managedHomePath: liveHomePath,
                isActive: false,
                isLive: true,
                canReauthenticate: true,
                canRemove: false)
        }()

        let resolvedSource = GrokActiveSourceResolver.resolve(
            persistedSource: persistedSource,
            liveAccount: liveAccount,
            managedAccounts: managedAccounts)

        var accounts: [GrokVisibleAccount] = []
        if let liveAccount {
            accounts.append(GrokVisibleAccount(
                id: liveAccount.id,
                email: liveAccount.email,
                storedAccountID: liveAccount.storedAccountID,
                selectionSource: liveAccount.selectionSource,
                managedHomePath: liveAccount.managedHomePath,
                isActive: resolvedSource == .liveSystem,
                isLive: true,
                canReauthenticate: true,
                canRemove: false))
        }
        for stored in managedAccounts {
            let isActive: Bool = if case let .managedAccount(id) = resolvedSource {
                id == stored.id
            } else {
                false
            }
            accounts.append(GrokVisibleAccount(
                id: stored.id.uuidString,
                email: stored.email,
                storedAccountID: stored.id,
                selectionSource: .managedAccount(id: stored.id),
                managedHomePath: stored.managedHomePath,
                isActive: isActive,
                isLive: false,
                canReauthenticate: true,
                canRemove: true))
        }

        let activeID = accounts.first(where: \.isActive)?.id
        return GrokVisibleAccountProjection(
            visibleAccounts: accounts,
            activeVisibleAccountID: activeID,
            liveVisibleAccountID: liveAccount?.id,
            hasUnreadableAddedAccountStore: hasUnreadableAddedAccountStore)
    }
}

public enum GrokFetchedAccountIdentity {
    public static func matches(_ fetchedEmail: String?, storedEmail: String) -> Bool {
        guard let fetched = fetchedEmail?.trimmingCharacters(in: .whitespacesAndNewlines), !fetched.isEmpty else {
            return true
        }
        return ManagedGrokAccount.normalizeEmail(fetched) == ManagedGrokAccount.normalizeEmail(storedEmail)
    }
}
