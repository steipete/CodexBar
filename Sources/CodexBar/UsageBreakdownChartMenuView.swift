import Charts
import CodexBarCore
import SwiftUI

@MainActor
struct UsageBreakdownChartMenuView: View {
    private struct Point: Identifiable {
        let id: String
        let date: Date
        let service: String
        let creditsUsed: Double

        init(date: Date, service: String, creditsUsed: Double) {
            self.date = date
            self.service = service
            self.creditsUsed = creditsUsed
            self.id = "\(service)-\(Int(date.timeIntervalSince1970))- \(creditsUsed)"
        }
    }

    private let breakdown: [OpenAIDashboardDailyBreakdown]
    private let width: CGFloat
    @State private var selectedDayKey: String?

    init(breakdown: [OpenAIDashboardDailyBreakdown], width: CGFloat) {
        self.breakdown = breakdown
        self.width = width
    }

    var body: some View {
        let model = Self.makeModel(from: self.breakdown)
        VStack(alignment: .leading, spacing: 10) {
            if model.points.isEmpty {
                Text("No usage breakdown data.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                Chart {
                    ForEach(model.points) { point in
                        BarMark(
                            x: .value("Day", point.date, unit: .day),
                            y: .value("Credits used", point.creditsUsed))
                            .foregroundStyle(by: .value("Service", point.service))
                    }
                    if let peak = model.peakPoint {
                        let capStart = max(peak.creditsUsed - Self.capHeight(maxValue: model.maxCreditsUsed), 0)
                        BarMark(
                            x: .value("Day", peak.date, unit: .day),
                            yStart: .value("Cap start", capStart),
                            yEnd: .value("Cap end", peak.creditsUsed))
                            .foregroundStyle(Color(nsColor: .systemYellow))
                    }
                }
                .chartForegroundStyleScale(domain: model.services, range: model.serviceColors)
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

                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 110), alignment: .leading)],
                    alignment: .leading,
                    spacing: 6)
                {
                    ForEach(model.services, id: \.self) { service in
                        HStack(spacing: 6) {
                            Circle()
                                .fill(model.color(for: service))
                                .frame(width: 7, height: 7)
                            Text(service)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(minWidth: self.width, maxWidth: .infinity, alignment: .leading)
    }

    private struct Model {
        let points: [Point]
        let breakdownByDayKey: [String: OpenAIDashboardDailyBreakdown]
        let dayDates: [(dayKey: String, date: Date)]
        let selectableDayDates: [(dayKey: String, date: Date)]
        let peakPoint: (date: Date, creditsUsed: Double)?
        let services: [String]
        let serviceColors: [Color]
        let axisDates: [Date]
        let maxCreditsUsed: Double

        func color(for service: String) -> Color {
            guard let idx = self.services.firstIndex(of: service), idx < self.serviceColors.count else {
                return .secondary
            }
            return self.serviceColors[idx]
        }
    }

    private static let selectionBandColor = Color(nsColor: .labelColor).opacity(0.1)

    private static func makeModel(from breakdown: [OpenAIDashboardDailyBreakdown]) -> Model {
        let sorted = breakdown
            .sorted { lhs, rhs in lhs.day < rhs.day }

        var points: [Point] = []
        points.reserveCapacity(sorted.count * 2)

        var breakdownByDayKey: [String: OpenAIDashboardDailyBreakdown] = [:]
        breakdownByDayKey.reserveCapacity(sorted.count)

        var dayDates: [(dayKey: String, date: Date)] = []
        dayDates.reserveCapacity(sorted.count)

        var selectableDayDates: [(dayKey: String, date: Date)] = []
        selectableDayDates.reserveCapacity(sorted.count)

        var peak: (date: Date, creditsUsed: Double)?
        var maxCreditsUsed: Double = 0

        for day in sorted {
            guard let date = self.dateFromDayKey(day.day) else { continue }
            breakdownByDayKey[day.day] = day
            dayDates.append((dayKey: day.day, date: date))
            if day.totalCreditsUsed > 0 {
                if let cur = peak {
                    if day.totalCreditsUsed > cur.creditsUsed { peak = (date, day.totalCreditsUsed) }
                } else {
                    peak = (date, day.totalCreditsUsed)
                }
                maxCreditsUsed = max(maxCreditsUsed, day.totalCreditsUsed)
            }
            var addedSelectable = false
            for service in day.services where service.creditsUsed > 0 {
                points.append(Point(date: date, service: service.service, creditsUsed: service.creditsUsed))
                if !addedSelectable {
                    selectableDayDates.append((dayKey: day.day, date: date))
                    addedSelectable = true
                }
            }
        }

        let services = Self.serviceOrder(from: sorted)
        let colors = services.map { Self.colorForService($0) }
        let axisDates = Self.axisDates(fromSortedDays: sorted)

        return Model(
            points: points,
            breakdownByDayKey: breakdownByDayKey,
            dayDates: dayDates,
            selectableDayDates: selectableDayDates,
            peakPoint: peak,
            services: services,
            serviceColors: colors,
            axisDates: axisDates,
            maxCreditsUsed: maxCreditsUsed)
    }

    private static func capHeight(maxValue: Double) -> Double {
        maxValue * 0.05
    }

    private static func serviceOrder(from breakdown: [OpenAIDashboardDailyBreakdown]) -> [String] {
        var totals: [String: Double] = [:]
        for day in breakdown {
            for service in day.services {
                totals[service.service, default: 0] += service.creditsUsed
            }
        }

        return totals
            .sorted { lhs, rhs in
                if lhs.value == rhs.value { return lhs.key < rhs.key }
                return lhs.value > rhs.value
            }
            .map(\.key)
    }

    private static func colorForService(_ service: String) -> Color {
        let lower = service.lowercased()
        if lower == "cli" {
            return Color(red: 0.26, green: 0.55, blue: 0.96)
        }
        if lower.contains("github"), lower.contains("review") {
            return Color(red: 0.94, green: 0.53, blue: 0.18)
        }
        let palette: [Color] = [
            Color(red: 0.46, green: 0.75, blue: 0.36),
            Color(red: 0.80, green: 0.45, blue: 0.92),
            Color(red: 0.26, green: 0.78, blue: 0.86),
            Color(red: 0.94, green: 0.74, blue: 0.26),
        ]
        let idx = abs(service.hashValue) % palette.count
        return palette[idx]
    }

    private static func axisDates(fromSortedDays sortedDays: [OpenAIDashboardDailyBreakdown]) -> [Date] {
        guard let first = sortedDays.first, let last = sortedDays.last else { return [] }
        guard let firstDate = self.dateFromDayKey(first.day),
              let lastDate = self.dateFromDayKey(last.day)
        else {
            return []
        }
        if Calendar.current.isDate(firstDate, inSameDayAs: lastDate) {
            return [firstDate]
        }
        return [firstDate, lastDate]
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
        // Noon avoids off-by-one-day shifts if anything ends up interpreted in UTC.
        comps.hour = 12
        return comps.date
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
              let day = model.breakdownByDayKey[key],
              let date = Self.dateFromDayKey(key)
        else {
            return ("Hover a bar for details", nil)
        }

        let dayLabel = date.formatted(.dateTime.month(.abbreviated).day())
        let total = day.totalCreditsUsed.formatted(.number.precision(.fractionLength(0...2)))
        if day.services.isEmpty {
            return ("\(dayLabel): \(total)", nil)
        }
        if day.services.count <= 1, let first = day.services.first {
            let used = first.creditsUsed.formatted(.number.precision(.fractionLength(0...2)))
            return ("\(dayLabel): \(used)", first.service)
        }

        let services = day.services
            .sorted { lhs, rhs in
                if lhs.creditsUsed == rhs.creditsUsed { return lhs.service < rhs.service }
                return lhs.creditsUsed > rhs.creditsUsed
            }
            .prefix(3)
            .map { "\($0.service) \($0.creditsUsed.formatted(.number.precision(.fractionLength(0...2))))" }
            .joined(separator: " · ")

        return ("\(dayLabel): \(total)", services)
    }
}
