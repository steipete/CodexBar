import CodexBarCore
import Foundation
import Observation

extension CodexModelsMetric {
    var localizedTitle: String {
        switch self {
        case .tokens: L("codex_models_tokens")
        case .knownCost: L("codex_models_known_cost")
        case .sessionReferences: L("codex_models_session_references")
        }
    }

    var analyticsNoun: String {
        switch self {
        case .tokens: L("codex_models_tokens_lowercase")
        case .knownCost: L("codex_models_known_cost_lowercase")
        case .sessionReferences: L("codex_models_session_references_lowercase")
        }
    }

    var shareBasisTitle: String {
        switch self {
        case .tokens: L("codex_models_total_tokens_lowercase")
        case .knownCost: L("codex_models_known_cost_lowercase")
        case .sessionReferences: L("codex_models_total_session_references_lowercase")
        }
    }
}

extension CodexModelsGranularity {
    var localizedTitle: String {
        switch self {
        case .daily: L("Daily")
        case .weekly: L("Weekly")
        case .monthly: L("Monthly")
        }
    }
}

enum CodexModelsGranularityPreference: String, CaseIterable, Identifiable {
    case automatic
    case daily
    case weekly
    case monthly

    var id: Self {
        self
    }

    var title: String {
        switch self {
        case .automatic: L("Automatic")
        case .daily: L("Daily")
        case .weekly: L("Weekly")
        case .monthly: L("Monthly")
        }
    }
}

enum CodexModelsOptionalColumn: String, CaseIterable, Identifiable {
    case sessionReferences
    case delta

    var id: Self {
        self
    }

    var title: String {
        switch self {
        case .sessionReferences: L("codex_models_session_refs")
        case .delta: L("codex_models_delta_vs_prior")
        }
    }
}

enum CodexModelsTimelinePresentation: Equatable {
    case trend
    case sparse(observedBuckets: Int)
}

struct CodexModelsTimelineData {
    let buckets: [CodexModelsDailyBucket]
    let plottedBuckets: [CodexModelsDailyBucket]
    let completedPlottedBuckets: [CodexModelsDailyBucket]
    let inProgressBucket: CodexModelsDailyBucket?
    let peakBucket: CodexModelsDailyBucket?
    let presentation: CodexModelsTimelinePresentation
    let selectedBucket: CodexModelsDailyBucket?
    let changeFromPeak: Double?

    func selectionStart(nearest date: Date) -> Date? {
        guard let nearest = self.plottedBuckets.min(by: {
            abs($0.day.timeIntervalSince(date)) < abs($1.day.timeIntervalSince(date))
        }) else { return nil }
        let adjacentSpacings = zip(self.plottedBuckets, self.plottedBuckets.dropFirst())
            .map { abs($1.day.timeIntervalSince($0.day)) }
        let threshold = if let minimumSpacing = adjacentSpacings.min() {
            minimumSpacing * 0.32
        } else {
            max(nearest.effectiveInterval.duration * 0.32, 12 * 60 * 60)
        }
        return abs(nearest.day.timeIntervalSince(date)) <= threshold ? nearest.day : nil
    }
}

struct CodexModelsConcentrationData {
    let groups: [CodexModelsVisualGroup]
    let topTwoShare: Double
}

struct CodexModelsSortValue<Value: Comparable>: Comparable {
    let value: Value
    let canonicalID: String

    static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.value != rhs.value { return lhs.value < rhs.value }
        return lhs.canonicalID < rhs.canonicalID
    }
}

struct CodexModelsCostSortValue: Comparable {
    let availability: Int
    let coverage: Double
    let amount: Decimal
    let canonicalID: String

    static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.availability != rhs.availability { return lhs.availability < rhs.availability }
        if lhs.coverage != rhs.coverage { return lhs.coverage < rhs.coverage }
        if lhs.amount != rhs.amount { return lhs.amount < rhs.amount }
        return lhs.canonicalID < rhs.canonicalID
    }
}

struct CodexModelsTableRow: Identifiable {
    let row: CodexModelsRow
    let metric: CodexModelsMetric
    let share: Double

    var id: String {
        self.row.id
    }

    var modelSort: CodexModelsSortValue<String> {
        CodexModelsSortValue(value: self.row.displayName.localizedLowercase, canonicalID: self.id)
    }

    var tokensSort: CodexModelsSortValue<Int64> {
        CodexModelsSortValue(value: self.row.totalTokens, canonicalID: self.id)
    }

    var costSort: CodexModelsCostSortValue {
        let availability = if self.row.cost.pricedTokens == 0 {
            0
        } else if self.row.cost.unpricedTokens > 0 {
            1
        } else {
            2
        }
        return CodexModelsCostSortValue(
            availability: availability,
            coverage: self.row.cost.coverage,
            amount: self.row.cost.knownAmount,
            canonicalID: self.id)
    }

    var sessionReferencesSort: CodexModelsSortValue<Int> {
        CodexModelsSortValue(value: self.row.sessionReferences, canonicalID: self.id)
    }

    var shareSort: CodexModelsSortValue<Double> {
        CodexModelsSortValue(value: self.share, canonicalID: self.id)
    }

    var deltaSort: CodexModelsSortValue<Double> {
        CodexModelsSortValue(value: self.row.comparison(self.metric).sortableValue, canonicalID: self.id)
    }
}

struct CodexModelsVisualGroup: Identifiable {
    let id: String
    let canonicalModelID: String?
    let displayName: String
    let value: Double
    let share: Double
    let modelCount: Int
    let rows: [CodexModelsRow]

    var isOther: Bool {
        self.canonicalModelID == nil
    }
}

@MainActor
@Observable
final class CodexModelsDashboardModel {
    enum Layout: Equatable {
        case wide
        case medium
        case compact
    }

    var snapshot: CodexModelsAnalyticsSnapshot
    private(set) var metric: CodexModelsMetric = .tokens
    private(set) var granularityPreference: CodexModelsGranularityPreference = .automatic
    var searchText = ""
    var selectedModelID: String?
    var selectedBucketStart: Date?
    var layout: Layout = .compact
    var optionalColumns = Set(CodexModelsOptionalColumn.allCases)
    var sortOrder: [KeyPathComparator<CodexModelsTableRow>]

    init(snapshot: CodexModelsAnalyticsSnapshot) {
        self.snapshot = snapshot
        self.sortOrder = Self.defaultSortOrder(metric: .tokens)
    }

    var granularity: CodexModelsGranularity {
        switch self.granularityPreference {
        case .automatic:
            let interval = self.snapshot.currentInterval
            let inclusiveEnd = interval.end.addingTimeInterval(-0.001)
            let start = Calendar.current.startOfDay(for: interval.start)
            let end = Calendar.current.startOfDay(for: inclusiveEnd)
            let days = (Calendar.current.dateComponents([.day], from: start, to: end).day ?? 0) + 1
            if days < 45 { return .daily }
            if days <= 180 { return .weekly }
            return .monthly
        case .daily: return .daily
        case .weekly: return .weekly
        case .monthly: return .monthly
        }
    }

    var selectedRow: CodexModelsRow? {
        self.selectedModelID.flatMap { id in self.snapshot.rows.first { $0.id == id } }
    }

    var tableRows: [CodexModelsTableRow] {
        self.snapshot.rows.map { row in
            CodexModelsTableRow(row: row, metric: self.metric, share: self.snapshot.share(of: row, metric: self.metric))
        }
    }

    var visibleTableRows: [CodexModelsTableRow] {
        let needle = self.searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let filtered = needle.isEmpty ? self.tableRows : self.tableRows.filter { tableRow in
            let row = tableRow.row
            return row.displayName.lowercased().contains(needle)
                || row.id.lowercased().contains(needle)
                || row.rawAliases.contains { $0.lowercased().contains(needle) }
        }
        return filtered.sorted(using: self.sortOrder)
    }

    var selectedModelIsHiddenBySearch: Bool {
        guard let selectedModelID else { return false }
        return !self.visibleTableRows.contains { $0.id == selectedModelID }
    }

    var costMetricIsAvailable: Bool {
        self.snapshot.cost.pricedTokens > 0
    }

    var rankedRows: [CodexModelsRow] {
        self.snapshot.rows.sorted {
            let lhs = $0.metricValue(self.metric)
            let rhs = $1.metricValue(self.metric)
            if lhs != rhs { return lhs > rhs }
            return $0.id < $1.id
        }
    }

    var rankingGroups: [CodexModelsVisualGroup] {
        let rows = self.rankedRows
        return self.visualGroups(
            rows: rows,
            canonicalLimit: rows.count > 8 ? 7 : 8,
            otherID: "ranking-other")
    }

    var concentrationGroups: [CodexModelsVisualGroup] {
        self.concentrationData.groups
    }

    var concentrationData: CodexModelsConcentrationData {
        let rows = self.rankedRows
        let total = self.snapshot.totalValue(self.metric)
        let topTwoValue = rows.prefix(2).reduce(0) { $0 + $1.metricValue(self.metric) }
        return CodexModelsConcentrationData(
            groups: self.visualGroups(rows: rows, canonicalLimit: 5, otherID: "concentration-other"),
            topTwoShare: total == 0 ? 0 : topTwoValue / total)
    }

    var timeline: [CodexModelsDailyBucket] {
        self.timelineData.buckets
    }

    var timelinePresentation: CodexModelsTimelinePresentation {
        self.timelineData.presentation
    }

    var selectedBucket: CodexModelsDailyBucket? {
        self.timelineData.selectedBucket
    }

    var timelineData: CodexModelsTimelineData {
        let source = self.selectedModelID.flatMap { self.snapshot.dailyByModel[$0] } ?? self.snapshot.daily
        let buckets = Self.rebucket(source, granularity: self.granularity)
        let plottedBuckets = self.metric == .knownCost
            ? buckets.filter { $0.cost.pricedTokens > 0 }
            : buckets
        let presentation: CodexModelsTimelinePresentation = plottedBuckets.count < 3
            ? .sparse(observedBuckets: plottedBuckets.count)
            : .trend
        let selectedBucket = self.selectedBucketStart.flatMap { start in
            buckets.first { $0.day == start }
        }
        let observationEnd = min(self.snapshot.generatedAt, self.snapshot.currentInterval.end)
        let completedPlottedBuckets = plottedBuckets.filter { $0.effectiveInterval.end <= observationEnd }
        let inProgressBucket = plottedBuckets.last { bucket in
            bucket.effectiveInterval.start <= observationEnd && bucket.effectiveInterval.end > observationEnd
        }
        let peakBucket = completedPlottedBuckets.max { lhs, rhs in
            self.timelineMetricValue(lhs) < self.timelineMetricValue(rhs)
        }
        let changeFromPeak: Double? = if completedPlottedBuckets.count >= 2,
                                         let peakBucket,
                                         self.timelineMetricValue(peakBucket) > 0,
                                         let latest = completedPlottedBuckets.last,
                                         self.timelineMetricValue(latest) < self.timelineMetricValue(peakBucket)
        {
            (self.timelineMetricValue(latest) - self.timelineMetricValue(peakBucket))
                / self.timelineMetricValue(peakBucket)
        } else {
            nil
        }
        return CodexModelsTimelineData(
            buckets: buckets,
            plottedBuckets: plottedBuckets,
            completedPlottedBuckets: completedPlottedBuckets,
            inProgressBucket: inProgressBucket,
            peakBucket: peakBucket,
            presentation: presentation,
            selectedBucket: selectedBucket,
            changeFromPeak: changeFromPeak)
    }

    var topModel: CodexModelsRow? {
        self.snapshot.totalValue(self.metric) > 0 ? self.rankedRows.first : nil
    }

    func setMetric(_ metric: CodexModelsMetric) {
        guard metric != .knownCost || self.costMetricIsAvailable else { return }
        guard self.metric != metric else { return }
        self.metric = metric
        self.sortOrder = Self.defaultSortOrder(metric: metric)
    }

    func reconcileMetric(costDisplayEnabled: Bool) {
        guard self.metric == .knownCost,
              !costDisplayEnabled || !self.costMetricIsAvailable
        else { return }
        self.metric = .tokens
        self.sortOrder = Self.defaultSortOrder(metric: .tokens)
    }

    func setGranularityPreference(_ preference: CodexModelsGranularityPreference) {
        guard self.granularityPreference != preference else { return }
        self.granularityPreference = preference
        self.selectedBucketStart = nil
    }

    func replaceSnapshot(_ snapshot: CodexModelsAnalyticsSnapshot) {
        let selectedModelID = self.selectedModelID
        let selectedBucketStart = self.selectedBucketStart
        self.snapshot = snapshot
        self.reconcileMetric(costDisplayEnabled: true)
        self.selectedModelID = selectedModelID
            .flatMap { id in snapshot.rows.contains(where: { $0.id == id }) ? id : nil }
        self.selectedBucketStart = selectedBucketStart.flatMap { start in
            self.timeline.contains(where: { $0.day == start }) ? start : nil
        }
    }

    func updateLayout(width: CGFloat) {
        self.layout = if width >= CodexModelsDashboardTokens.Width.wide {
            .wide
        } else if width >= CodexModelsDashboardTokens.Width.medium {
            .medium
        } else {
            .compact
        }
    }

    func selectModel(_ canonicalID: String?) {
        self.selectedModelID = canonicalID
        if let selectedBucketStart,
           !self.timeline.contains(where: { $0.day == selectedBucketStart })
        {
            self.selectedBucketStart = nil
        }
    }

    func exportRows(_ scope: CodexModelsExportScope) -> [CodexModelsRow] {
        switch scope {
        case .visible: self.visibleTableRows.map(\.row)
        case .all: self.snapshot.rows
        case .selected: self.selectedRow.map { [$0] } ?? []
        }
    }

    func clearSelection() {
        self.selectedBucketStart = nil
        self.selectedModelID = nil
    }

    private func visualGroups(
        rows: [CodexModelsRow],
        canonicalLimit: Int,
        otherID: String) -> [CodexModelsVisualGroup]
    {
        let total = self.snapshot.totalValue(self.metric)
        let visible = Array(rows.prefix(canonicalLimit))
        var groups = visible.map { row in
            let value = row.metricValue(self.metric)
            return CodexModelsVisualGroup(
                id: row.id,
                canonicalModelID: row.id,
                displayName: row.displayName,
                value: value,
                share: total == 0 ? 0 : value / total,
                modelCount: 1,
                rows: [row])
        }
        let remainder = Array(rows.dropFirst(canonicalLimit))
        if !remainder.isEmpty {
            let value = remainder.reduce(0) { $0 + $1.metricValue(self.metric) }
            groups.append(CodexModelsVisualGroup(
                id: otherID,
                canonicalModelID: nil,
                displayName: L("codex_models_other_count", remainder.count),
                value: value,
                share: total == 0 ? 0 : value / total,
                modelCount: remainder.count,
                rows: remainder))
        }
        return groups
    }

    private func timelineMetricValue(_ bucket: CodexModelsDailyBucket) -> Double {
        switch self.metric {
        case .tokens: Double(bucket.tokens)
        case .knownCost: NSDecimalNumber(decimal: bucket.cost.knownAmount).doubleValue
        case .sessionReferences: Double(bucket.sessionReferences)
        }
    }

    private static func defaultSortOrder(
        metric: CodexModelsMetric) -> [KeyPathComparator<CodexModelsTableRow>]
    {
        switch metric {
        case .tokens: [KeyPathComparator(\CodexModelsTableRow.tokensSort, order: .reverse)]
        case .knownCost: [KeyPathComparator(\CodexModelsTableRow.costSort, order: .reverse)]
        case .sessionReferences:
            [KeyPathComparator(\CodexModelsTableRow.sessionReferencesSort, order: .reverse)]
        }
    }

    private static func rebucket(
        _ source: [CodexModelsDailyBucket],
        granularity: CodexModelsGranularity) -> [CodexModelsDailyBucket]
    {
        guard granularity != .daily else { return source }
        var calendar = Calendar.autoupdatingCurrent
        calendar.timeZone = .autoupdatingCurrent
        let component: Calendar.Component = granularity == .weekly ? .weekOfYear : .month
        let groups = Dictionary(grouping: source) { bucket in
            calendar.dateInterval(of: component, for: bucket.day)?.start ?? bucket.day
        }
        return groups.map { start, buckets in
            let interval = calendar.dateInterval(of: component, for: start)
                ?? DateInterval(start: start, end: buckets.map(\.effectiveInterval.end).max() ?? start)
            return CodexModelsDailyBucket(
                day: start,
                interval: interval,
                tokens: buckets.reduce(0) { $0 + $1.tokens },
                sessionIDs: Array(Set(buckets.flatMap(\.sessionIDs))).sorted(),
                sessionReferenceIDs: Array(Set(buckets.flatMap(\.sessionReferenceIDs))).sorted(),
                cost: buckets.reduce(CodexModelsCost.zero) { $0.adding($1.cost) })
        }
        .sorted { $0.day < $1.day }
    }
}
