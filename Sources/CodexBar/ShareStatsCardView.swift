import AppKit
import SwiftUI

struct ShareStatsCardView: View {
    static let size = CGSize(width: 1200, height: 630)

    let payload: ShareStatsPayload

    static func activityLevel(totalTokens: Int, maximum: Int) -> Int {
        guard totalTokens > 0, maximum > 0 else { return 0 }
        let scaled = Int(ceil(Double(totalTokens) / Double(maximum) * 5))
        return min(5, max(1, scaled))
    }

    var body: some View {
        ZStack {
            ShareStatsBrandBackground()
            HStack(spacing: 0) {
                ShareStatsStory(payload: self.payload)
                    .frame(width: 750)
                    .background(ShareStatsBrand.canvas.opacity(0.78))
                ShareStatsActivity(payload: self.payload)
                    .frame(width: 450)
                    .background(ShareStatsBrand.surface.opacity(0.82))
                    .overlay(alignment: .leading) {
                        Rectangle()
                            .fill(Color.white.opacity(0.12))
                            .frame(width: 1)
                    }
            }
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .clipped()
        .foregroundStyle(ShareStatsBrand.primary)
        .environment(\.colorScheme, .dark)
    }
}

private struct ShareStatsStory: View {
    let payload: ShareStatsPayload

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            self.header
            self.headline
                .padding(.top, 44)
            self.tokenHero
                .padding(.top, 26)
            self.spend
                .padding(.top, 29)
            self.routes
                .padding(.top, 32)
            Spacer(minLength: 8)
            Text("\(self.payload.days) DAYS · AGGREGATED LOCALLY · NO PROMPTS SHARED")
                .font(ShareStatsBrand.mono(size: 12, weight: .semibold))
                .tracking(0.4)
                .foregroundStyle(ShareStatsBrand.secondary)
        }
        .padding(.horizontal, 52)
        .padding(.top, 38)
        .padding(.bottom, 28)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 30, height: 30)
                .clipShape(RoundedRectangle(cornerRadius: 7))
                .overlay {
                    RoundedRectangle(cornerRadius: 7)
                        .stroke(Color.white.opacity(0.16), lineWidth: 1)
                }
            Text("CodexBar")
                .font(.system(size: 18, weight: .semibold))
                .tracking(-0.3)
        }
    }

    private var headline: some View {
        HStack(spacing: 0) {
            Text("You kept ")
            Text("the models")
                .foregroundStyle(ShareStatsBrand.aurora)
            Text(" busy.")
        }
        .font(.system(size: 43, weight: .semibold))
        .tracking(-1.8)
    }

    private var tokenHero: some View {
        HStack(alignment: .lastTextBaseline, spacing: 17) {
            Text(self.payload.totalTokens.map(ShareStatsFormatting.compactCount) ?? "—")
                .font(.system(size: 126, weight: .bold))
                .tracking(-7)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.72)
            Text("TOKENS")
                .font(ShareStatsBrand.mono(size: 15, weight: .bold))
                .tracking(2)
                .foregroundStyle(ShareStatsBrand.secondary)
                .padding(.bottom, 11)
        }
        .frame(height: 106, alignment: .bottomLeading)
    }

    private var spend: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(self.spendHeadline)
                .font(.system(size: 32, weight: .bold))
                .tracking(-1.3)
                .foregroundStyle(ShareStatsBrand.teal)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
            Text(self.spendDetail)
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(ShareStatsBrand.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
    }

    private var spendHeadline: String {
        let pricedCurrencies = self.payload.currencies.compactMap { currency -> String? in
            guard let estimatedCost = currency.estimatedCost else { return nil }
            return ShareStatsFormatting.currency(estimatedCost, code: currency.currencyCode)
        }
        guard !pricedCurrencies.isEmpty else { return "—" }
        let shown = pricedCurrencies.prefix(2).joined(separator: " · ")
        if pricedCurrencies.count > 2 {
            return "\(shown) +\(pricedCurrencies.count - 2)"
        }
        let isPartial = self.pricedSourceCount < self.payload.providers.count
        return pricedCurrencies.count == 1 && isPartial ? "\(shown)+" : shown
    }

    private var spendDetail: String {
        guard self.pricedSourceCount > 0 else {
            return "estimated token spend unavailable · \(self.payload.providers.count) sources tracked"
        }
        return "estimated token spend · pricing for \(self.pricedSourceCount) "
            + "of \(self.payload.providers.count) sources"
    }

    private var pricedSourceCount: Int {
        self.payload.providers.count { $0.estimatedCost != nil }
    }

    private var routes: some View {
        VStack(alignment: .leading, spacing: 0) {
            Rectangle()
                .fill(ShareStatsBrand.rule)
                .frame(height: 1)
            HStack(alignment: .firstTextBaseline) {
                Text("MODEL + SOURCE")
                Spacer()
                Text(self.routeHeaderDetail)
            }
            .font(ShareStatsBrand.mono(size: 13, weight: .bold))
            .tracking(0.8)
            .foregroundStyle(ShareStatsBrand.secondary)
            .padding(.top, 16)
            .padding(.bottom, 9)

            if self.payload.topModels.isEmpty {
                Text("Model breakdown unavailable")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(ShareStatsBrand.secondary)
                    .frame(height: 40)
            } else {
                ForEach(
                    Array(self.payload.topModels.prefix(3).enumerated()),
                    id: \.offset)
                { _, model in
                    HStack {
                        Text(model.modelName)
                            .font(.system(size: 20, weight: .semibold))
                            .tracking(-0.3)
                        Spacer()
                        Text(model.providerName)
                            .font(ShareStatsBrand.mono(size: 15, weight: .semibold))
                            .foregroundStyle(ShareStatsBrand.secondary)
                    }
                    .frame(height: 40)
                    .overlay(alignment: .bottom) {
                        Rectangle()
                            .fill(ShareStatsBrand.rule)
                            .frame(height: 1)
                    }
                }
            }

            HStack {
                Text(self.routeOverflowDetail)
                Spacer()
                Text("\(self.payload.providers.count) sources tracked")
            }
            .font(ShareStatsBrand.mono(size: 12, weight: .semibold))
            .foregroundStyle(ShareStatsBrand.secondary)
            .padding(.top, 9)
        }
    }

    private var routeHeaderDetail: String {
        guard !self.payload.topModels.isEmpty else { return "UNAVAILABLE" }
        return "TOP \(min(3, self.payload.topModels.count)) OF \(self.payload.topModels.count)"
    }

    private var routeOverflowDetail: String {
        let hiddenCount = max(0, self.payload.topModels.count - 3)
        return hiddenCount > 0 ? "+\(hiddenCount) more model / source pairs" : "All model / source pairs shown"
    }
}

private struct ShareStatsActivity: View {
    let payload: ShareStatsPayload

    private var calendar: Calendar {
        Calendar.current
    }

    private var periodEnd: Date {
        self.calendar.startOfDay(for: self.payload.periodEnd)
    }

    private var periodStart: Date {
        self.calendar.date(byAdding: .day, value: -(self.payload.days - 1), to: self.periodEnd)
            ?? self.periodEnd
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(
                "\(ShareStatsFormatting.shortRange(from: self.periodStart, through: self.periodEnd))"
                    + " · \(self.payload.days)-DAY SNAPSHOT")
                .font(ShareStatsBrand.mono(size: 13, weight: .bold))
                .tracking(1)
                .foregroundStyle(ShareStatsBrand.secondary)

            HStack(alignment: .lastTextBaseline, spacing: 9) {
                Text(self.payload.dailyTokens.isEmpty ? "—" : "\(self.activeDayCount)")
                    .font(.system(size: 72, weight: .heavy))
                    .tracking(-4.5)
                    .monospacedDigit()
                    .foregroundStyle(ShareStatsBrand.activeGradient)
                if !self.payload.dailyTokens.isEmpty {
                    Text("of \(self.payload.days)")
                        .font(.system(size: 23, weight: .bold))
                        .foregroundStyle(ShareStatsBrand.secondary)
                        .padding(.bottom, 7)
                }
            }
            .frame(height: 72, alignment: .bottomLeading)
            .padding(.top, 18)

            Text(self.payload.dailyTokens.isEmpty ? "daily activity unavailable" : "days active")
                .font(.system(size: 21, weight: .semibold))
                .padding(.top, 8)

            ShareStatsCalendar(
                cells: self.calendarCells,
                start: self.periodStart,
                end: self.periodEnd)
                .frame(maxWidth: .infinity)
                .padding(.top, 24)

            Spacer(minLength: 10)

            HStack {
                Text("DAILY TOKEN ACTIVITY")
                Spacer()
                Text(self.sourceCoverage)
            }
            .font(ShareStatsBrand.mono(size: 12, weight: .bold))
            .tracking(0.35)
            .foregroundStyle(ShareStatsBrand.secondary)
        }
        .padding(.horizontal, 38)
        .padding(.top, 38)
        .padding(.bottom, 29)
    }

    private var activeDayCount: Int {
        self.payload.dailyTokens.count { $0.totalTokens > 0 }
    }

    private var sourceCoverage: String {
        guard self.payload.dailySourceCount > 0 else { return "NO SOURCE DATA" }
        return "\(self.payload.dailySourceCount) OF \(self.payload.providers.count) SOURCES"
    }

    private var calendarCells: [ShareStatsCalendarCell] {
        let dailyTokens = Dictionary(uniqueKeysWithValues: self.payload.dailyTokens.map {
            (self.calendar.startOfDay(for: $0.day), $0.totalTokens)
        })
        let maximum = dailyTokens.values.max() ?? 0
        let leadingCount = max(0, self.calendar.component(.weekday, from: self.periodStart) - 1)
        let requiredCount = leadingCount + self.payload.days
        let totalCount = Int(ceil(Double(requiredCount) / 7.0)) * 7

        return (0..<totalCount).map { index in
            let dayOffset = index - leadingCount
            guard dayOffset >= 0,
                  dayOffset < self.payload.days,
                  let day = self.calendar.date(byAdding: .day, value: dayOffset, to: self.periodStart)
            else {
                return ShareStatsCalendarCell(id: index, level: nil)
            }
            let tokens = dailyTokens[self.calendar.startOfDay(for: day)] ?? 0
            return ShareStatsCalendarCell(
                id: index,
                level: ShareStatsCardView.activityLevel(totalTokens: tokens, maximum: maximum))
        }
    }
}

private struct ShareStatsCalendarCell: Identifiable {
    let id: Int
    let level: Int?
}

private struct ShareStatsCalendar: View {
    let cells: [ShareStatsCalendarCell]
    let start: Date
    let end: Date

    private var weeks: [[ShareStatsCalendarCell]] {
        stride(from: 0, to: self.cells.count, by: 7).map { startIndex in
            Array(self.cells[startIndex..<min(startIndex + 7, self.cells.count)])
        }
    }

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            HStack(alignment: .top, spacing: 9) {
                VStack(spacing: 8) {
                    ForEach(0..<7, id: \.self) { weekdayIndex in
                        Text(self.weekdayLabel(for: weekdayIndex))
                            .font(ShareStatsBrand.mono(size: 12, weight: .bold))
                            .foregroundStyle(ShareStatsBrand.secondary)
                            .frame(width: 29, height: 42, alignment: .trailing)
                    }
                }
                HStack(spacing: 8) {
                    ForEach(Array(self.weeks.enumerated()), id: \.offset) { _, week in
                        VStack(spacing: 8) {
                            ForEach(week) { cell in
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(ShareStatsBrand.activity(level: cell.level))
                                    .overlay {
                                        if cell.level != nil {
                                            RoundedRectangle(cornerRadius: 6)
                                                .stroke(Color.white.opacity(0.10), lineWidth: 1)
                                        }
                                    }
                                    .frame(width: 42, height: 42)
                            }
                        }
                    }
                }
            }

            HStack {
                Text(ShareStatsFormatting.shortDay(self.start))
                Spacer()
                Text(ShareStatsFormatting.shortDay(self.midpoint))
                Spacer()
                Text(ShareStatsFormatting.shortDay(self.end))
            }
            .font(ShareStatsBrand.mono(size: 12, weight: .bold))
            .foregroundStyle(ShareStatsBrand.secondary)
            .frame(width: self.gridWidth)

            HStack(spacing: 4) {
                Text("Less")
                ForEach(0..<4, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(ShareStatsBrand.activity(level: index == 0 ? 0 : index + 1))
                        .overlay {
                            RoundedRectangle(cornerRadius: 2)
                                .stroke(Color.white.opacity(0.10), lineWidth: 1)
                        }
                        .frame(width: 11, height: 11)
                }
                Text("More")
            }
            .font(ShareStatsBrand.mono(size: 11, weight: .bold))
            .foregroundStyle(ShareStatsBrand.secondary)
            .frame(width: self.gridWidth, alignment: .trailing)
        }
    }

    private var gridWidth: CGFloat {
        CGFloat(self.weeks.count) * 42 + CGFloat(max(0, self.weeks.count - 1)) * 8
    }

    private var midpoint: Date {
        Calendar.current.date(
            byAdding: .day,
            value: Calendar.current.dateComponents([.day], from: self.start, to: self.end).day.map { $0 / 2 } ?? 0,
            to: self.start) ?? self.start
    }

    private func weekdayLabel(for index: Int) -> String {
        switch index {
        case 1: "Mon"
        case 3: "Wed"
        case 5: "Fri"
        default: ""
        }
    }
}

private struct ShareStatsBrandBackground: View {
    var body: some View {
        ZStack {
            ShareStatsBrand.canvas
            RadialGradient(
                colors: [ShareStatsBrand.orange.opacity(0.42), .clear],
                center: .topLeading,
                startRadius: 0,
                endRadius: 460)
            RadialGradient(
                colors: [ShareStatsBrand.violet.opacity(0.46), .clear],
                center: .topTrailing,
                startRadius: 0,
                endRadius: 480)
            RadialGradient(
                colors: [ShareStatsBrand.teal.opacity(0.22), .clear],
                center: .bottom,
                startRadius: 0,
                endRadius: 420)
            RadialGradient(
                colors: [ShareStatsBrand.pink.opacity(0.28), .clear],
                center: .bottomTrailing,
                startRadius: 0,
                endRadius: 360)
        }
    }
}

private enum ShareStatsBrand {
    static let canvas = Color(red: 10.0 / 255.0, green: 10.0 / 255.0, blue: 12.0 / 255.0)
    static let surface = Color(red: 19.0 / 255.0, green: 20.0 / 255.0, blue: 24.0 / 255.0)
    static let primary = Color(red: 240.0 / 255.0, green: 240.0 / 255.0, blue: 243.0 / 255.0)
    static let secondary = Color(red: 182.0 / 255.0, green: 189.0 / 255.0, blue: 198.0 / 255.0)
    static let orange = Color(red: 255.0 / 255.0, green: 122.0 / 255.0, blue: 26.0 / 255.0)
    static let pink = Color(red: 255.0 / 255.0, green: 61.0 / 255.0, blue: 139.0 / 255.0)
    static let violet = Color(red: 110.0 / 255.0, green: 90.0 / 255.0, blue: 255.0 / 255.0)
    static let teal = Color(red: 22.0 / 255.0, green: 211.0 / 255.0, blue: 180.0 / 255.0)
    static let rule = Color.white.opacity(0.18)

    static let aurora = LinearGradient(
        colors: [ShareStatsBrand.orange, ShareStatsBrand.pink, ShareStatsBrand.violet, ShareStatsBrand.teal],
        startPoint: .leading,
        endPoint: .trailing)

    static let activeGradient = LinearGradient(
        colors: [ShareStatsBrand.orange, ShareStatsBrand.pink],
        startPoint: .topLeading,
        endPoint: .bottomTrailing)

    static func mono(size: CGFloat, weight: Font.Weight) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }

    static func activity(level: Int?) -> Color {
        guard let level else { return .clear }
        switch level {
        case 1: return self.teal.opacity(0.18)
        case 2: return self.teal.opacity(0.34)
        case 3: return self.teal.opacity(0.52)
        case 4: return self.teal.opacity(0.74)
        case 5: return self.teal.opacity(0.98)
        default: return Color.white.opacity(0.055)
        }
    }
}
