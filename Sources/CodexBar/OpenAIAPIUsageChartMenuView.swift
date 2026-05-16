import Charts
import CodexBarCore
import SwiftUI

@MainActor
struct OpenAIAPIUsageChartMenuView: View {
    private let snapshot: OpenAIAPIUsageSnapshot
    private let width: CGFloat
    @State private var selectedDay: String?

    init(snapshot: OpenAIAPIUsageSnapshot, width: CGFloat) {
        self.snapshot = snapshot
        self.width = width
    }

    var body: some View {
        let model = Self.makeModel(snapshot: self.snapshot)
        VStack(alignment: .leading, spacing: 10) {
            if model.points.isEmpty {
                Text("No OpenAI API usage data.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 88), alignment: .leading)],
                    alignment: .leading,
                    spacing: 6)
                {
                    StatPill(title: "30d spend", value: UsageFormatter.usdString(model.last30.costUSD))
                    StatPill(title: "30d tokens", value: UsageFormatter.tokenCountString(model.last30.totalTokens))
                    StatPill(title: "30d requests", value: UsageFormatter.tokenCountString(model.last30.requests))
                }

                Chart {
                    ForEach(model.points) { point in
                        BarMark(
                            x: .value("Day", point.date, unit: .day),
                            y: .value("Spend", point.costUSD))
                            .foregroundStyle(Self.spendColor)
                            .cornerRadius(2)
                    }
                    if let peak = model.peakSpendPoint {
                        PointMark(
                            x: .value("Peak spend day", peak.date, unit: .day),
                            y: .value("Spend", peak.costUSD))
                            .symbolSize(30)
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
                .frame(height: 106)
                .accessibilityLabel("OpenAI API spend chart")
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

                Chart {
                    ForEach(model.points) { point in
                        AreaMark(
                            x: .value("Day", point.date, unit: .day),
                            y: .value("Tokens", point.totalTokens))
                            .interpolationMethod(.catmullRom)
                            .foregroundStyle(Self.tokenColor.opacity(0.22))
                        LineMark(
                            x: .value("Day", point.date, unit: .day),
                            y: .value("Tokens", point.totalTokens))
                            .interpolationMethod(.catmullRom)
                            .foregroundStyle(Self.tokenColor)
                        BarMark(
                            x: .value("Day", point.date, unit: .day),
                            y: .value("Requests", point.requests))
                            .foregroundStyle(Self.requestColor.opacity(0.32))
                    }
                }
                .chartYAxis(.hidden)
                .chartXAxis(.hidden)
                .frame(height: 74)
                .accessibilityLabel("OpenAI API token and request chart")

                let detail = self.detail(model: model)
                VStack(alignment: .leading, spacing: 3) {
                    Text(detail.primary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if let secondary = detail.secondary {
                        Text(secondary)
                            .font(.caption2)
                            .foregroundStyle(Color(nsColor: .tertiaryLabelColor))
                            .lineLimit(1)
                    }
                }

                LegendRow(items: [
                    (Self.spendColor, "Spend"),
                    (Self.tokenColor, "Tokens"),
                    (Self.requestColor, "Requests"),
                ])
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(minWidth: self.width, maxWidth: .infinity, alignment: .leading)
    }

    private struct Point: Identifiable {
        let id: String
        let day: String
        let date: Date
        let costUSD: Double
        let requests: Int
        let totalTokens: Int
    }

    private struct Model {
        let points: [Point]
        let pointsByDay: [String: Point]
        let dayDates: [(day: String, date: Date)]
        let axisDates: [Date]
        let peakSpendPoint: Point?
        let last30: OpenAIAPIUsageSnapshot.Summary
    }

    private static let spendColor = Color(red: 0.81, green: 0.56, blue: 0.24)
    private static let tokenColor = Color(red: 0.48, green: 0.41, blue: 0.86)
    private static let requestColor = Color(red: 0.43, green: 0.73, blue: 0.62)
    private static let selectionBandColor = Color(nsColor: .labelColor).opacity(0.1)

    private static func makeModel(snapshot: OpenAIAPIUsageSnapshot) -> Model {
        let points = snapshot.daily.compactMap { day -> Point? in
            guard let date = Self.dateFromDayKey(day.day) else { return nil }
            return Point(
                id: day.day,
                day: day.day,
                date: date,
                costUSD: day.costUSD,
                requests: day.requests,
                totalTokens: day.totalTokens)
        }
        let pointsByDay = Dictionary(uniqueKeysWithValues: points.map { ($0.day, $0) })
        let dayDates = points.map { ($0.day, $0.date) }
        let axisDates: [Date] = {
            guard let first = points.first?.date, let last = points.last?.date else { return [] }
            if Calendar.current.isDate(first, inSameDayAs: last) { return [first] }
            return [first, last]
        }()
        let peak = points.max { lhs, rhs in
            if lhs.costUSD == rhs.costUSD { return lhs.totalTokens < rhs.totalTokens }
            return lhs.costUSD < rhs.costUSD
        }
        return Model(
            points: points,
            pointsByDay: pointsByDay,
            dayDates: dayDates,
            axisDates: axisDates,
            peakSpendPoint: (peak?.costUSD ?? 0) > 0 ? peak : nil,
            last30: snapshot.last30Days)
    }

    private func detail(model: Model) -> (primary: String, secondary: String?) {
        let point = self.selectedDay.flatMap { model.pointsByDay[$0] } ?? model.points.last
        guard let point else { return ("No selected day", nil) }
        let primary = "\(Self.displayDate(point.date)): \(UsageFormatter.usdString(point.costUSD)) · " +
            "\(UsageFormatter.tokenCountString(point.totalTokens)) tokens · " +
            "\(UsageFormatter.tokenCountString(point.requests)) requests"
        let bucket = self.snapshot.daily.first { $0.day == point.day }
        let topModel = bucket?.models.first?.name
        let topLineItem = bucket?.lineItems.first?.name
        let secondary = [topModel.map { "Top model: \($0)" }, topLineItem.map { "Top spend: \($0)" }]
            .compactMap(\.self)
            .joined(separator: " · ")
        return (primary, secondary.isEmpty ? nil : secondary)
    }

    private func updateSelection(location: CGPoint?, model: Model, proxy: ChartProxy, geo: GeometryProxy) {
        guard let location else {
            if self.selectedDay != nil { self.selectedDay = nil }
            return
        }
        guard !model.dayDates.isEmpty else { return }
        guard let plotFrame = proxy.plotFrame else { return }
        let frame = geo[plotFrame]
        guard frame.contains(location) else { return }
        let x = location.x - frame.origin.x
        guard let date: Date = proxy.value(atX: x) else { return }
        self.selectedDay = Self.nearestDay(to: date, in: model.dayDates)
    }

    private func selectionBandRect(model: Model, proxy: ChartProxy, geo: GeometryProxy) -> CGRect? {
        guard let selectedDay, let selected = model.dayDates.first(where: { $0.day == selectedDay }) else {
            return nil
        }
        guard let plotFrame = proxy.plotFrame else { return nil }
        let frame = geo[plotFrame]
        guard let x = proxy.position(forX: selected.date) else { return nil }
        let width = max(5, frame.width / CGFloat(max(model.dayDates.count, 1)))
        return CGRect(
            x: frame.origin.x + x - width / 2,
            y: frame.origin.y,
            width: width,
            height: frame.height)
    }

    private static func nearestDay(to date: Date, in days: [(day: String, date: Date)]) -> String? {
        days.min {
            abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date))
        }?.day
    }

    private static func dateFromDayKey(_ key: String) -> Date? {
        let parts = key.split(separator: "-")
        guard parts.count == 3,
              let year = Int(parts[0]),
              let month = Int(parts[1]),
              let day = Int(parts[2])
        else { return nil }
        var comps = DateComponents()
        comps.calendar = Calendar.current
        comps.timeZone = TimeZone.current
        comps.year = year
        comps.month = month
        comps.day = day
        comps.hour = 12
        return comps.date
    }

    private static func displayDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMM d"
        return formatter.string(from: date)
    }
}

private struct StatPill: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(self.title)
                .font(.caption2)
                .foregroundStyle(Color(nsColor: .tertiaryLabelColor))
                .lineLimit(1)
            Text(self.value)
                .font(.caption)
                .fontWeight(.semibold)
                .lineLimit(1)
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 7)
        .background(Color(nsColor: .separatorColor).opacity(0.35), in: RoundedRectangle(cornerRadius: 6))
    }
}

private struct LegendRow: View {
    let items: [(Color, String)]

    var body: some View {
        HStack(spacing: 10) {
            ForEach(self.items, id: \.1) { item in
                HStack(spacing: 5) {
                    Circle()
                        .fill(item.0)
                        .frame(width: 7, height: 7)
                    Text(item.1)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
    }
}
