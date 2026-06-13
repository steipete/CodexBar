import Foundation

public struct CodexVisibleAccount: Equatable, Identifiable, Sendable {
    public let id: String
    public let email: String
    public let workspaceLabel: String?
    public let workspaceAccountID: String?
    public let authFingerprint: String?
    public let storedAccountID: UUID?
    public let selectionSource: CodexActiveSource
    public let isActive: Bool
    public let isLive: Bool
    public let canReauthenticate: Bool
    public let canRemove: Bool

    public init(
        id: String,
        email: String,
        workspaceLabel: String? = nil,
        workspaceAccountID: String? = nil,
        authFingerprint: String? = nil,
        storedAccountID: UUID?,
        selectionSource: CodexActiveSource,
        isActive: Bool,
        isLive: Bool,
        canReauthenticate: Bool,
        canRemove: Bool)
    {
        self.id = id
        self.email = email
        self.workspaceLabel = Self.normalizeWorkspaceLabel(workspaceLabel)
        self.workspaceAccountID = workspaceAccountID
        self.authFingerprint = CodexAuthFingerprint.normalize(authFingerprint)
        self.storedAccountID = storedAccountID
        self.selectionSource = selectionSource
        self.isActive = isActive
        self.isLive = isLive
        self.canReauthenticate = canReauthenticate
        self.canRemove = canRemove
    }

    public var displayName: String {
        guard let workspaceLabel else { return self.email }
        return "\(self.email) — \(workspaceLabel)"
    }

    public var menuDisplayName: String {
        guard let menuWorkspaceLabel else { return self.email }
        return "\(self.email) — \(menuWorkspaceLabel)"
    }

    public var menuWorkspaceLabel: String? {
        guard let workspaceLabel, workspaceLabel.compare("Personal", options: [.caseInsensitive]) != .orderedSame else {
            return nil
        }
        return workspaceLabel
    }

    public var authenticationHealthLabel: String? {
        guard !self.isLive, self.storedAccountID != nil, self.authFingerprint == nil else { return nil }
        return "Missing auth"
    }

    private static func normalizeWorkspaceLabel(_ workspaceLabel: String?) -> String? {
        guard let trimmed = workspaceLabel?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}

public struct CodexVisibleAccountProjection: Equatable, Sendable {
    public let visibleAccounts: [CodexVisibleAccount]
    public let activeVisibleAccountID: String?
    public let liveVisibleAccountID: String?
    public let hasUnreadableAddedAccountStore: Bool

    public init(
        visibleAccounts: [CodexVisibleAccount],
        activeVisibleAccountID: String?,
        liveVisibleAccountID: String?,
        hasUnreadableAddedAccountStore: Bool)
    {
        self.visibleAccounts = visibleAccounts
        self.activeVisibleAccountID = activeVisibleAccountID
        self.liveVisibleAccountID = liveVisibleAccountID
        self.hasUnreadableAddedAccountStore = hasUnreadableAddedAccountStore
    }

    public func source(forVisibleAccountID id: String) -> CodexActiveSource? {
        self.visibleAccounts.first { $0.id == id }?.selectionSource
    }
}

extension DefaultCodexAccountReconciler {
    public func loadVisibleAccounts() -> CodexVisibleAccountProjection {
        CodexVisibleAccountProjection.make(from: self.loadSnapshot())
    }
}

extension CodexVisibleAccountProjection {
    public static func make(from snapshot: CodexAccountReconciliationSnapshot) -> CodexVisibleAccountProjection {
        let resolvedActiveSource = CodexActiveSourceResolver.resolve(from: snapshot).resolvedSource
        var drafts: [VisibleAccountDraft] = []

        for storedAccount in snapshot.storedAccounts {
            let normalizedEmail = snapshot.runtimeEmail(for: storedAccount)
            drafts.append(VisibleAccountDraft(
                email: normalizedEmail,
                workspaceLabel: Self.normalizeWorkspaceLabel(storedAccount.workspaceLabel),
                workspaceAccountID: storedAccount.workspaceAccountID,
                authFingerprint: storedAccount.authFingerprint,
                storedAccountID: storedAccount.id,
                selectionSource: .managedAccount(id: storedAccount.id),
                isLive: false,
                canReauthenticate: true,
                canRemove: true,
                identity: snapshot.runtimeIdentity(for: storedAccount)))
        }

        if let liveSystemAccount = snapshot.liveSystemAccount {
            let normalizedEmail = Self.normalizeVisibleEmail(liveSystemAccount.email)
            let liveIdentity = snapshot.runtimeIdentity(for: liveSystemAccount)
            if let exactStoredAccountID = snapshot.matchingStoredAccountForLiveSystemAccount?.id,
               let exactIndex = drafts.firstIndex(where: { $0.storedAccountID == exactStoredAccountID })
            {
                let existingDraft = drafts[exactIndex]
                let liveWorkspaceLabel = Self.normalizeWorkspaceLabel(liveSystemAccount.workspaceLabel)
                drafts[exactIndex] = VisibleAccountDraft(
                    email: existingDraft.email,
                    workspaceLabel: liveWorkspaceLabel ?? existingDraft.workspaceLabel,
                    workspaceAccountID: liveSystemAccount.workspaceAccountID ?? existingDraft.workspaceAccountID,
                    authFingerprint: liveSystemAccount.authFingerprint ?? existingDraft.authFingerprint,
                    storedAccountID: existingDraft.storedAccountID,
                    selectionSource: .liveSystem,
                    isLive: true,
                    canReauthenticate: existingDraft.canReauthenticate,
                    canRemove: existingDraft.canRemove,
                    identity: liveIdentity)
            } else if let existingIndex = drafts.firstIndex(where: { draft in
                CodexIdentityMatcher.matches(
                    draft.identity,
                    lhsEmail: draft.email,
                    liveIdentity,
                    rhsEmail: normalizedEmail)
            }) {
                let existingDraft = drafts[existingIndex]
                let liveWorkspaceLabel = Self.normalizeWorkspaceLabel(liveSystemAccount.workspaceLabel)
                drafts[existingIndex] = VisibleAccountDraft(
                    email: existingDraft.email,
                    workspaceLabel: liveWorkspaceLabel ?? existingDraft.workspaceLabel,
                    workspaceAccountID: liveSystemAccount.workspaceAccountID ?? existingDraft.workspaceAccountID,
                    authFingerprint: liveSystemAccount.authFingerprint ?? existingDraft.authFingerprint,
                    storedAccountID: existingDraft.storedAccountID,
                    selectionSource: .liveSystem,
                    isLive: true,
                    canReauthenticate: existingDraft.canReauthenticate,
                    canRemove: existingDraft.canRemove,
                    identity: liveIdentity)
            } else {
                drafts.append(VisibleAccountDraft(
                    email: normalizedEmail,
                    workspaceLabel: Self.normalizeWorkspaceLabel(liveSystemAccount.workspaceLabel),
                    workspaceAccountID: liveSystemAccount.workspaceAccountID,
                    authFingerprint: liveSystemAccount.authFingerprint,
                    storedAccountID: nil,
                    selectionSource: .liveSystem,
                    isLive: true,
                    canReauthenticate: true,
                    canRemove: false,
                    identity: liveIdentity))
            }
        }

        let livePath = snapshot.liveSystemAccount.flatMap { CodexHomeScope.normalizedHomePath($0.codexHomePath) }
        let managedPaths = Set(snapshot.storedAccounts.compactMap {
            CodexHomeScope.normalizedHomePath($0.managedHomePath)
        })
        for profileAccount in snapshot.profileHomeAccounts {
            let profilePath = CodexHomeScope.normalizedHomePath(profileAccount.codexHomePath)
            guard let profilePath,
                  profilePath != livePath,
                  !managedPaths.contains(profilePath)
            else {
                continue
            }
            drafts.append(VisibleAccountDraft(
                email: Self.normalizeVisibleEmail(profileAccount.email),
                workspaceLabel: Self.normalizeWorkspaceLabel(profileAccount.workspaceLabel),
                workspaceAccountID: profileAccount.workspaceAccountID,
                authFingerprint: profileAccount.authFingerprint,
                storedAccountID: nil,
                selectionSource: .profileHome(path: profilePath),
                isLive: false,
                canReauthenticate: false,
                canRemove: false,
                identity: snapshot.runtimeIdentity(for: profileAccount)))
        }

        let groupedByEmail = Dictionary(grouping: drafts.indices, by: { drafts[$0].email })
        let visibleAccounts = drafts.map { draft in
            let id = Self.visibleAccountID(for: draft, emailGroupSize: groupedByEmail[draft.email]?.count ?? 0)
            let isActive = switch resolvedActiveSource {
            case .liveSystem:
                draft.selectionSource == .liveSystem
            case let .managedAccount(id):
                draft.selectionSource == .managedAccount(id: id)
            case let .profileHome(path):
                draft.selectionSource == .profileHome(path: path)
            }

            return CodexVisibleAccount(
                id: id,
                email: draft.email,
                workspaceLabel: draft.workspaceLabel,
                workspaceAccountID: draft.workspaceAccountID,
                authFingerprint: draft.authFingerprint,
                storedAccountID: draft.storedAccountID,
                selectionSource: draft.selectionSource,
                isActive: isActive,
                isLive: draft.isLive,
                canReauthenticate: draft.canReauthenticate,
                canRemove: draft.canRemove)
        }.sorted { lhs, rhs in
            if lhs.email != rhs.email {
                return lhs.email < rhs.email
            }
            if lhs.isLive != rhs.isLive {
                return lhs.isLive && !rhs.isLive
            }
            if lhs.displayName != rhs.displayName {
                return lhs.displayName < rhs.displayName
            }
            return lhs.id < rhs.id
        }

        return CodexVisibleAccountProjection(
            visibleAccounts: visibleAccounts,
            activeVisibleAccountID: visibleAccounts.first { $0.isActive }?.id,
            liveVisibleAccountID: visibleAccounts.first { $0.isLive }?.id,
            hasUnreadableAddedAccountStore: snapshot.hasUnreadableAddedAccountStore)
    }

    private static func normalizeVisibleEmail(_ email: String) -> String {
        email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func normalizeWorkspaceLabel(_ workspaceLabel: String?) -> String? {
        guard let trimmed = workspaceLabel?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    private static func visibleAccountID(for draft: VisibleAccountDraft, emailGroupSize: Int) -> String {
        guard emailGroupSize > 1 else { return draft.email }

        switch draft.selectionSource {
        case .liveSystem:
            return "live:\(CodexIdentityMatcher.selectionKey(for: draft.identity, fallbackEmail: draft.email))"
        case let .managedAccount(id):
            return "managed:\(id.uuidString.lowercased())"
        case let .profileHome(path):
            return "profile:\(path)"
        }
    }
}

private struct VisibleAccountDraft {
    let email: String
    let workspaceLabel: String?
    let workspaceAccountID: String?
    let authFingerprint: String?
    let storedAccountID: UUID?
    let selectionSource: CodexActiveSource
    let isLive: Bool
    let canReauthenticate: Bool
    let canRemove: Bool
    let identity: CodexIdentity
}
