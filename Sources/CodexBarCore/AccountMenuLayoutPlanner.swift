import Foundation

/// Plans the compact ("smart") multi-account menu layout used when a provider
/// surfaces many account rows: the active account keeps its full usage card,
/// inactive accounts collapse to one-line rows sorted most-constrained-first,
/// and a long healthy tail folds behind a single summary row.
///
/// Pure projection: inputs are account snapshots plus menu expansion state,
/// output is an ordered row plan. Rendering and interaction stay in the app layer.
public enum AccountMenuLayoutPlanner {
    /// Compact layout only engages once a provider has this many account rows;
    /// below that the classic stacked cards still fit on screen.
    public static let compactLayoutMinimumAccountCount = 4
    public static let criticalHeadroomPercent: Double = 10
    public static let warningHeadroomPercent: Double = 50
    /// Folding fewer healthy rows than this behind a summary row would not save
    /// meaningful menu height.
    public static let minimumCollapsedHealthyRowCount = 2
    static let constraintDetailWindowLimit = 2

    public enum Severity: Equatable, Sendable {
        case critical
        case warning
        case healthy
    }

    public struct CompactRow: Equatable, Sendable {
        public let accountID: ProviderAccountIdentity
        public let label: String
        /// Lowest remaining percent across the account's usage windows; nil when
        /// the account reported no usable windows (for example an error row).
        public let headroomPercent: Double?
        public let severity: Severity?
        /// Short summary of the constrained windows, e.g. "Fable 0% · Weekly 43%".
        public let constraintDetail: String?
        public let hasError: Bool
        public let canActivate: Bool
        /// Marks the inactive account with the most usable headroom — the best
        /// candidate to switch to next. Only healthy accounts qualify.
        public let isBestCandidate: Bool
    }

    public enum Row: Equatable, Sendable {
        case card(ProviderAccountIdentity)
        case compact(CompactRow)
        /// Healthy accounts folded behind one summary row; `count` is how many are hidden.
        case collapsedHealthy(count: Int)
    }

    public struct Plan: Equatable, Sendable {
        public let rows: [Row]
        public let usesCompactLayout: Bool
    }

    public static func plan(
        accounts: [ProviderAccountUsageSnapshot],
        expandedAccountIDs: Set<ProviderAccountIdentity> = [],
        healthyTailExpanded: Bool = false) -> Plan
    {
        guard accounts.count >= self.compactLayoutMinimumAccountCount else {
            return Plan(rows: accounts.map { .card($0.id) }, usesCompactLayout: false)
        }

        var rows: [Row] = accounts.filter(\.isActive).map { .card($0.id) }

        let inactive = accounts.filter { !$0.isActive }
        let compactRows = self.sortedCompactRows(for: inactive)

        let collapsible = healthyTailExpanded
            ? []
            : compactRows.filter { $0.severity == .healthy && !$0.isBestCandidate && !$0.hasError &&
                !expandedAccountIDs.contains($0.accountID)
            }
        let collapsedIDs: Set<ProviderAccountIdentity> =
            collapsible.count >= self.minimumCollapsedHealthyRowCount
                ? Set(collapsible.map(\.accountID))
                : []

        for row in compactRows where !collapsedIDs.contains(row.accountID) {
            if expandedAccountIDs.contains(row.accountID) {
                rows.append(.card(row.accountID))
            } else {
                rows.append(.compact(row))
            }
        }
        if !collapsedIDs.isEmpty {
            rows.append(.collapsedHealthy(count: collapsedIDs.count))
        }
        return Plan(rows: rows, usesCompactLayout: true)
    }

    public static func severity(forHeadroom headroom: Double) -> Severity {
        if headroom <= self.criticalHeadroomPercent {
            return .critical
        }
        if headroom <= self.warningHeadroomPercent {
            return .warning
        }
        return .healthy
    }

    /// Lowest remaining percent across the account's real usage windows.
    public static func headroomPercent(for account: ProviderAccountUsageSnapshot) -> Double? {
        self.labeledWindows(for: account).map(\.remainingPercent).min()
    }

    private static func sortedCompactRows(for accounts: [ProviderAccountUsageSnapshot]) -> [CompactRow] {
        let bestCandidateID = self.bestCandidateID(in: accounts)
        let unsorted = accounts.map { account in
            self.compactRow(for: account, isBestCandidate: account.id == bestCandidateID)
        }
        return unsorted.enumerated()
            .sorted { lhs, rhs in
                let lhsKey = (lhs.element.headroomPercent ?? 0, lhs.offset)
                let rhsKey = (rhs.element.headroomPercent ?? 0, rhs.offset)
                return lhsKey < rhsKey
            }
            .map(\.element)
    }

    private static func compactRow(
        for account: ProviderAccountUsageSnapshot,
        isBestCandidate: Bool) -> CompactRow
    {
        let windows = self.labeledWindows(for: account)
        let headroom = windows.map(\.remainingPercent).min()
        let constrained = windows
            .filter { $0.remainingPercent <= self.warningHeadroomPercent }
            .sorted { $0.remainingPercent < $1.remainingPercent }
            .prefix(self.constraintDetailWindowLimit)
            .map { "\($0.label) \(Int($0.remainingPercent.rounded()))%" }
        return CompactRow(
            accountID: account.id,
            label: account.displayLabel,
            headroomPercent: headroom,
            severity: headroom.map(self.severity(forHeadroom:)),
            constraintDetail: constrained.isEmpty ? nil : constrained.joined(separator: " · "),
            hasError: account.error != nil,
            canActivate: account.canActivate,
            isBestCandidate: isBestCandidate)
    }

    private static func bestCandidateID(
        in accounts: [ProviderAccountUsageSnapshot]) -> ProviderAccountIdentity?
    {
        accounts
            .compactMap { account -> (id: ProviderAccountIdentity, headroom: Double)? in
                guard account.canActivate, account.error == nil,
                      let headroom = self.headroomPercent(for: account),
                      self.severity(forHeadroom: headroom) == .healthy
                else { return nil }
                return (account.id, headroom)
            }
            .max { $0.headroom < $1.headroom }?
            .id
    }

    private static func labeledWindows(
        for account: ProviderAccountUsageSnapshot) -> [(label: String, remainingPercent: Double)]
    {
        guard let snapshot = account.snapshot else { return [] }
        let metadata = ProviderDefaults.metadata[account.provider]
        var windows: [(label: String, remainingPercent: Double)] = []
        if let primary = snapshot.primary, !primary.isSyntheticPlaceholder {
            windows.append((metadata?.sessionLabel ?? "Session", primary.remainingPercent))
        }
        if let secondary = snapshot.secondary {
            windows.append((metadata?.weeklyLabel ?? "Weekly", secondary.remainingPercent))
        }
        if let tertiary = snapshot.tertiary {
            windows.append((metadata?.opusLabel ?? "Monthly", tertiary.remainingPercent))
        }
        for extra in snapshot.extraRateWindows ?? [] where extra.usageKnown {
            windows.append((self.shortLabel(forWindowTitle: extra.title), extra.window.remainingPercent))
        }
        return windows
    }

    /// Scoped weekly windows are titled "<model> only" for the card view; the
    /// compact row's constraint summary reads better without the suffix.
    public static func shortLabel(forWindowTitle title: String) -> String {
        guard title.hasSuffix(" only") else { return title }
        let trimmed = String(title.dropLast(" only".count))
        return trimmed.isEmpty ? title : trimmed
    }
}
