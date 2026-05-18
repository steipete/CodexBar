import CodexBarCore
import Foundation

enum CodexAccountHealth: Equatable {
    case ok
    case needsReauth
    case workspaceDeactivated
    case missingAuth
    case unavailable

    var label: String? {
        switch self {
        case .ok:
            nil
        case .needsReauth:
            "Needs re-auth"
        case .workspaceDeactivated:
            "Workspace deactivated"
        case .missingAuth:
            "Missing auth"
        case .unavailable:
            "Unavailable"
        }
    }

    static func status(for account: CodexVisibleAccount, error: String?) -> CodexAccountHealth {
        if let error {
            return self.status(forError: error)
        }
        if account.authenticationHealthLabel != nil {
            return .missingAuth
        }
        return .ok
    }

    static func status(forError error: String) -> CodexAccountHealth {
        let normalized = error.lowercased()
        if normalized.contains("deactivated") {
            return .workspaceDeactivated
        }
        if normalized.contains("expired") ||
            normalized.contains("revoked") ||
            normalized.contains("unauthorized") ||
            normalized.contains("401")
        {
            return .needsReauth
        }
        if normalized.contains("missing"), normalized.contains("auth") {
            return .missingAuth
        }
        return .unavailable
    }
}

enum CodexAccountPresentationOrdering {
    static func orderedAccounts(
        _ accounts: [CodexVisibleAccount],
        snapshots: [CodexAccountUsageSnapshot],
        activeVisibleAccountID: String?)
        -> [CodexVisibleAccount]
    {
        guard accounts.count > 1 else { return accounts }
        let snapshotByID = Dictionary(uniqueKeysWithValues: snapshots.map { ($0.id, $0) })
        let rankedAccounts = accounts.enumerated().map { index, account in
            RankedAccount(
                account: account,
                rank: Rank(
                    account: account,
                    snapshot: snapshotByID[account.id],
                    activeVisibleAccountID: activeVisibleAccountID,
                    originalIndex: index))
        }
        let grouped = Dictionary(grouping: rankedAccounts, by: { Self.workspaceSortKey(for: $0.account) })
        return grouped.values.sorted { lhs, rhs in
            (lhs.map(\.rank).min() ?? .last) < (rhs.map(\.rank).min() ?? .last)
        }.flatMap { group in
            group.sorted { lhs, rhs in lhs.rank < rhs.rank }.map(\.account)
        }
    }

    private struct RankedAccount {
        let account: CodexVisibleAccount
        let rank: Rank
    }

    private struct Rank: Comparable {
        static let last = Rank(bucket: Int.max, availabilityScore: -.greatestFiniteMagnitude, originalIndex: Int.max)

        let bucket: Int
        let availabilityScore: Double
        let displaySort: String
        let originalIndex: Int

        private init(bucket: Int, availabilityScore: Double, originalIndex: Int) {
            self.bucket = bucket
            self.availabilityScore = availabilityScore
            self.displaySort = ""
            self.originalIndex = originalIndex
        }

        init(
            account: CodexVisibleAccount,
            snapshot: CodexAccountUsageSnapshot?,
            activeVisibleAccountID: String?,
            originalIndex: Int)
        {
            self.originalIndex = originalIndex
            self.displaySort = account.menuDisplayName.lowercased()

            if account.id == activeVisibleAccountID {
                self.bucket = 0
            } else {
                let health = CodexAccountHealth.status(for: account, error: snapshot?.error)
                if health != .ok {
                    self.bucket = health == .missingAuth ? 4 : 3
                } else if let availability = Self.availability(snapshot?.snapshot), availability <= 0 {
                    self.bucket = 2
                } else {
                    self.bucket = 1
                }
            }
            self.availabilityScore = Self.availability(snapshot?.snapshot) ?? -1
        }

        static func < (lhs: Rank, rhs: Rank) -> Bool {
            if lhs.bucket != rhs.bucket { return lhs.bucket < rhs.bucket }
            if lhs.availabilityScore != rhs.availabilityScore {
                return lhs.availabilityScore > rhs.availabilityScore
            }
            if lhs.displaySort != rhs.displaySort { return lhs.displaySort < rhs.displaySort }
            return lhs.originalIndex < rhs.originalIndex
        }

        private static func availability(_ snapshot: UsageSnapshot?) -> Double? {
            guard let snapshot else { return nil }
            let session = snapshot.primary?.remainingPercent
            let weekly = snapshot.secondary?.remainingPercent
            return switch (session, weekly) {
            case let (.some(session), .some(weekly)):
                min(session, weekly)
            case let (.some(session), .none):
                session
            case let (.none, .some(weekly)):
                weekly
            case (.none, .none):
                nil
            }
        }
    }

    private static func workspaceSortKey(for account: CodexVisibleAccount) -> String {
        if let workspaceAccountID = account.workspaceAccountID, !workspaceAccountID.isEmpty {
            return workspaceAccountID.lowercased()
        }
        return account.menuWorkspaceLabel?.lowercased() ?? "personal"
    }
}

struct CodexAccountWorkspaceSection: Equatable {
    let title: String
    let accounts: [CodexVisibleAccount]
}

extension [CodexVisibleAccount] {
    func codexWorkspaceSections() -> [CodexAccountWorkspaceSection] {
        guard !self.isEmpty else { return [] }
        var sections: [CodexAccountWorkspaceSection] = []
        for account in self {
            let title = account.menuWorkspaceLabel ?? "Personal"
            if let index = sections.firstIndex(where: { $0.title == title }) {
                var accounts = sections[index].accounts
                accounts.append(account)
                sections[index] = CodexAccountWorkspaceSection(title: title, accounts: accounts)
            } else {
                sections.append(CodexAccountWorkspaceSection(title: title, accounts: [account]))
            }
        }
        return sections
    }
}
