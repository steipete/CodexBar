import Foundation

/// Plans the compact ("smart") multi-account menu layout used when a provider
/// surfaces many account rows: the active account keeps its full usage card,
/// inactive accounts collapse to compact rows sorted most-constrained-first,
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

    public enum ResetPresentation: Equatable, Sendable {
        case standard
        case hidden
        case providerDescription
    }

    public struct WindowDetail: Equatable, Sendable {
        public let metricID: String
        public let label: String
        public let window: RateWindow
        public let resetPresentation: ResetPresentation
    }

    public struct CompactRow: Equatable, Sendable {
        public let accountID: ProviderAccountIdentity
        public let label: String
        /// Lowest remaining percent across the account's usage windows; nil when
        /// the account reported no usable windows (for example an error row).
        public let headroomPercent: Double?
        public let severity: Severity?
        /// Constrained windows, or the least remaining window for a healthy account.
        /// Keep reset metadata attached to its own quota until the app formats it.
        public let windowDetails: [WindowDetail]
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
        healthyTailExpanded: Bool = false,
        hiddenMetricIDs: Set<String> = []) -> Plan
    {
        guard accounts.count >= self.compactLayoutMinimumAccountCount else {
            return Plan(rows: accounts.map { .card($0.id) }, usesCompactLayout: false)
        }

        var rows: [Row] = accounts.filter(\.isActive).map { .card($0.id) }

        let inactive = accounts.filter { !$0.isActive }
        let compactRows = self.sortedCompactRows(for: inactive, hiddenMetricIDs: hiddenMetricIDs)

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
        self.labeledWindows(for: account).map(\.window.remainingPercent).min()
    }

    private static func sortedCompactRows(
        for accounts: [ProviderAccountUsageSnapshot],
        hiddenMetricIDs: Set<String>) -> [CompactRow]
    {
        let bestCandidateID = self.bestCandidateID(in: accounts)
        let unsorted = accounts.map { account in
            self.compactRow(
                for: account,
                isBestCandidate: account.id == bestCandidateID,
                hiddenMetricIDs: hiddenMetricIDs)
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
        isBestCandidate: Bool,
        hiddenMetricIDs: Set<String>) -> CompactRow
    {
        let windows = self.labeledWindows(for: account)
            .sorted { $0.window.remainingPercent < $1.window.remainingPercent }
        let headroom = windows.first?.window.remainingPercent
        let visibleWindows = windows.filter { !hiddenMetricIDs.contains($0.metricID) }
        let constrained = visibleWindows.filter { $0.window.remainingPercent <= self.warningHeadroomPercent }
        let details = constrained.isEmpty
            ? visibleWindows.prefix(1)
            : constrained.prefix(self.constraintDetailWindowLimit)
        return CompactRow(
            accountID: account.id,
            label: account.displayLabel,
            headroomPercent: headroom,
            severity: headroom.map(self.severity(forHeadroom:)),
            windowDetails: Array(details),
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
        for account: ProviderAccountUsageSnapshot) -> [WindowDetail]
    {
        guard let snapshot = account.snapshot else { return [] }
        let metadata = ProviderDefaults.metadata[account.provider]
        var windows: [WindowDetail] = []
        if let primary = snapshot.primary, !primary.isSyntheticPlaceholder {
            windows.append(WindowDetail(
                metricID: "primary",
                label: metadata?.sessionLabel ?? "Session",
                window: primary,
                resetPresentation: self.primaryResetPresentation(for: account, window: primary)))
        }
        if let secondary = snapshot.secondary {
            windows.append(WindowDetail(
                metricID: "secondary",
                label: metadata?.weeklyLabel ?? "Weekly",
                window: secondary,
                resetPresentation: .standard))
        }
        if let tertiary = snapshot.tertiary {
            windows.append(WindowDetail(
                metricID: "tertiary",
                label: metadata?.opusLabel ?? "Monthly",
                window: tertiary,
                resetPresentation: .standard))
        }
        for extra in snapshot.extraRateWindows ?? [] where extra.usageKnown {
            windows.append(WindowDetail(
                metricID: extra.id,
                label: self.shortLabel(forWindowTitle: extra.title),
                window: extra.window,
                resetPresentation: .standard))
        }
        return windows
    }

    private static func primaryResetPresentation(
        for account: ProviderAccountUsageSnapshot,
        window: RateWindow) -> ResetPresentation
    {
        let policy = ProviderDescriptorRegistry.descriptor(for: account.provider).presentation.menuCard
        if policy.clearsPrimaryReset ||
            ((policy.hidesPrimaryResetWithoutDate || policy.usesAbacusPace) && window.resetsAt == nil) ||
            (policy.hidesPrimaryResetWithoutSecondary && account.snapshot?.secondary == nil)
        {
            return .hidden
        }
        if policy.usesRawPrimaryResetDescription {
            return .providerDescription
        }
        if policy.primaryDescriptionPlacement == .reset,
           let description = window.resetDescription,
           !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            return .providerDescription
        }
        return .standard
    }

    /// Scoped weekly windows are titled "<model> only" for the card view; the
    /// compact row's constraint summary reads better without the suffix.
    public static func shortLabel(forWindowTitle title: String) -> String {
        guard title.hasSuffix(" only") else { return title }
        let trimmed = String(title.dropLast(" only".count))
        return trimmed.isEmpty ? title : trimmed
    }
}
