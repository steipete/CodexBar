import Charts
import CodexBarCore
import SwiftUI

@MainActor
struct CodeBuddyDailyUsageChartMenuView: View {
    private struct Point: Identifiable {
        let id: String
        let date: Date
        let creditsUsed: Double

        init(date: Date, creditsUsed: Double) {
            self.date = date
            self.creditsUsed = creditsUsed
            self.id = "\(Int(date.timeIntervalSince1970))-\(creditsUsed)"
        }
    }

    private let dailyUsage: [CodeBuddyDailyUsageEntry]
    private let width: CGFloat
    @State private var selectedDayKey: String?

    init(dailyUsage: [CodeBuddyDailyUsageEntry], width: CGFloat) {
        self.dailyUsage = dailyUsage
        self.width = width
    }

    var body: some View {
        let model = Self.makeModel(from: self.dailyUsage)
        VStack(alignment: .leading, spacing: 10) {
            if model.points.isEmpty {
                Text("No usage history data.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                Chart {
                    ForEach(model.points) { point in
                        BarMark(
                            x: .value("Day", point.date, unit: .day),
                            y: .value("Credits used", point.creditsUsed))
                            .foregroundStyle(Self.barColor)
                    }
                    if let peak = Self.peakPoint(model: model) {
                        let capStart = max(peak.creditsUsed - Self.capHeight(maxValue: model.maxCreditsUsed), 0)
                        BarMark(
                            x: .value("Day", peak.date, unit: .day),
                            yStart: .value("Cap start", capStart),
                            yEnd: .value("Cap end", peak.creditsUsed))
                            .foregroundStyle(Color(nsColor: .systemYellow))
                    }
                }
                .chartYAxis(.hidden)
                .chartXAxis {
                    AxisMarks(values: model.axisDates) { _ in
                        AxisGridLine().foregroundStyle(Color.clear)
                        AxisTick().foregroundStyle(Color.clear)
                        AxisValueLabel(format: .dateTime.month(.abbreviated).day())
                            .font(.caption2)
                            .foregroundStyle(Color(nsColor: .tertiaryLabelColor))
                    }
                }
                .chartLegend(.hidden)
                .frame(height: 130)
                .chartOverlay { proxy in
                    GeometryReader { geo in
                        ZStack(alignment: .topLeading) {
                            if let rect = self.selectionBandRect(model: model, proxy: proxy, geo: geo) {
                                Rectangle()
                                    .fill(Self.selectionBandColor)
                                    .frame(width: rect.width, height: rect.height)
                                    .position(x: rect.midX, y: rect.midY)
                                    .allowsHitTesting(false)
                            }
                            MouseLocationReader { location in
                                self.updateSelection(location: location, model: model, proxy: proxy, geo: geo)
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .contentShape(Rectangle())
                        }
                    }
                }

                let detail = self.detailLines(model: model)
                VStack(alignment: .leading, spacing: 0) {
                    Text(detail.primary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(height: 16, alignment: .leading)
                    Text(detail.secondary ?? " ")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(height: 16, alignment: .leading)
                        .opacity(detail.secondary == nil ? 0 : 1)
                }

                if let total = model.totalCreditsUsed {
                    Text("Total (30d): \(total.formatted(.number.precision(.fractionLength(0...2)))) credits")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(minWidth: self.width, maxWidth: .infinity, alignment: .leading)
    }

    private struct Model {
        let points: [Point]
        let usageByDayKey: [String: CodeBuddyDailyUsageEntry]
        let pointsByDayKey: [String: Point]
        let dayDates: [(dayKey: String, date: Date)]
        let selectableDayDates: [(dayKey: String, date: Date)]
        let axisDates: [Date]
        let peakKey: String?
        let totalCreditsUsed: Double?
        let maxCreditsUsed: Double
    }

    // CodeBuddy brand color (blue)
    private static let barColor = Color(red: 0 / 255, green: 120 / 255, blue: 215 / 255)
    private static let selectionBandColor = Color(nsColor: .labelColor).opacity(0.1)
    private static func capHeight(maxValue: Double) -> Double {
        maxValue * 0.05
    }

    private static func makeModel(from dailyUsage: [CodeBuddyDailyUsageEntry]) -> Model {
        let sorted = dailyUsage.sorted { lhs, rhs in lhs.date < rhs.date }

        var points: [Point] = []
        points.reserveCapacity(sorted.count)

        var usageByDayKey: [String: CodeBuddyDailyUsageEntry] = [:]
        usageByDayKey.reserveCapacity(sorted.count)

        var pointsByDayKey: [String: Point] = [:]
        pointsByDayKey.reserveCapacity(sorted.count)

        var dayDates: [(dayKey: String, date: Date)] = []
        dayDates.reserveCapacity(sorted.count)

        var selectableDayDates: [(dayKey: String, date: Date)] = []
        selectableDayDates.reserveCapacity(sorted.count)

        var totalCreditsUsed: Double = 0
        var peak: (key: String, creditsUsed: Double)?
        var maxCreditsUsed: Double = 0

        for entry in sorted {
            guard let date = self.dateFromDayKey(entry.date) else { continue }
            usageByDayKey[entry.date] = entry
            dayDates.append((dayKey: entry.date, date: date))
            totalCreditsUsed += entry.credit
            if entry.credit > 0 {
                let point = Point(date: date, creditsUsed: entry.credit)
                points.append(point)
                pointsByDayKey[entry.date] = point
                selectableDayDates.append((dayKey: entry.date, date: date))
                if let cur = peak {
                    if entry.credit > cur.creditsUsed { peak = (entry.date, entry.credit) }
                } else {
                    peak = (entry.date, entry.credit)
                }
                maxCreditsUsed = max(maxCreditsUsed, entry.credit)
            }
        }

        let axisDates: [Date] = {
            guard let first = dayDates.first?.date, let last = dayDates.last?.date else { return [] }
            if Calendar.current.isDate(first, inSameDayAs: last) { return [first] }
            return [first, last]
        }()

        return Model(
            points: points,
            usageByDayKey: usageByDayKey,
            pointsByDayKey: pointsByDayKey,
            dayDates: dayDates,
            selectableDayDates: selectableDayDates,
            axisDates: axisDates,
            peakKey: peak?.key,
            totalCreditsUsed: totalCreditsUsed > 0 ? totalCreditsUsed : nil,
            maxCreditsUsed: maxCreditsUsed)
    }

    private static func dateFromDayKey(_ key: String) -> Date? {
        let parts = key.split(separator: "-")
        guard parts.count == 3,
              let year = Int(parts[0]),
              let month = Int(parts[1]),
              let day = Int(parts[2])
        else {
            return nil
        }

        var comps = DateComponents()
        comps.calendar = Calendar.current
        comps.timeZone = TimeZone.current
        comps.year = year
        comps.month = month
        comps.day = day
        comps.hour = 12
        return comps.date
    }

    private static func peakPoint(model: Model) -> Point? {
        guard let key = model.peakKey else { return nil }
        return model.pointsByDayKey[key]
    }

    private func selectionBandRect(model: Model, proxy: ChartProxy, geo: GeometryProxy) -> CGRect? {
        guard let key = self.selectedDayKey else { return nil }
        guard let plotAnchor = proxy.plotFrame else { return nil }
        let plotFrame = geo[plotAnchor]
        guard let index = model.dayDates.firstIndex(where: { $0.dayKey == key }) else { return nil }
        let date = model.dayDates[index].date
        guard let x = proxy.position(forX: date) else { return nil }

        func xForIndex(_ idx: Int) -> CGFloat? {
            guard idx >= 0, idx < model.dayDates.count else { return nil }
            return proxy.position(forX: model.dayDates[idx].date)
        }

        let xPrev = xForIndex(index - 1)
        let xNext = xForIndex(index + 1)

        if model.dayDates.count <= 1 {
            return CGRect(
                x: plotFrame.origin.x,
                y: plotFrame.origin.y,
                width: plotFrame.width,
                height: plotFrame.height)
        }

        let leftInPlot: CGFloat = if let xPrev {
            (xPrev + x) / 2
        } else if let xNext {
            x - (xNext - x) / 2
        } else {
            x - 8
        }

        let rightInPlot: CGFloat = if let xNext {
            (xNext + x) / 2
        } else if let xPrev {
            x + (x - xPrev) / 2
        } else {
            x + 8
        }

        let left = plotFrame.origin.x + min(leftInPlot, rightInPlot)
        let right = plotFrame.origin.x + max(leftInPlot, rightInPlot)
        return CGRect(x: left, y: plotFrame.origin.y, width: right - left, height: plotFrame.height)
    }

    private func updateSelection(
        location: CGPoint?,
        model: Model,
        proxy: ChartProxy,
        geo: GeometryProxy)
    {
        guard let location else {
            if self.selectedDayKey != nil { self.selectedDayKey = nil }
            return
        }

        guard let plotAnchor = proxy.plotFrame else { return }
        let plotFrame = geo[plotAnchor]
        guard plotFrame.contains(location) else { return }

        let xInPlot = location.x - plotFrame.origin.x
        guard let date: Date = proxy.value(atX: xInPlot) else { return }
        guard let nearest = self.nearestDayKey(to: date, model: model) else { return }

        if self.selectedDayKey != nearest {
            self.selectedDayKey = nearest
        }
    }

    private func nearestDayKey(to date: Date, model: Model) -> String? {
        guard !model.selectableDayDates.isEmpty else { return nil }
        var best: (key: String, distance: TimeInterval)?
        for entry in model.selectableDayDates {
            let dist = abs(entry.date.timeIntervalSince(date))
            if let cur = best {
                if dist < cur.distance { best = (entry.dayKey, dist) }
            } else {
                best = (entry.dayKey, dist)
            }
        }
        return best?.key
    }

    private func detailLines(model: Model) -> (primary: String, secondary: String?) {
        guard let key = self.selectedDayKey,
              let entry = model.usageByDayKey[key],
              let date = Self.dateFromDayKey(key)
        else {
            return ("Hover a bar for details", nil)
        }

        let dayLabel = date.formatted(.dateTime.month(.abbreviated).day())
        let credits = entry.credit.formatted(.number.precision(.fractionLength(0...2)))
        return ("\(dayLabel): \(credits) credits", nil)
    }
}
