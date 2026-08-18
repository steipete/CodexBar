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

    init(
        daily: [Int],
        isCovered: [Bool],
        isScanned: [Bool]? = nil,
        start: Date,
        rangeStart: Date,
        today: Date,
        calendar: Calendar)
    {
        self.daily = daily
        self.isCovered = isCovered
        self.isScanned = isScanned ?? [Bool](repeating: true, count: daily.count)
        self.start = start
        self.rangeStart = rangeStart
        self.today = today
        self.calendar = calendar
    }

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
            to: today) ?? today
        let rangeStartWeekday = calendar.component(.weekday, from: rangeStart)
        let start = calendar.date(
            byAdding: .day,
            value: -(rangeStartWeekday - 1),
            to: rangeStart) ?? rangeStart
        let cellCount = Self.weekCount * Self.dayCount
        var daily = [Int](repeating: 0, count: cellCount)
        var isCovered = [Bool](repeating: false, count: cellCount)
        var isScanned = [Bool](repeating: false, count: cellCount)
        for index in 0..<cellCount {
            guard let date = calendar.date(byAdding: .day, value: index, to: start),
                  rangeStart...today ~= date
            else {
                continue
            }
            isScanned[index] = !unscannedDays.contains(date)
            guard !unknownDays.contains(date), let total = totals[date] else { continue }
            daily[index] = total
            isCovered[index] = true
        }
        return Self(
            daily: daily,
            isCovered: isCovered,
            isScanned: isScanned,
            start: start,
            rangeStart: rangeStart,
            today: today,
            calendar: calendar)
    }

    func date(at index: Int) -> Date? {
        self.calendar.date(byAdding: .day, value: index, to: self.start)
    }

    func weekStartDate(at week: Int) -> Date? {
        self.calendar.date(byAdding: .day, value: week * Self.dayCount, to: self.start)
    }

    var visibleDayCount: Int {
        self.daily.indices.filter(self.isVisible).count
    }

    var coveredDayCount: Int {
        self.daily.indices.count(where: { self.isVisible($0) && self.isCovered[$0] })
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

    static func weeklyTotals(_ daily: [Int]) -> [Int] {
        stride(from: 0, to: daily.count, by: SpendActivitySeries.dayCount).map { start in
            daily[start..<min(start + SpendActivitySeries.dayCount, daily.count)].reduce(0) { total, value in
                let result = total.addingReportingOverflow(value)
                return result.overflow ? Int.max : result.partialValue
            }
        }
    }

    static func cumulativeTotals(_ weekly: [Int]) -> [Int] {
        var sum = 0
        return weekly.map { value in
            let result = sum.addingReportingOverflow(value)
            sum = result.overflow ? Int.max : result.partialValue
            return sum
        }
    }

    static func color(forLevel level: Int) -> Color {
        switch level {
        case 4: self.rgb(0x216E39)
        case 3: self.rgb(0x30A14E)
        case 2: self.rgb(0x40C463)
        case 1: self.rgb(0x9BE9A8)
        default: self.rgb(0xEBEDF0)
        }
    }

    static var uniformFill: Color {
        self.rgb(0x40C463)
    }

    static var unavailableFill: Color {
        self.rgb(0xD6DCE5)
    }

    private static func rgb(_ hex: UInt32) -> Color {
        Color(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255)
    }
}

struct SpendActivityGridGeometry {
    static let weekdayGutterWidth: CGFloat = 40
    static let gridSpacing: CGFloat = 8
    static let tooltipInset: CGFloat = 4
    static let tooltipGap: CGFloat = 7
    static let tooltipWidth: CGFloat = 148
    static let tooltipHeight: CGFloat = 50

    static func gridFrame(containerWidth: CGFloat, columns: Int = SpendActivitySeries.weekCount) -> CGRect {
        let leading = self.weekdayGutterWidth + self.gridSpacing
        let width = max(containerWidth - leading, 0)
        let pitch = columns > 0 ? width / CGFloat(columns) : 0
        return CGRect(x: leading, y: 0, width: width, height: pitch * CGFloat(SpendActivitySeries.dayCount))
    }

    static func weekdayCenter(row: Int, rowPitch: CGFloat) -> CGFloat {
        (CGFloat(row) + 0.5) * rowPitch
    }

    static func tooltipCenterX(anchorX: CGFloat, tooltipWidth: CGFloat, gridWidth: CGFloat) -> CGFloat {
        let halfWidth = tooltipWidth / 2
        let lower = min(halfWidth + self.tooltipInset, gridWidth / 2)
        let upper = max(gridWidth - halfWidth - self.tooltipInset, gridWidth / 2)
        return min(max(anchorX, lower), upper)
    }

    static func tooltipOriginY(anchorY: CGFloat, tooltipHeight: CGFloat, gridHeight: CGFloat) -> CGFloat {
        let below = anchorY + self.tooltipGap
        if below + tooltipHeight <= gridHeight {
            return below
        }
        return max(anchorY - tooltipHeight - self.tooltipGap, 0)
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

enum SpendActivityWeekday {
    static let labeledRows = [1, 3, 5]

    static func label(for row: Int, locale: Locale? = nil) -> String {
        guard self.labeledRows.contains(row) else { return "" }
        let formatter = DateFormatter()
        formatter.locale = locale ?? codexBarLocalizedResourceLocale()
        guard let symbols = formatter.shortStandaloneWeekdaySymbols, symbols.indices.contains(row) else {
            return ""
        }
        return symbols[row]
    }
}

enum SpendActivityDateFormatting {
    static func mediumDateString(_ date: Date, locale: Locale? = nil) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale ?? codexBarLocalizedResourceLocale()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }
}

enum SpendActivityAccessibility {
    static func description(date: Date, value: String, locale: Locale? = nil) -> String {
        "\(SpendActivityDateFormatting.mediumDateString(date, locale: locale)): \(value)"
    }
}

struct SpendActivityHeatmapView: View {
    let points: [SpendDashboardModel.TokenActivityPoint]
    let now: Date
    let selectedDay: Date?
    let onSelectDay: ((Date?) -> Void)?

    @AppStorage("spendActivityViewMode") private var mode: SpendActivityViewMode = .daily
    @State private var series: SpendActivitySeries

    init(
        points: [SpendDashboardModel.TokenActivityPoint],
        now: Date = Date(),
        selectedDay: Date? = nil,
        onSelectDay: ((Date?) -> Void)? = nil)
    {
        self.points = points
        self.now = now
        self.selectedDay = selectedDay
        self.onSelectDay = onSelectDay
        self._series = State(initialValue: SpendActivitySeries.make(from: points, now: now))
    }

    var body: some View {
        let hasActivity = (self.series.daily.max() ?? 0) > 0
        let hasUnknownCoverage = self.series.hasUnknownCoverage
        let totalTokens = Self.saturatingTotal(self.series.daily)
        let coverageText = spendDashboardCoverageText(
            covered: self.series.coveredDayCount,
            requested: self.series.visibleDayCount)
        let weekly = self.series.weeklyActivity()
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("Token activity"))
                        .font(.headline)
                    if hasActivity {
                        Text(self.activitySummary(totalTokens: totalTokens, coverageText: coverageText))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else if hasUnknownCoverage {
                        Text("\(L("Unavailable")) · \(coverageText)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Picker(L("View"), selection: self.$mode) {
                    ForEach(SpendActivityViewMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .fixedSize()
            }

            if hasActivity || hasUnknownCoverage {
                switch self.mode {
                case .daily:
                    SpendActivityDailyGrid(
                        series: self.series,
                        selectedDay: self.selectedDay,
                        onSelectDay: self.onSelectDay)
                    self.dailyLegend
                case .weekly:
                    SpendActivityWeekGrid(
                        series: self.series,
                        activity: weekly,
                        cumulative: false)
                    self.caption(
                        L("Each column = 1 week"),
                        showsUnavailable: weekly.isCovered.contains(false))
                case .cumulative:
                    SpendActivityWeekGrid(
                        series: self.series,
                        activity: weekly.cumulative(),
                        cumulative: true)
                    self.caption(L("Running total"), showsUnavailable: hasUnknownCoverage)
                }
            } else {
                Text(L("No activity in the last 12 months"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 12)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onChange(of: self.points) { _, points in
            self.series = SpendActivitySeries.make(from: points, now: self.now)
        }
    }

    private var dailyLegend: some View {
        HStack(spacing: 4) {
            Spacer()
            Text(L("Less"))
            ForEach(0...4, id: \.self) { level in
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(SpendActivityLevels.color(forLevel: level))
                    .frame(width: 9, height: 9)
            }
            Text(L("More"))
            if self.series.hasUnknownCoverage {
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(SpendActivityLevels.unavailableFill)
                    .frame(width: 9, height: 9)
                    .padding(.leading, 6)
                Text(L("Unavailable"))
            }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
    }

    private func caption(_ text: String, showsUnavailable: Bool) -> some View {
        HStack(spacing: 4) {
            Text(text)
            Spacer()
            if showsUnavailable {
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(SpendActivityLevels.unavailableFill)
                    .frame(width: 9, height: 9)
                Text(L("Unavailable"))
            }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
    }

    private func activitySummary(totalTokens: Int, coverageText: String) -> String {
        let total = UsageFormatter.tokenCountString(totalTokens)
        return self.series.hasUnknownCoverage
            ? "\(total) · \(coverageText)"
            : "\(total) \(L("in the last year"))"
    }

    private static func saturatingTotal(_ values: [Int]) -> Int {
        values.reduce(0) { total, value in
            let result = total.addingReportingOverflow(value)
            return result.overflow ? Int.max : result.partialValue
        }
    }
}

private struct SpendActivityDailyGrid: View {
    let series: SpendActivitySeries
    var selectedDay: Date?
    var onSelectDay: ((Date?) -> Void)?

    @State private var hoveredIndex: Int?
    @State private var keyboardIndex: Int?
    @FocusState private var isKeyboardFocused: Bool

    private let columns = SpendActivitySeries.weekCount
    private let rows = SpendActivitySeries.dayCount

    var body: some View {
        let levels = SpendActivityLevels.dailyLevels(self.series.daily)
        VStack(alignment: .leading, spacing: 3) {
            self.monthRow
            GeometryReader { proxy in
                let gridFrame = SpendActivityGridGeometry.gridFrame(containerWidth: proxy.size.width)
                let pitch = gridFrame.width / CGFloat(self.columns)
                let cell = max(pitch - 2, 2)
                ZStack(alignment: .topLeading) {
                    self.weekdayLabels(rowPitch: pitch)
                    ZStack(alignment: .topLeading) {
                        Canvas { context, _ in
                            let corner = min(cell * 0.22, 2.5)
                            for index in 0..<(self.columns * self.rows) where self.isVisibleCell(index) {
                                let col = index / self.rows
                                let row = index % self.rows
                                let rect = CGRect(
                                    x: CGFloat(col) * pitch + (pitch - cell) / 2,
                                    y: CGFloat(row) * pitch + (pitch - cell) / 2,
                                    width: cell,
                                    height: cell)
                                let fill = self.series.isCovered[index]
                                    ? SpendActivityLevels.color(forLevel: levels[index])
                                    : SpendActivityLevels.unavailableFill
                                context.fill(
                                    RoundedRectangle(cornerRadius: corner, style: .continuous).path(in: rect),
                                    with: .color(fill))
                            }
                        }
                        self.hoverHighlight(cell: cell, pitch: pitch)
                        self.tooltip(size: gridFrame.size, pitch: pitch)
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
                    .offset(x: gridFrame.minX)
                }
            }
            .aspectRatio(CGFloat(self.columns + 2) / CGFloat(self.rows), contentMode: .fit)
        }
        .focusable()
        .focused(self.$isKeyboardFocused)
        .onMoveCommand(perform: self.moveKeyboardSelection)
        .onChange(of: self.isKeyboardFocused) { _, isFocused in
            if isFocused, self.keyboardIndex == nil {
                self.keyboardIndex = self.lastVisibleIndex
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L("Token activity"))
        .accessibilityValue(self.accessibilityValue)
        .accessibilityChildren {
            ForEach(self.series.daily.indices.filter(self.series.isVisible), id: \.self) { index in
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

    private var monthRow: some View {
        GeometryReader { proxy in
            let gridFrame = SpendActivityGridGeometry.gridFrame(containerWidth: proxy.size.width)
            let pitch = gridFrame.width / CGFloat(self.columns)
            ZStack(alignment: .topLeading) {
                ForEach(self.monthMarkers(pitch: pitch)) { marker in
                    Text(marker.label)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .offset(x: gridFrame.minX + marker.offset)
                }
            }
        }
        .frame(height: 14)
    }

    private func weekdayLabels(rowPitch: CGFloat) -> some View {
        ForEach(SpendActivityWeekday.labeledRows, id: \.self) { row in
            Text(SpendActivityWeekday.label(for: row))
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .frame(width: SpendActivityGridGeometry.weekdayGutterWidth, alignment: .trailing)
                .position(
                    x: SpendActivityGridGeometry.weekdayGutterWidth / 2,
                    y: SpendActivityGridGeometry.weekdayCenter(row: row, rowPitch: rowPitch))
        }
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
    private func tooltip(size: CGSize, pitch: CGFloat) -> some View {
        if let index = self.activeIndex, let date = self.series.date(at: index) {
            let col = index / self.rows
            let row = index % self.rows
            let anchorX = CGFloat(col) * pitch + pitch / 2
            let anchorY = CGFloat(row) * pitch + pitch / 2
            let width = min(SpendActivityGridGeometry.tooltipWidth, max(size.width - 8, 1))
            let originY = SpendActivityGridGeometry.tooltipOriginY(
                anchorY: anchorY,
                tooltipHeight: SpendActivityGridGeometry.tooltipHeight,
                gridHeight: size.height)
            SpendActivityTooltip(
                title: self.series.isCovered[index]
                    ? UsageFormatter.tokenCountString(self.series.daily[index])
                    : L("Unavailable"),
                subtitle: SpendActivityDateFormatting.mediumDateString(date),
                width: width)
                .position(
                    x: SpendActivityGridGeometry.tooltipCenterX(
                        anchorX: anchorX,
                        tooltipWidth: width,
                        gridWidth: size.width),
                    y: originY + SpendActivityGridGeometry.tooltipHeight / 2)
                .allowsHitTesting(false)
        }
    }

    private func cellIndex(at location: CGPoint, pitch: CGFloat) -> Int? {
        guard pitch > 0 else { return nil }
        let col = Int(location.x / pitch)
        let row = Int(location.y / pitch)
        guard col >= 0, col < self.columns, row >= 0, row < self.rows else { return nil }
        let index = col * self.rows + row
        return self.isVisibleCell(index) ? index : nil
    }

    private func handleTap(at location: CGPoint, pitch: CGFloat) {
        guard let onSelectDay, let index = self.cellIndex(at: location, pitch: pitch) else { return }
        guard self.series.isCovered.indices.contains(index), self.series.isCovered[index] else { return }
        onSelectDay(SpendActivityDaySelection.day(from: self.series, at: index, selectedDay: self.selectedDay))
    }

    private func isVisibleCell(_ index: Int) -> Bool {
        self.series.isVisible(index)
    }

    private var activeIndex: Int? {
        if let hoveredIndex {
            return hoveredIndex
        }
        return self.keyboardIndex
    }

    private var lastVisibleIndex: Int? {
        self.series.daily.indices.last(where: self.series.isVisible)
    }

    private func moveKeyboardSelection(_ direction: MoveCommandDirection) {
        self.hoveredIndex = nil
        guard let current = self.keyboardIndex ?? self.lastVisibleIndex else { return }
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
        guard let candidate, self.isVisibleCell(candidate) else { return }
        self.keyboardIndex = candidate
    }

    private func moveKeyboardSelectionChronologically(by offset: Int) {
        self.hoveredIndex = nil
        guard let current = self.keyboardIndex else {
            self.keyboardIndex = self.lastVisibleIndex
            return
        }
        let candidate = current + offset
        guard self.isVisibleCell(candidate) else { return }
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

    private static func saturatingTotal(_ values: [Int]) -> Int {
        values.reduce(0) { total, value in
            let result = total.addingReportingOverflow(value)
            return result.overflow ? Int.max : result.partialValue
        }
    }

    private var accessibilityValue: String {
        if let index = self.activeIndex, let date = self.series.date(at: index) {
            return self.accessibilityDescription(at: index, date: date)
        }
        let total = UsageFormatter.tokenCountString(Self.saturatingTotal(self.series.daily))
        guard self.series.hasUnknownCoverage else { return total }
        let coverage = spendDashboardCoverageText(
            covered: self.series.coveredDayCount,
            requested: self.series.visibleDayCount)
        return "\(total) · \(coverage)"
    }

    private func accessibilityDescription(at index: Int, date: Date) -> String {
        SpendActivityAccessibility.description(date: date, value: self.accessibilityTokenValue(at: index))
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

    @State private var hoverLocation: CGPoint?

    private let columns = SpendActivitySeries.weekCount
    private let rows = SpendActivitySeries.dayCount

    var body: some View {
        let maxValue = self.activity.values.enumerated()
            .filter { self.activity.isCovered[$0.offset] }
            .map(\.element)
            .max() ?? 0
        GeometryReader { proxy in
            let gridFrame = SpendActivityGridGeometry.gridFrame(containerWidth: proxy.size.width)
            let pitch = gridFrame.width / CGFloat(self.columns)
            let cell = max(pitch - 2, 2)
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
                            let fill: Color = if !isCovered {
                                SpendActivityLevels.unavailableFill
                            } else if row >= self.rows - filled {
                                SpendActivityLevels.uniformFill
                            } else {
                                SpendActivityLevels.color(forLevel: 0)
                            }
                            let rect = CGRect(
                                x: CGFloat(col) * pitch + (pitch - cell) / 2,
                                y: CGFloat(row) * pitch + (pitch - cell) / 2,
                                width: cell,
                                height: cell)
                            context.fill(
                                RoundedRectangle(cornerRadius: corner, style: .continuous).path(in: rect),
                                with: .color(fill))
                        }
                    }
                }
                self.tooltip(size: gridFrame.size, pitch: pitch)
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
            .offset(x: gridFrame.minX)
        }
        .aspectRatio(CGFloat(self.columns + 2) / CGFloat(self.rows), contentMode: .fit)
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

    @ViewBuilder
    private func tooltip(size: CGSize, pitch: CGFloat) -> some View {
        if let location = self.hoverLocation,
           let col = self.column(at: location, pitch: pitch),
           col < self.activity.values.count,
           let weekStart = self.series.weekStartDate(at: col)
        {
            let width = min(SpendActivityGridGeometry.tooltipWidth, max(size.width - 8, 1))
            let originY = SpendActivityGridGeometry.tooltipOriginY(
                anchorY: location.y,
                tooltipHeight: SpendActivityGridGeometry.tooltipHeight,
                gridHeight: size.height)
            SpendActivityTooltip(
                title: self.activity.isCovered[col]
                    ? UsageFormatter.tokenCountString(self.activity.values[col])
                    : L("Unavailable"),
                subtitle: SpendActivityDateFormatting.mediumDateString(weekStart),
                width: width)
                .position(
                    x: SpendActivityGridGeometry.tooltipCenterX(
                        anchorX: CGFloat(col) * pitch + pitch / 2,
                        tooltipWidth: width,
                        gridWidth: size.width),
                    y: originY + SpendActivityGridGeometry.tooltipHeight / 2)
                .allowsHitTesting(false)
        }
    }

    private func column(at location: CGPoint, pitch: CGFloat) -> Int? {
        guard pitch > 0 else { return nil }
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
        return self.activity.values.reduce(0) { total, value in
            let result = total.addingReportingOverflow(value)
            return result.overflow ? Int.max : result.partialValue
        }
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
        return SpendActivityAccessibility.description(date: weekStart, value: value)
    }
}

private struct SpendActivityTooltip: View {
    let title: String
    let subtitle: String
    let width: CGFloat

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
            height: SpendActivityGridGeometry.tooltipHeight,
            alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor).opacity(0.3))
        }
    }
}
