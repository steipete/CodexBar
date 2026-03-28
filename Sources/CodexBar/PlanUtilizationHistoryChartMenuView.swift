import Charts
import CodexBarCore
import SwiftUI

@MainActor
struct PlanUtilizationHistoryChartMenuView: View {
    private enum Layout {
        static let chartHeight: CGFloat = 130
        static let detailHeight: CGFloat = 16
        static let emptyStateHeight: CGFloat = chartHeight + detailHeight
        static let maxPoints = 30
        static let maxAxisLabels = 4
        static let barWidth: CGFloat = 6
    }

    private struct SeriesSelection: Hashable {
        let name: PlanUtilizationSeriesName
        let windowMinutes: Int

        var id: String {
            "\(self.name.rawValue):\(self.windowMinutes)"
        }
    }

    private struct VisibleSeries: Identifiable, Equatable {
        let selection: SeriesSelection
        let title: String
        let history: PlanUtilizationSeriesHistory

        var id: String {
            self.selection.id
        }
    }

    private struct EntryPointAccumulator {
        let effectiveBoundaryDate: Date
        let displayBoundaryDate: Date
        let observedAt: Date
        let usedPercent: Double
        let hasObservedResetBoundary: Bool
    }

    private struct ResetBoundaryLattice {
        let referenceBoundaryDate: Date
        let windowInterval: TimeInterval
    }

    private struct Point: Identifiable {
        let id: Date
        let index: Int
        let date: Date
        let usedPercent: Double
        let isObserved: Bool
    }

    private struct Model {
        let points: [Point]
        let axisIndexes: [Double]
        let xDomain: ClosedRange<Double>?
        let pointsByID: [Date: Point]
        let pointsByIndex: [Int: Point]
        let barColor: Color
        let trackColor: Color
    }

    private let provider: UsageProvider
    private let histories: [PlanUtilizationSeriesHistory]
    private let snapshot: UsageSnapshot?
    private let width: CGFloat

    @State private var selectedSeriesID: String?
    @State private var selectedPointID: Date?

    init(
        provider: UsageProvider,
        histories: [PlanUtilizationSeriesHistory],
        snapshot: UsageSnapshot? = nil,
        width: CGFloat)
    {
        self.provider = provider
        self.histories = histories
        self.snapshot = snapshot
        self.width = width
    }

    var body: some View {
        let visibleSeries = Self.visibleSeries(
            histories: self.histories,
            provider: self.provider,
            snapshot: self.snapshot)
        let effectiveSelectedSeries = visibleSeries.first(where: { $0.id == self.selectedSeriesID }) ?? visibleSeries
            .first
        let model = Self.makeModel(
            history: effectiveSelectedSeries?.history,
            provider: self.provider,
            referenceDate: Date())

        VStack(alignment: .leading, spacing: 10) {
            if visibleSeries.count > 1 {
                Picker(selection: Binding(
                    get: { effectiveSelectedSeries?.id ?? "" },
                    set: { newValue in
                        self.selectedSeriesID = newValue
                        self.selectedPointID = nil
                    })) {
                        ForEach(visibleSeries) { series in
                            Text(series.title).tag(series.id)
                        }
                    } label: {
                        EmptyView()
                    }
                    .labelsHidden()
                        .pickerStyle(.segmented)
            }

            if model.points.isEmpty {
                ZStack {
                    Text(Self.emptyStateText(title: effectiveSelectedSeries?.title))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .frame(height: Layout.emptyStateHeight)
            } else {
                self.utilizationChart(model: model)
                    .chartYAxis(.hidden)
                    .chartYScale(domain: 0...100)
                    .chartXAxis {
                        AxisMarks(values: model.axisIndexes) { value in
                            AxisGridLine().foregroundStyle(Color.clear)
                            AxisTick().foregroundStyle(Color.clear)
                            AxisValueLabel {
                                if let raw = value.as(Double.self) {
                                    let index = Int(raw.rounded())
                                    if let point = model.pointsByIndex[index] {
                                        let isTrailingFullChartLabel = index == model.points.last?.index
                                            && model.points.count == Layout.maxPoints
                                        Self.axisLabel(
                                            for: point,
                                            windowMinutes: effectiveSelectedSeries?.history.windowMinutes ?? 0,
                                            isTrailingFullChartLabel: isTrailingFullChartLabel)
                                    }
                                }
                            }
                        }
                    }
                    .chartLegend(.hidden)
                    .frame(height: Layout.chartHeight)
                    .chartOverlay { proxy in
                        GeometryReader { geo in
                            MouseLocationReader { location in
                                self.updateSelection(location: location, model: model, proxy: proxy, geo: geo)
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .contentShape(Rectangle())
                        }
                    }

                Text(self.detailLine(model: model, windowMinutes: effectiveSelectedSeries?.history.windowMinutes ?? 0))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(height: Layout.detailHeight, alignment: .leading)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(minWidth: self.width, maxWidth: .infinity, alignment: .topLeading)
        .task(id: visibleSeries.map(\.id).joined(separator: ",")) {
            guard let firstVisibleSeries = visibleSeries.first else { return }
            guard !visibleSeries.contains(where: { $0.id == self.selectedSeriesID }) else { return }
            self.selectedSeriesID = firstVisibleSeries.id
            self.selectedPointID = nil
        }
    }

    private nonisolated static func visibleSeries(
        histories: [PlanUtilizationSeriesHistory],
        provider: UsageProvider,
        snapshot: UsageSnapshot?) -> [VisibleSeries]
    {
        let metadata = ProviderDescriptorRegistry.metadata[provider]
        let allowedNames = self.visibleSeriesNames(provider: provider, snapshot: snapshot)
        return histories
            .filter { history in
                guard !history.entries.isEmpty else { return false }
                guard let allowedNames else { return true }
                return allowedNames.contains(history.name)
            }
            .sorted { lhs, rhs in
                let lhsOrder = self.seriesSortOrder(lhs.name)
                let rhsOrder = self.seriesSortOrder(rhs.name)
                if lhsOrder != rhsOrder {
                    return lhsOrder < rhsOrder
                }
                if lhs.windowMinutes != rhs.windowMinutes {
                    return lhs.windowMinutes < rhs.windowMinutes
                }
                return lhs.name.rawValue < rhs.name.rawValue
            }
            .map { history in
                VisibleSeries(
                    selection: SeriesSelection(name: history.name, windowMinutes: history.windowMinutes),
                    title: self.seriesTitle(name: history.name, metadata: metadata),
                    history: history)
            }
    }

    private nonisolated static func visibleSeriesNames(
        provider: UsageProvider,
        snapshot: UsageSnapshot?) -> Set<PlanUtilizationSeriesName>?
    {
        guard let snapshot else { return nil }

        var names: Set<PlanUtilizationSeriesName> = []
        if snapshot.primary != nil {
            names.insert(.session)
        }
        if snapshot.secondary != nil {
            names.insert(.weekly)
        }

        if provider == .claude,
           snapshot.tertiary != nil,
           ProviderDescriptorRegistry.metadata[provider]?.supportsOpus == true
        {
            names.insert(.opus)
        }

        return names
    }

    private nonisolated static func makeModel(
        history: PlanUtilizationSeriesHistory?,
        provider: UsageProvider,
        referenceDate: Date) -> Model
    {
        guard let history else {
            return self.emptyModel(provider: provider)
        }

        var points = self.seriesPoints(history: history, referenceDate: referenceDate)
        if points.count > Layout.maxPoints {
            points = Array(points.suffix(Layout.maxPoints))
        }

        points = points.enumerated().map { offset, point in
            Point(
                id: point.id,
                index: offset,
                date: point.date,
                usedPercent: point.usedPercent,
                isObserved: point.isObserved)
        }

        let pointsByID = Dictionary(uniqueKeysWithValues: points.map { ($0.id, $0) })
        let pointsByIndex = Dictionary(uniqueKeysWithValues: points.map { ($0.index, $0) })
        let color = ProviderDescriptorRegistry.descriptor(for: provider).branding.color
        let barColor = Color(red: color.red, green: color.green, blue: color.blue)
        let trackColor = MenuHighlightStyle.progressTrack(false)

        return Model(
            points: points,
            axisIndexes: self.axisIndexes(points: points, windowMinutes: history.windowMinutes),
            xDomain: self.xDomain(points: points),
            pointsByID: pointsByID,
            pointsByIndex: pointsByIndex,
            barColor: barColor,
            trackColor: trackColor)
    }

    private nonisolated static func emptyModel(provider: UsageProvider) -> Model {
        let color = ProviderDescriptorRegistry.descriptor(for: provider).branding.color
        let barColor = Color(red: color.red, green: color.green, blue: color.blue)
        let trackColor = MenuHighlightStyle.progressTrack(false)
        return Model(
            points: [],
            axisIndexes: [],
            xDomain: nil,
            pointsByID: [:],
            pointsByIndex: [:],
            barColor: barColor,
            trackColor: trackColor)
    }

    private nonisolated static func seriesPoints(
        history: PlanUtilizationSeriesHistory,
        referenceDate: Date) -> [Point]
    {
        guard history.windowMinutes > 0 else { return [] }
        let windowInterval = Double(history.windowMinutes) * 60
        let resetBoundaryLattice = self.resetBoundaryLattice(
            entries: history.entries,
            windowMinutes: history.windowMinutes)
        var strongestObservedPointByPeriod: [Date: EntryPointAccumulator] = [:]

        for entry in history.entries {
            let candidate = self.observedPointCandidate(
                for: entry,
                windowMinutes: history.windowMinutes,
                resetBoundaryLattice: resetBoundaryLattice)

            if let existing = strongestObservedPointByPeriod[candidate.effectiveBoundaryDate],
               !self.shouldPreferObservedPoint(candidate, over: existing)
            {
                continue
            }
            strongestObservedPointByPeriod[candidate.effectiveBoundaryDate] = candidate
        }

        guard !strongestObservedPointByPeriod.isEmpty else { return [] }

        let sortedPeriodBoundaryDates = strongestObservedPointByPeriod.keys.sorted()
        var points: [Point] = []
        var previousPeriodBoundaryDate: Date?

        for periodBoundaryDate in sortedPeriodBoundaryDates {
            if let previousPeriodBoundaryDate {
                var cursor = previousPeriodBoundaryDate.addingTimeInterval(windowInterval)
                while cursor < periodBoundaryDate {
                    points.append(Point(
                        id: cursor,
                        index: 0,
                        date: cursor,
                        usedPercent: 0,
                        isObserved: false))
                    cursor = cursor.addingTimeInterval(windowInterval)
                }
            }

            if let bucket = strongestObservedPointByPeriod[periodBoundaryDate] {
                points.append(Point(
                    id: bucket.effectiveBoundaryDate,
                    index: 0,
                    date: bucket.displayBoundaryDate,
                    usedPercent: bucket.usedPercent,
                    isObserved: true))
            }
            previousPeriodBoundaryDate = periodBoundaryDate
        }

        if let lastObservedPeriodBoundaryDate = sortedPeriodBoundaryDates.last {
            let currentPeriodBoundaryDate = self.currentPeriodBoundaryDate(
                for: referenceDate,
                windowMinutes: history.windowMinutes,
                resetBoundaryLattice: resetBoundaryLattice)

            if currentPeriodBoundaryDate > lastObservedPeriodBoundaryDate {
                var cursor = lastObservedPeriodBoundaryDate.addingTimeInterval(windowInterval)
                while cursor <= currentPeriodBoundaryDate {
                    points.append(Point(
                        id: cursor,
                        index: 0,
                        date: cursor,
                        usedPercent: 0,
                        isObserved: false))
                    cursor = cursor.addingTimeInterval(windowInterval)
                }
            }
        }

        return points
    }

    private nonisolated static func observedPointCandidate(
        for entry: PlanUtilizationHistoryEntry,
        windowMinutes: Int,
        resetBoundaryLattice: ResetBoundaryLattice?) -> EntryPointAccumulator
    {
        let rawResetBoundaryDate = entry.resetsAt.map(self.normalizedBoundaryDate)
        let effectiveBoundaryDate = self.effectivePeriodBoundaryDate(
            for: entry,
            windowMinutes: windowMinutes,
            rawResetBoundaryDate: rawResetBoundaryDate,
            resetBoundaryLattice: resetBoundaryLattice)
        return EntryPointAccumulator(
            effectiveBoundaryDate: effectiveBoundaryDate,
            displayBoundaryDate: rawResetBoundaryDate ?? effectiveBoundaryDate,
            observedAt: entry.capturedAt,
            usedPercent: max(0, min(100, entry.usedPercent)),
            hasObservedResetBoundary: rawResetBoundaryDate != nil)
    }

    private nonisolated static func resetBoundaryLattice(
        entries: [PlanUtilizationHistoryEntry],
        windowMinutes: Int) -> ResetBoundaryLattice?
    {
        guard let latestObservedResetBoundaryDate = entries
            .compactMap(\.resetsAt)
            .map(self.normalizedBoundaryDate)
            .max()
        else {
            return nil
        }
        return ResetBoundaryLattice(
            referenceBoundaryDate: latestObservedResetBoundaryDate,
            windowInterval: Double(windowMinutes) * 60)
    }

    private nonisolated static func normalizedBoundaryDate(_ date: Date) -> Date {
        Date(timeIntervalSince1970: floor(date.timeIntervalSince1970))
    }

    private nonisolated static func effectivePeriodBoundaryDate(
        for entry: PlanUtilizationHistoryEntry,
        windowMinutes: Int,
        rawResetBoundaryDate: Date?,
        resetBoundaryLattice: ResetBoundaryLattice?) -> Date
    {
        if let rawResetBoundaryDate {
            if let resetBoundaryLattice {
                return self.closestPeriodBoundaryDate(
                    to: rawResetBoundaryDate,
                    resetBoundaryLattice: resetBoundaryLattice)
            }
            return rawResetBoundaryDate
        }
        if let resetBoundaryLattice {
            return self.periodBoundaryDate(
                containing: entry.capturedAt,
                resetBoundaryLattice: resetBoundaryLattice)
        }
        return self.syntheticBoundaryDate(for: entry.capturedAt, windowMinutes: windowMinutes)
    }

    private nonisolated static func shouldPreferObservedPoint(
        _ candidate: EntryPointAccumulator,
        over existing: EntryPointAccumulator) -> Bool
    {
        if candidate.usedPercent != existing.usedPercent {
            return candidate.usedPercent > existing.usedPercent
        }
        if candidate.hasObservedResetBoundary != existing.hasObservedResetBoundary {
            return candidate.hasObservedResetBoundary
        }
        if candidate.displayBoundaryDate != existing.displayBoundaryDate {
            return candidate.displayBoundaryDate > existing.displayBoundaryDate
        }
        return candidate.observedAt >= existing.observedAt
    }

    private nonisolated static func currentPeriodBoundaryDate(
        for referenceDate: Date,
        windowMinutes: Int,
        resetBoundaryLattice: ResetBoundaryLattice?) -> Date
    {
        if let resetBoundaryLattice {
            return self.periodBoundaryDate(
                containing: referenceDate,
                resetBoundaryLattice: resetBoundaryLattice)
        }
        return self.syntheticBoundaryDate(for: referenceDate, windowMinutes: windowMinutes)
    }

    private nonisolated static func closestPeriodBoundaryDate(
        to rawBoundaryDate: Date,
        resetBoundaryLattice: ResetBoundaryLattice) -> Date
    {
        let offset = rawBoundaryDate.timeIntervalSince(resetBoundaryLattice.referenceBoundaryDate)
        let periodOffset = (offset / resetBoundaryLattice.windowInterval).rounded()
        return resetBoundaryLattice.referenceBoundaryDate
            .addingTimeInterval(periodOffset * resetBoundaryLattice.windowInterval)
    }

    private nonisolated static func periodBoundaryDate(
        containing capturedAt: Date,
        resetBoundaryLattice: ResetBoundaryLattice) -> Date
    {
        let offset = capturedAt.timeIntervalSince(resetBoundaryLattice.referenceBoundaryDate)
        let periodOffset = ceil(offset / resetBoundaryLattice.windowInterval)
        return resetBoundaryLattice.referenceBoundaryDate
            .addingTimeInterval(periodOffset * resetBoundaryLattice.windowInterval)
    }

    private nonisolated static func syntheticBoundaryDate(for date: Date, windowMinutes: Int) -> Date {
        let bucketSeconds = Double(windowMinutes) * 60
        let bucketIndex = floor(date.timeIntervalSince1970 / bucketSeconds)
        return Date(timeIntervalSince1970: (bucketIndex + 1) * bucketSeconds)
    }

    private nonisolated static func xDomain(points: [Point]) -> ClosedRange<Double>? {
        guard !points.isEmpty else { return nil }
        return -0.5...(Double(Layout.maxPoints) - 0.5)
    }

    private nonisolated static func axisIndexes(points: [Point], windowMinutes: Int) -> [Double] {
        let candidateIndexes = self.axisCandidateIndexes(points: points, windowMinutes: windowMinutes)
        return self.proportionalAxisIndexes(points: points, candidateIndexes: candidateIndexes)
    }

    private nonisolated static func axisCandidateIndexes(points: [Point], windowMinutes: Int) -> [Int] {
        if windowMinutes <= 300 {
            return self.sessionAxisCandidateIndexes(points: points)
        }
        return points.map(\.index)
    }

    private nonisolated static func sessionAxisCandidateIndexes(points: [Point]) -> [Int] {
        guard let firstPoint = points.first else { return [] }
        let calendar = Calendar.current
        var previousPoint = firstPoint
        var rawIndexes: [Int] = [firstPoint.index]

        for point in points.dropFirst() {
            if !calendar.isDate(point.date, inSameDayAs: previousPoint.date) {
                rawIndexes.append(point.index)
            }
            previousPoint = point
        }

        return rawIndexes
    }

    private nonisolated static func proportionalAxisIndexes(points: [Point], candidateIndexes: [Int]) -> [Double] {
        guard !points.isEmpty, !candidateIndexes.isEmpty else { return [] }

        let occupiedFraction = Double(points.count) / Double(Layout.maxPoints)
        let proportionalBudget = Int(ceil(Double(Layout.maxAxisLabels) * occupiedFraction))
        let labelBudget = max(1, min(Layout.maxAxisLabels, proportionalBudget, candidateIndexes.count))

        if labelBudget == 1 {
            return [Double(candidateIndexes[0])]
        }

        let step = Double(candidateIndexes.count - 1) / Double(labelBudget - 1)
        var selectedIndexes = (0..<labelBudget).map { position in
            let candidateOffset = Int((Double(position) * step).rounded())
            return candidateIndexes[candidateOffset]
        }
        selectedIndexes = Array(NSOrderedSet(array: selectedIndexes)) as? [Int] ?? selectedIndexes

        let trailingLabelCutoff = points.first!.index + Int(floor(Double(points.count) * 0.8))
        if selectedIndexes.count > 1,
           let lastSelectedIndex = selectedIndexes.last,
           lastSelectedIndex >= trailingLabelCutoff
        {
            selectedIndexes.removeLast()
        }

        if points.count == Layout.maxPoints,
           let lastVisibleIndex = points.last?.index,
           !selectedIndexes.contains(lastVisibleIndex)
        {
            selectedIndexes.append(lastVisibleIndex)
        }

        let deduplicated = Array(NSOrderedSet(array: selectedIndexes)) as? [Int] ?? selectedIndexes
        return deduplicated.map(Double.init)
    }

    @ViewBuilder
    private static func axisLabel(
        for point: Point,
        windowMinutes: Int,
        isTrailingFullChartLabel: Bool) -> some View
    {
        let label = Text(point.date.formatted(self.axisFormat(windowMinutes: windowMinutes)))
            .font(.caption2)
            .foregroundStyle(Color(nsColor: .tertiaryLabelColor))

        if isTrailingFullChartLabel {
            label
                .frame(width: 48, alignment: .trailing)
                .offset(x: -24)
        } else {
            label
        }
    }

    private nonisolated static func axisFormat(windowMinutes: Int) -> Date.FormatStyle {
        if windowMinutes <= 300 {
            return .dateTime.month(.abbreviated).day()
        }
        return .dateTime.month(.abbreviated).day()
    }

    private nonisolated static func seriesTitle(
        name: PlanUtilizationSeriesName,
        metadata: ProviderMetadata?) -> String
    {
        switch name {
        case .session:
            metadata?.sessionLabel ?? "Session"
        case .weekly:
            metadata?.weeklyLabel ?? "Weekly"
        case .opus:
            metadata?.opusLabel ?? "Opus"
        default:
            self.fallbackTitle(for: name.rawValue)
        }
    }

    private nonisolated static func fallbackTitle(for rawValue: String) -> String {
        let words = rawValue
            .replacingOccurrences(of: "([a-z0-9])([A-Z])", with: "$1 $2", options: .regularExpression)
            .split(separator: " ")
        return words.map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }

    private nonisolated static func seriesSortOrder(_ name: PlanUtilizationSeriesName) -> Int {
        switch name {
        case .session:
            0
        case .weekly:
            1
        case .opus:
            2
        default:
            100
        }
    }

    private nonisolated static func emptyStateText(title: String?) -> String {
        if let title {
            return "No \(title.lowercased()) utilization data yet."
        }
        return "No utilization data yet."
    }

    #if DEBUG
    struct ModelSnapshot: Equatable {
        let pointCount: Int
        let axisIndexes: [Double]
        let xDomain: ClosedRange<Double>?
        let selectedSeries: String?
        let visibleSeries: [String]
        let usedPercents: [Double]
        let pointDates: [String]
    }

    nonisolated static func _modelSnapshotForTesting(
        selectedSeriesRawValue: String? = nil,
        histories: [PlanUtilizationSeriesHistory],
        provider: UsageProvider,
        snapshot: UsageSnapshot? = nil,
        referenceDate: Date? = nil) -> ModelSnapshot
    {
        let visibleSeries = self.visibleSeries(histories: histories, provider: provider, snapshot: snapshot)
        let selectedSeries = visibleSeries.first(where: { $0.id == selectedSeriesRawValue }) ?? visibleSeries.first
        let model = self.makeModel(
            history: selectedSeries?.history,
            provider: provider,
            referenceDate: referenceDate ?? histories.flatMap(\.entries).map(\.capturedAt).max() ?? Date())
        return ModelSnapshot(
            pointCount: model.points.count,
            axisIndexes: model.axisIndexes,
            xDomain: model.xDomain,
            selectedSeries: selectedSeries?.id,
            visibleSeries: visibleSeries.map(\.id),
            usedPercents: model.points.map(\.usedPercent),
            pointDates: model.points.map { point in
                let formatter = DateFormatter()
                formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.timeZone = TimeZone.current
                formatter.dateFormat = "yyyy-MM-dd HH:mm"
                return formatter.string(from: point.date)
            })
    }

    nonisolated static func _detailLineForTesting(
        selectedSeriesRawValue: String? = nil,
        histories: [PlanUtilizationSeriesHistory],
        provider: UsageProvider,
        snapshot: UsageSnapshot? = nil,
        referenceDate: Date? = nil) -> String
    {
        let visibleSeries = self.visibleSeries(histories: histories, provider: provider, snapshot: snapshot)
        let selectedSeries = visibleSeries.first(where: { $0.id == selectedSeriesRawValue }) ?? visibleSeries.first
        let model = self.makeModel(
            history: selectedSeries?.history,
            provider: provider,
            referenceDate: referenceDate ?? histories.flatMap(\.entries).map(\.capturedAt).max() ?? Date())
        return self.detailLine(point: model.points.last, windowMinutes: selectedSeries?.history.windowMinutes ?? 0)
    }

    nonisolated static func _emptyStateTextForTesting(title: String?) -> String {
        self.emptyStateText(title: title)
    }
    #endif

    private func xValue(for index: Int) -> PlottableValue<Double> {
        .value("Series", Double(index))
    }

    @ViewBuilder
    private func utilizationChart(model: Model) -> some View {
        if let xDomain = model.xDomain {
            Chart {
                self.utilizationChartContent(model: model)
            }
            .chartXScale(domain: xDomain)
        } else {
            Chart {
                self.utilizationChartContent(model: model)
            }
        }
    }

    @ChartContentBuilder
    private func utilizationChartContent(model: Model) -> some ChartContent {
        ForEach(model.points) { point in
            BarMark(
                x: self.xValue(for: point.index),
                yStart: .value("Capacity Start", 0),
                yEnd: .value("Capacity End", 100),
                width: .fixed(Layout.barWidth))
                .foregroundStyle(model.trackColor)
            BarMark(
                x: self.xValue(for: point.index),
                yStart: .value("Utilization Start", 0),
                yEnd: .value("Utilization End", point.usedPercent),
                width: .fixed(Layout.barWidth))
                .foregroundStyle(model.barColor)
        }
        if let selected = self.selectedPoint(model: model) {
            RuleMark(x: self.xValue(for: selected.index))
                .foregroundStyle(Color(nsColor: .tertiaryLabelColor))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
        }
    }

    private func selectedPoint(model: Model) -> Point? {
        guard let selectedPointID else { return nil }
        return model.pointsByID[selectedPointID]
    }

    private func detailLine(model: Model, windowMinutes: Int) -> String {
        let activePoint = self.selectedPoint(model: model) ?? model.points.last
        return Self.detailLine(point: activePoint, windowMinutes: windowMinutes)
    }

    private func updateSelection(
        location: CGPoint?,
        model: Model,
        proxy: ChartProxy,
        geo: GeometryProxy)
    {
        guard let location else {
            if self.selectedPointID != nil { self.selectedPointID = nil }
            return
        }

        guard let plotAnchor = proxy.plotFrame else { return }
        let plotFrame = geo[plotAnchor]
        guard plotFrame.contains(location) else {
            if self.selectedPointID != nil { self.selectedPointID = nil }
            return
        }

        let xInPlot = location.x - plotFrame.origin.x
        guard let xValue: Double = proxy.value(atX: xInPlot) else { return }

        var best: (id: Date, distance: Double)?
        for point in model.points {
            let distance = abs(Double(point.index) - xValue)
            if let current = best {
                if distance < current.distance {
                    best = (point.id, distance)
                }
            } else {
                best = (point.id, distance)
            }
        }

        if self.selectedPointID != best?.id {
            self.selectedPointID = best?.id
        }
    }
}

extension PlanUtilizationHistoryChartMenuView {
    private nonisolated static func detailLine(point: Point?, windowMinutes: Int) -> String {
        guard let point else {
            return "-"
        }

        let dateLabel = self.detailDateLabel(for: point.date, windowMinutes: windowMinutes)

        let used = max(0, min(100, point.usedPercent))
        if !point.isObserved {
            return "\(dateLabel): -"
        }
        let usedText = used.formatted(.number.precision(.fractionLength(0...1)))
        return "\(dateLabel): \(usedText)% used"
    }

    private nonisolated static func detailDateLabel(for date: Date, windowMinutes: Int) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.amSymbol = "am"
        formatter.pmSymbol = "pm"
        formatter.dateFormat = "MMM d, h:mm a"
        return formatter.string(from: date)
    }
}
