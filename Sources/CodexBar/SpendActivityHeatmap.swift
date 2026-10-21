import CodexBarCore
import Foundation
import SwiftUI

enum SpendActivityViewMode: String, CaseIterable, Identifiable {
    case daily
    case weekly
    case cumulative

    var id: Self {
        self
    }

    var title: String {
        switch self {
        case .daily: L("Daily")
        case .weekly: L("Weekly")
        case .cumulative: L("Cumulative")
        }
    }
}

enum SpendActivityDaySelection {
    static func day(from series: SpendActivitySeries, at index: Int, selectedDay: Date?) -> Date? {
        guard series.isCovered.indices.contains(index), series.isCovered[index] else { return nil }
        let day = series.date(at: index).map { series.calendar.startOfDay(for: $0) }
        return day == selectedDay ? nil : day
    }
}

struct SpendActivitySeries {
    static let weekCount = 53
    static let dayCount = 7
    static let rangeDayCount = 365

    let daily: [Int]
    let isCovered: [Bool]
    /// Whether the scan window reached the day. A day can be scanned and still uncovered when the
    /// source data is missing, which is a real gap rather than a window edge.
    let isScanned: [Bool]
    let start: Date
    let rangeStart: Date
    let today: Date
    let calendar: Calendar
    let dates: [Date?]
    let visibleIndices: [Int]
    let coveredDayCount: Int

    static func make(
        from points: [SpendDashboardModel.TokenActivityPoint],
        now: Date = Date(),
        calendar: Calendar = .current) -> Self
    {
        var totals: [Date: Int] = [:]
        var unknownDays: Set<Date> = []
        var unscannedDays: Set<Date> = []
        for point in points {
            let day = calendar.startOfDay(for: point.day)
            if !point.isScanned {
                unscannedDays.insert(day)
            }
            guard let totalTokens = point.totalTokens else {
                totals.removeValue(forKey: day)
                unknownDays.insert(day)
                continue
            }
            guard !unknownDays.contains(day) else { continue }
            totals[day] = Self.saturatingAdd(totals[day] ?? 0, max(totalTokens, 0))
        }

        let today = calendar.startOfDay(for: now)
        let rangeStart = calendar.date(
            byAdding: .day,
            value: -(Self.rangeDayCount - 1),
            to: today).map { calendar.startOfDay(for: $0) } ?? today
        let rangeStartWeekday = calendar.component(.weekday, from: rangeStart)
        let start = calendar.date(
            byAdding: .day,
            value: -(rangeStartWeekday - 1),
            to: rangeStart) ?? rangeStart
        let cellCount = Self.weekCount * Self.dayCount
        var daily = [Int](repeating: 0, count: cellCount)
        var isCovered = [Bool](repeating: false, count: cellCount)
        var isScanned = [Bool](repeating: false, count: cellCount)
        let dates = (0..<cellCount).map { index in
            calendar.date(byAdding: .day, value: index, to: start).map { calendar.startOfDay(for: $0) }
        }
        for index in 0..<cellCount {
            // Midnight DST transitions can leave the aligned start at 01:00. Match the day keys above.
            guard let date = dates[index], rangeStart...today ~= date
            else {
                continue
            }
            isScanned[index] = !unscannedDays.contains(date)
            guard !unknownDays.contains(date), let total = totals[date] else { continue }
            daily[index] = total
            isCovered[index] = true
        }
        let visible = dates.indices.filter { index in
            dates[index].map { rangeStart...today ~= $0 } ?? false
        }
        return Self(
            daily: daily,
            isCovered: isCovered,
            isScanned: isScanned,
            start: start,
            rangeStart: rangeStart,
            today: today,
            calendar: calendar,
            dates: dates,
            visibleIndices: visible,
            coveredDayCount: visible.count(where: { isCovered[$0] }))
    }

    func date(at index: Int) -> Date? {
        if self.dates.indices.contains(index) { return self.dates[index] }
        return self.calendar.date(byAdding: .day, value: index, to: self.start)
            .map { self.calendar.startOfDay(for: $0) }
    }

    func weekStartDate(at week: Int) -> Date? {
        self.date(at: week * Self.dayCount)
    }

    var visibleDayCount: Int {
        self.visibleIndices.count
    }

    var hasUnknownCoverage: Bool {
        self.coveredDayCount < self.visibleDayCount
    }

    func weeklyActivity() -> SpendActivityAggregateSeries {
        let firstScannedIndex = self.daily.indices.first { self.isVisible($0) && self.isScanned[$0] }
        var values: [Int] = []
        var coverage: [Bool] = []
        var scanned: [Bool] = []
        for start in stride(from: 0, to: self.daily.count, by: Self.dayCount) {
            let indices = start..<min(start + Self.dayCount, self.daily.count)
            let visible = indices.filter(self.isVisible)
            // The scanned region is contiguous, so unscanned days split into a leading window edge
            // and a trailing stale suffix. Only days before the first scanned day are the window
            // edge; they cannot make a week unavailable. Every visible day from that point on
            // counts, so a trailing unscanned day (a stale snapshot) keeps its week — and every
            // later running total — unavailable.
            let counted: [Int] = if let firstScannedIndex {
                visible.filter { $0 >= firstScannedIndex }
            } else {
                []
            }
            values.append(visible.reduce(0) { Self.saturatingAdd($0, self.daily[$1]) })
            coverage.append(!counted.isEmpty && counted.allSatisfy { self.isCovered[$0] })
            scanned.append(!counted.isEmpty)
        }
        return SpendActivityAggregateSeries(values: values, isCovered: coverage, isScanned: scanned)
    }

    func isVisible(_ index: Int) -> Bool {
        guard let date = self.date(at: index) else { return false }
        return self.rangeStart...self.today ~= date
    }

    static func saturatingAdd(_ lhs: Int, _ rhs: Int) -> Int {
        let result = lhs.addingReportingOverflow(rhs)
        return result.overflow ? Int.max : result.partialValue
    }
}

struct SpendActivityAggregateSeries: Equatable {
    let values: [Int]
    let isCovered: [Bool]
    /// Whether the week holds any day at or after the first scanned day. Weeks entirely before the
    /// scan window are skipped by the running coverage; weeks at or after it participate.
    let isScanned: [Bool]

    init(values: [Int], isCovered: [Bool], isScanned: [Bool]? = nil) {
        self.values = values
        self.isCovered = isCovered
        self.isScanned = isScanned ?? [Bool](repeating: true, count: values.count)
    }

    /// Running total per week. The grid always spans a full year, so a scan window shorter than
    /// 365 days leaves an unscanned prefix. That prefix must not mark the whole series
    /// unavailable, so the running coverage starts at the first scanned week.
    ///
    /// An unscanned week and an unknown week are not the same thing. A week the scan never reached
    /// carries no information either way. A week the scan reached but could not resolve is a real
    /// gap, and every later total is then only a lower bound, so it stays unavailable.
    func cumulative() -> Self {
        var total = 0
        var hasStarted = false
        var coverageIsComplete = true
        var cumulativeValues: [Int] = []
        var cumulativeCoverage: [Bool] = []
        for index in self.values.indices {
            total = SpendActivitySeries.saturatingAdd(total, self.values[index])
            if self.isScanned[index] {
                hasStarted = true
            }
            if hasStarted {
                coverageIsComplete = coverageIsComplete && self.isCovered[index]
            }
            cumulativeValues.append(total)
            cumulativeCoverage.append(hasStarted && coverageIsComplete)
        }
        return Self(values: cumulativeValues, isCovered: cumulativeCoverage, isScanned: self.isScanned)
    }
}

enum SpendActivityLevels {
    static func dailyLevels(_ values: [Int]) -> [Int] {
        let maxValue = values.max() ?? 0
        return values.map { value in
            guard value > 0, maxValue > 0 else { return 0 }
            let ratio = Double(value) / Double(maxValue)
            if ratio > 0.75 {
                return 4
            }
            if ratio > 0.5 {
                return 3
            }
            if ratio > 0.25 {
                return 2
            }
            return 1
        }
    }
}

struct SpendActivityGridGeometry {
    static let minimumCellSize: CGFloat = 10
    static let cellSpacing: CGFloat = 3
    static let tooltipInset: CGFloat = 8
    static let tooltipGap: CGFloat = 5
    static let tooltipWidth: CGFloat = 148
    static let tooltipHeight: CGFloat = 50

    static func gridFrame(containerWidth: CGFloat, columns: Int = SpendActivitySeries.weekCount) -> CGRect {
        let minimumWidth = CGFloat(max(columns, 0)) * (self.minimumCellSize + self.cellSpacing)
        let width = max(containerWidth, minimumWidth)
        let pitch = columns > 0 ? width / CGFloat(columns) : 0
        return CGRect(x: 0, y: 0, width: width, height: pitch * CGFloat(SpendActivitySeries.dayCount))
    }

    static func tooltipCenterX(
        anchorX: CGFloat,
        tooltipWidth: CGFloat,
        gridWidth: CGFloat,
        visibleRect: CGRect? = nil) -> CGFloat
    {
        let lowerEdge = max(visibleRect?.minX ?? 0, 0)
        let upperEdge = min(visibleRect?.maxX ?? gridWidth, gridWidth)
        let center = (lowerEdge + upperEdge) / 2
        let halfWidth = tooltipWidth / 2
        let lower = min(lowerEdge + halfWidth + self.tooltipInset, center)
        let upper = max(upperEdge - halfWidth - self.tooltipInset, center)
        return min(max(anchorX, lower), upper)
    }

    /// Caps the tooltip to the grid's own height so a very short grid (e.g. a narrow window with the
    /// sidebar expanded) compacts the tooltip instead of letting it overflow past the grid's edges.
    static func effectiveTooltipHeight(gridHeight: CGFloat) -> CGFloat {
        min(self.tooltipHeight, gridHeight)
    }

    static func tooltipOriginY(anchorY: CGFloat, tooltipHeight: CGFloat, gridHeight: CGFloat) -> CGFloat {
        let maxOrigin = max(gridHeight - tooltipHeight, 0)
        let above = anchorY - tooltipHeight - self.tooltipGap
        let candidate = above >= self.tooltipInset ? above : anchorY + self.tooltipGap
        return min(max(candidate, 0), maxOrigin)
    }
}

enum SpendActivityGridMove {
    case left
    case right
    case up
    case down
}

enum SpendActivityGridNavigation {
    static func candidate(from current: Int, move: SpendActivityGridMove, rows: Int) -> Int? {
        guard rows > 0 else { return nil }
        let row = current % rows
        return switch move {
        case .left:
            current - rows
        case .right:
            current + rows
        case .up where row > 0:
            current - 1
        case .down where row < rows - 1:
            current + 1
        default:
            nil
        }
    }
}

enum SpendActivityDateFormatting {
    private struct Context: Hashable {
        let calendar: Calendar
        let locale: Locale
        let timeZone: TimeZone
    }

    private static let formatterLock = NSLock()
    private nonisolated(unsafe) static var formatters: [Context: DateFormatter] = [:]

    static func mediumDateString(_ date: Date, calendar: Calendar? = nil, locale: Locale? = nil) -> String {
        let context = Context(
            calendar: calendar ?? .current,
            locale: locale ?? codexBarLocalizedResourceLocale(),
            timeZone: calendar?.timeZone ?? NSTimeZone.default)
        let formatter = self.formatterLock.withLock {
            if let formatter = self.formatters[context] { return formatter }
            let formatter = DateFormatter()
            formatter.locale = context.locale
            formatter.calendar = context.calendar
            formatter.timeZone = context.timeZone
            formatter.dateStyle = .medium
            formatter.timeStyle = .none
            // Bound retained contexts when users change language or reporting time zone.
            if self.formatters.count >= 16 { self.formatters.removeAll(keepingCapacity: true) }
            self.formatters[context] = formatter
            return formatter
        }
        // Published formatters are immutable; DateFormatter supports concurrent string formatting.
        return formatter.string(from: date)
    }
}

enum SpendActivityAccessibility {
    static func description(date: Date, value: String, calendar: Calendar? = nil, locale: Locale? = nil) -> String {
        "\(SpendActivityDateFormatting.mediumDateString(date, calendar: calendar, locale: locale)): \(value)"
    }
}

struct SpendActivityHeatmapView: View {
    let points: [SpendDashboardModel.TokenActivityPoint]
    let now: Date
    let calendar: Calendar
    let selectedDay: Date?
    let onSelectDay: ((Date?) -> Void)?

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @AppStorage("spendActivityViewMode") private var mode: SpendActivityViewMode = .daily
    @State private var series: SpendActivitySeries

    init(
        points: [SpendDashboardModel.TokenActivityPoint],
        now: Date = Date(),
        calendar: Calendar = .current,
        selectedDay: Date? = nil,
        onSelectDay: ((Date?) -> Void)? = nil)
    {
        self.points = points
        self.now = now
        self.calendar = calendar
        self.selectedDay = selectedDay
        self.onSelectDay = onSelectDay
        self._series = State(initialValue: SpendActivitySeries.make(from: points, now: now, calendar: calendar))
    }

    var body: some View {
        let hasActivity = (self.series.daily.max() ?? 0) > 0
        let hasUnknownCoverage = self.series.hasUnknownCoverage
        let totalTokens = self.series.daily.reduce(0, SpendActivitySeries.saturatingAdd)
        let coverageText = spendDashboardCoverageText(
            covered: self.series.coveredDayCount,
            requested: self.series.visibleDayCount)
        let heading = self.heading(hasActivity: hasActivity, totalTokens: totalTokens, coverageText: coverageText)
        VStack(alignment: .leading, spacing: 8) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 16) {
                    heading.fixedSize(horizontal: true, vertical: false)
                    Spacer()
                    self.modePicker
                }
                VStack(alignment: .leading, spacing: 8) {
                    heading
                    self.modePicker
                }
            }

            if hasActivity || hasUnknownCoverage {
                switch self.mode {
                case .daily:
                    SpendActivityDailyGrid(
                        series: self.series,
                        selectedDay: self.selectedDay,
                        onSelectDay: self.onSelectDay)
                    self.dailyLegend
                case .weekly, .cumulative:
                    let weekly = self.series.weeklyActivity()
                    let cumulative = self.mode == .cumulative
                    SpendActivityWeekGrid(
                        series: self.series,
                        activity: cumulative ? weekly.cumulative() : weekly,
                        cumulative: cumulative)
                    self.caption(
                        cumulative ? L("Running total") : L("Each column = 1 week"),
                        showsUnavailable: cumulative ? hasUnknownCoverage : weekly.isCovered.contains(false))
                }
            } else {
                Text(L("No activity in the last 12 months"))
                    .font(.callout)
                    .foregroundStyle(.primary.opacity(0.75))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 12)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onChange(of: self.points) { _, points in
            self.series = SpendActivitySeries.make(from: points, now: self.now, calendar: self.calendar)
        }
        .onChange(of: self.calendar) { _, calendar in
            self.series = SpendActivitySeries.make(from: self.points, now: self.now, calendar: calendar)
        }
    }

    private func heading(hasActivity: Bool, totalTokens: Int, coverageText: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(L("Token activity"))
                .font(.headline)
            if hasActivity {
                Text(self.activitySummary(totalTokens: totalTokens, coverageText: coverageText))
                    .font(.callout)
                    .foregroundStyle(.primary.opacity(0.75))
            } else if self.series.hasUnknownCoverage {
                Text("\(L("Unavailable")) · \(coverageText)")
                    .font(.callout)
                    .foregroundStyle(.primary.opacity(0.75))
            }
        }
    }

    private var modePicker: some View {
        Picker(L("View"), selection: self.$mode) {
            ForEach(SpendActivityViewMode.allCases) { mode in
                Text(mode.title).tag(mode)
            }
        }
        .labelsHidden()
        .pickerStyle(.segmented)
        .fixedSize()
    }

    private var dailyLegend: some View {
        let palette = SpendActivityPalette(colorScheme: self.colorScheme, contrast: self.contrast)
        return HStack(spacing: 4) {
            Spacer()
            Text(L("Less"))
            ForEach(0...4, id: \.self) { level in
                SpendActivitySwatch(palette: palette, level: level)
            }
            Text(L("More"))
            if self.series.hasUnknownCoverage {
                SpendActivitySwatch(palette: palette, level: nil)
                    .padding(.leading, 6)
                Text(L("Unavailable"))
            }
        }
        .font(.callout)
        .foregroundStyle(.primary.opacity(0.75))
    }

    private func caption(_ text: String, showsUnavailable: Bool) -> some View {
        let palette = SpendActivityPalette(colorScheme: self.colorScheme, contrast: self.contrast)
        return HStack(spacing: 4) {
            Text(text)
            Spacer()
            if showsUnavailable {
                SpendActivitySwatch(palette: palette, level: nil)
                Text(L("Unavailable"))
            }
        }
        .font(.callout)
        .foregroundStyle(.primary.opacity(0.75))
    }

    private func activitySummary(totalTokens: Int, coverageText: String) -> String {
        let total = UsageFormatter.tokenCountString(totalTokens)
        return self.series.hasUnknownCoverage
            ? "\(total) · \(coverageText)"
            : "\(total) \(L("in the last year"))"
    }
}

private struct SpendActivityDailyGrid: View {
    let series: SpendActivitySeries
    var selectedDay: Date?
    var onSelectDay: ((Date?) -> Void)?

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var hoveredIndex: Int?
    @State private var keyboardIndex: Int?
    @FocusState private var isKeyboardFocused: Bool

    private let columns = SpendActivitySeries.weekCount
    private let rows = SpendActivitySeries.dayCount

    var body: some View {
        let levels = SpendActivityLevels.dailyLevels(self.series.daily)
        let palette = SpendActivityPalette(colorScheme: self.colorScheme, contrast: self.contrast)
        SpendActivityScrollableGrid(
            headerHeight: 21,
            scrollToIndex: self.keyboardIndex)
        { size, visibleRect in
            VStack(alignment: .leading, spacing: 3) {
                self.monthRow
                let gridFrame = CGRect(origin: .zero, size: size)
                let pitch = gridFrame.width / CGFloat(self.columns)
                let cell = pitch - SpendActivityGridGeometry.cellSpacing
                ZStack(alignment: .topLeading) {
                    ZStack(alignment: .topLeading) {
                        Canvas { context, _ in
                            let corner = min(cell * 0.22, 2.5)
                            for index in 0..<(self.columns * self.rows) where self.series.isVisible(index) {
                                let col = index / self.rows
                                let row = index % self.rows
                                let rect = CGRect(
                                    x: CGFloat(col) * pitch + (pitch - cell) / 2,
                                    y: CGFloat(row) * pitch + (pitch - cell) / 2,
                                    width: cell,
                                    height: cell)
                                palette.drawCell(
                                    in: &context,
                                    rect: rect,
                                    corner: corner,
                                    level: self.series.isCovered[index] ? levels[index] : nil)
                            }
                        }
                        self.hoverHighlight(cell: cell, pitch: pitch)
                        self.tooltip(size: gridFrame.size, pitch: pitch, visibleRect: visibleRect)
                    }
                    .frame(width: gridFrame.width, height: gridFrame.height)
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case let .active(location):
                            self.hoveredIndex = self.cellIndex(at: location, pitch: pitch)
                        case .ended:
                            self.hoveredIndex = nil
                        }
                    }
                    .gesture(SpatialTapGesture().onEnded { event in
                        self.handleTap(at: event.location, pitch: pitch)
                    })
                }
                .frame(width: gridFrame.width, height: gridFrame.height)
            }
            .onChange(of: visibleRect.minX) { _, _ in self.hoveredIndex = nil }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(L("Token activity"))
            .accessibilityValue(self.accessibilityValue)
            .accessibilityChildren {
                ForEach(self.series.visibleIndices, id: \.self) { index in
                    if let date = self.series.date(at: index) {
                        Text(self.accessibilityDescription(at: index, date: date))
                    }
                }
            }
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment:
                    self.moveKeyboardSelectionChronologically(by: 1)
                case .decrement:
                    self.moveKeyboardSelectionChronologically(by: -1)
                @unknown default:
                    break
                }
            }
        }
        .focusable()
        .focusEffectDisabled()
        .focused(self.$isKeyboardFocused)
        .onMoveCommand(perform: self.moveKeyboardSelection)
        .onChange(of: self.isKeyboardFocused) { _, isFocused in
            if isFocused, self.keyboardIndex == nil {
                self.keyboardIndex = self.series.visibleIndices.last
            }
        }
    }

    private var monthRow: some View {
        GeometryReader { proxy in
            let gridFrame = SpendActivityGridGeometry.gridFrame(containerWidth: proxy.size.width)
            let pitch = gridFrame.width / CGFloat(self.columns)
            let markers = self.monthMarkers(pitch: pitch)
            SpendActivityMonthLabelsLayout(offsets: markers.map(\.offset)) {
                ForEach(markers) { marker in
                    Text(marker.label)
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.primary.opacity(0.75))
                }
            }
        }
        .frame(height: 18)
    }

    @ViewBuilder
    private func hoverHighlight(cell: CGFloat, pitch: CGFloat) -> some View {
        if let index = self.activeIndex {
            let col = index / self.rows
            let row = index % self.rows
            RoundedRectangle(cornerRadius: min(cell * 0.22, 2.5), style: .continuous)
                .stroke(Color.primary.opacity(0.7), lineWidth: 1.5)
                .frame(width: cell, height: cell)
                .position(
                    x: CGFloat(col) * pitch + pitch / 2,
                    y: CGFloat(row) * pitch + pitch / 2)
                .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private func tooltip(size: CGSize, pitch: CGFloat, visibleRect: CGRect) -> some View {
        if let index = self.activeIndex,
           let date = self.series.date(at: index),
           visibleRect.minX <= CGFloat(index / self.rows) * pitch + pitch / 2,
           visibleRect.maxX >= CGFloat(index / self.rows) * pitch + pitch / 2
        {
            let col = index / self.rows
            let row = index % self.rows
            let anchorX = CGFloat(col) * pitch + pitch / 2
            let anchorY = CGFloat(row) * pitch + pitch / 2
            let width = min(SpendActivityGridGeometry.tooltipWidth, max(visibleRect.width - 8, 1))
            let height = SpendActivityGridGeometry.effectiveTooltipHeight(gridHeight: size.height)
            let originY = SpendActivityGridGeometry.tooltipOriginY(
                anchorY: anchorY,
                tooltipHeight: height,
                gridHeight: size.height)
            SpendActivityTooltip(
                title: self.series.isCovered[index]
                    ? UsageFormatter.tokenCountString(self.series.daily[index])
                    : L("Unavailable"),
                subtitle: SpendActivityDateFormatting.mediumDateString(date, calendar: self.series.calendar),
                width: width,
                height: height)
                .position(
                    x: SpendActivityGridGeometry.tooltipCenterX(
                        anchorX: anchorX,
                        tooltipWidth: width,
                        gridWidth: size.width,
                        visibleRect: visibleRect),
                    y: originY + height / 2)
                .allowsHitTesting(false)
        }
    }

    private func cellIndex(at location: CGPoint, pitch: CGFloat) -> Int? {
        guard pitch > 0, location.x >= 0, location.y >= 0 else { return nil }
        let col = Int(location.x / pitch)
        let row = Int(location.y / pitch)
        guard col >= 0, col < self.columns, row >= 0, row < self.rows else { return nil }
        let index = col * self.rows + row
        return self.series.isVisible(index) ? index : nil
    }

    private func handleTap(at location: CGPoint, pitch: CGFloat) {
        guard let onSelectDay, let index = self.cellIndex(at: location, pitch: pitch) else { return }
        guard self.series.isCovered.indices.contains(index), self.series.isCovered[index] else { return }
        onSelectDay(SpendActivityDaySelection.day(from: self.series, at: index, selectedDay: self.selectedDay))
    }

    private var activeIndex: Int? {
        self.hoveredIndex ?? self.keyboardIndex
    }

    private func moveKeyboardSelection(_ direction: MoveCommandDirection) {
        self.hoveredIndex = nil
        guard let current = self.keyboardIndex ?? self.series.visibleIndices.last else { return }
        self.keyboardIndex = current
        let move: SpendActivityGridMove? = switch direction {
        case .left:
            .left
        case .right:
            .right
        case .up:
            .up
        case .down:
            .down
        default:
            nil
        }
        guard let move else { return }
        let candidate = SpendActivityGridNavigation.candidate(from: current, move: move, rows: self.rows)
        guard let candidate, self.series.isVisible(candidate) else { return }
        self.keyboardIndex = candidate
    }

    private func moveKeyboardSelectionChronologically(by offset: Int) {
        self.hoveredIndex = nil
        guard let current = self.keyboardIndex else {
            self.keyboardIndex = self.series.visibleIndices.last
            return
        }
        let candidate = current + offset
        guard self.series.isVisible(candidate) else { return }
        self.keyboardIndex = candidate
    }

    private struct MonthMarker: Identifiable {
        let id: Int
        let offset: CGFloat
        let label: String
    }

    private func monthMarkers(pitch: CGFloat) -> [MonthMarker] {
        let formatter = DateFormatter()
        formatter.locale = codexBarLocalizedResourceLocale()
        formatter.calendar = self.series.calendar
        formatter.timeZone = self.series.calendar.timeZone
        formatter.dateFormat = "MMM"
        var markers: [MonthMarker] = []
        var lastLabel = ""
        for col in 0..<self.columns {
            guard let date = self.series.date(at: col * self.rows),
                  self.series.calendar.component(.day, from: date) <= 7
            else { continue }
            let label = formatter.string(from: date)
            guard label != lastLabel else { continue }
            markers.append(MonthMarker(id: col, offset: CGFloat(col) * pitch, label: label))
            lastLabel = label
        }
        return markers
    }

    private var accessibilityValue: String {
        if let index = self.activeIndex, let date = self.series.date(at: index) {
            return self.accessibilityDescription(at: index, date: date)
        }
        let total = UsageFormatter.tokenCountString(self.series.daily.reduce(0, SpendActivitySeries.saturatingAdd))
        guard self.series.hasUnknownCoverage else { return total }
        let coverage = spendDashboardCoverageText(
            covered: self.series.coveredDayCount,
            requested: self.series.visibleDayCount)
        return "\(total) · \(coverage)"
    }

    private func accessibilityDescription(at index: Int, date: Date) -> String {
        SpendActivityAccessibility.description(
            date: date, value: self.accessibilityTokenValue(at: index), calendar: self.series.calendar)
    }

    private func accessibilityTokenValue(at index: Int) -> String {
        self.series.isCovered[index]
            ? UsageFormatter.tokenCountString(self.series.daily[index])
            : L("Unavailable")
    }
}

private struct SpendActivityWeekGrid: View {
    let series: SpendActivitySeries
    let activity: SpendActivityAggregateSeries
    let cumulative: Bool

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var hoverLocation: CGPoint?

    private let columns = SpendActivitySeries.weekCount
    private let rows = SpendActivitySeries.dayCount

    var body: some View {
        let palette = SpendActivityPalette(colorScheme: self.colorScheme, contrast: self.contrast)
        let maxValue = self.activity.values.enumerated()
            .filter { self.activity.isCovered[$0.offset] }
            .map(\.element)
            .max() ?? 0
        SpendActivityScrollableGrid { size, visibleRect in
            let gridFrame = CGRect(origin: .zero, size: size)
            let pitch = gridFrame.width / CGFloat(self.columns)
            let cell = pitch - SpendActivityGridGeometry.cellSpacing
            ZStack(alignment: .topLeading) {
                Canvas { context, _ in
                    let corner = min(cell * 0.22, 2.5)
                    for col in 0..<self.columns where col < self.activity.values.count && self.isVisible(col) {
                        let value = self.activity.values[col]
                        let isCovered = self.activity.isCovered[col]
                        let rawFill = maxValue > 0
                            ? Int((Double(value) / Double(maxValue) * Double(self.rows)).rounded())
                            : 0
                        let filled = value > 0 ? max(rawFill, 1) : 0
                        for row in 0..<self.rows {
                            let level: Int? = if !isCovered {
                                nil
                            } else if row >= self.rows - filled {
                                2
                            } else {
                                0
                            }
                            let rect = CGRect(
                                x: CGFloat(col) * pitch + (pitch - cell) / 2,
                                y: CGFloat(row) * pitch + (pitch - cell) / 2,
                                width: cell,
                                height: cell)
                            palette.drawCell(in: &context, rect: rect, corner: corner, level: level)
                        }
                    }
                }
                self.tooltip(size: gridFrame.size, pitch: pitch, visibleRect: visibleRect)
            }
            .frame(width: gridFrame.width, height: gridFrame.height)
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case let .active(location):
                    self.hoverLocation = self.column(at: location, pitch: pitch) == nil ? nil : location
                case .ended:
                    self.hoverLocation = nil
                }
            }
            .onChange(of: visibleRect.minX) { _, _ in self.hoverLocation = nil }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(L("Token activity"))
            .accessibilityValue(self.accessibilityValue)
            .accessibilityChildren {
                ForEach(self.activity.values.indices.filter(self.isVisible), id: \.self) { index in
                    if let weekStart = self.series.weekStartDate(at: index) {
                        Text(self.accessibilityDescription(at: index, weekStart: weekStart))
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func tooltip(size: CGSize, pitch: CGFloat, visibleRect: CGRect) -> some View {
        if let location = self.hoverLocation,
           let col = self.column(at: location, pitch: pitch),
           col < self.activity.values.count,
           let weekStart = self.series.weekStartDate(at: col)
        {
            let width = min(SpendActivityGridGeometry.tooltipWidth, max(visibleRect.width - 8, 1))
            let height = SpendActivityGridGeometry.effectiveTooltipHeight(gridHeight: size.height)
            let originY = SpendActivityGridGeometry.tooltipOriginY(
                anchorY: location.y,
                tooltipHeight: height,
                gridHeight: size.height)
            SpendActivityTooltip(
                title: self.activity.isCovered[col]
                    ? UsageFormatter.tokenCountString(self.activity.values[col])
                    : L("Unavailable"),
                subtitle: SpendActivityDateFormatting.mediumDateString(weekStart, calendar: self.series.calendar),
                width: width,
                height: height)
                .position(
                    x: SpendActivityGridGeometry.tooltipCenterX(
                        anchorX: CGFloat(col) * pitch + pitch / 2,
                        tooltipWidth: width,
                        gridWidth: size.width,
                        visibleRect: visibleRect),
                    y: originY + height / 2)
                .allowsHitTesting(false)
        }
    }

    private func column(at location: CGPoint, pitch: CGFloat) -> Int? {
        guard pitch > 0, location.x >= 0, location.y >= 0 else { return nil }
        let col = Int(location.x / pitch)
        guard col >= 0, col < self.columns, self.isVisible(col) else { return nil }
        return col
    }

    private func isVisible(_ column: Int) -> Bool {
        guard let start = self.series.weekStartDate(at: column) else { return false }
        let end = self.series.calendar.date(
            byAdding: .day,
            value: SpendActivitySeries.dayCount - 1,
            to: start) ?? start
        return start <= self.series.today && end >= self.series.rangeStart
    }

    private var accessibilityTokenTotal: Int {
        if self.cumulative {
            return self.activity.values.last ?? 0
        }
        return self.activity.values.reduce(0, SpendActivitySeries.saturatingAdd)
    }

    private var accessibilityValue: String {
        let total = UsageFormatter.tokenCountString(self.accessibilityTokenTotal)
        let hasUnavailable = self.activity.isCovered.enumerated().contains { index, covered in
            self.isVisible(index) && !covered
        }
        guard hasUnavailable else { return total }
        let coverage = spendDashboardCoverageText(
            covered: self.series.coveredDayCount,
            requested: self.series.visibleDayCount)
        return "\(total) · \(coverage)"
    }

    private func accessibilityDescription(at index: Int, weekStart: Date) -> String {
        let value = self.activity.isCovered[index]
            ? UsageFormatter.tokenCountString(self.activity.values[index])
            : L("Unavailable")
        return SpendActivityAccessibility.description(
            date: weekStart, value: value, calendar: self.series.calendar)
    }
}

private struct SpendActivityTooltip: View {
    let title: String
    let subtitle: String
    let width: CGFloat
    let height: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(self.title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
            Text(self.subtitle)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .frame(
            width: self.width,
            height: self.height,
            alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor).opacity(0.3))
        }
    }
}
