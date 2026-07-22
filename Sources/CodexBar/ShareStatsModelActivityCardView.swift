import AppKit
import SwiftUI

struct ShareStatsModelActivityCardView: View {
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
            Image(nsImage: ShareStatsBrand.appIcon)
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
            Text(self.tokenHeadline)
                .font(.system(size: 126, weight: .bold))
                .tracking(-7)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.72)
            Text(self.payload.tokenCoverageIsComplete ? "TOKENS" : "KNOWN TOKENS")
                .font(ShareStatsBrand.mono(size: 15, weight: .bold))
                .tracking(2)
                .foregroundStyle(ShareStatsBrand.secondary)
                .padding(.bottom, 11)
        }
        .frame(height: 106, alignment: .bottomLeading)
    }

    private var tokenHeadline: String {
        guard let totalTokens = self.payload.totalTokens else { return "—" }
        let value = ShareStatsFormatting.compactCount(totalTokens)
        return self.payload.tokenCoverageIsComplete ? value : "≥\(value)"
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
            let knownSpend = ShareStatsFormatting.currency(estimatedCost, code: currency.currencyCode)
            let isPartial = currency.pricedSourceCount < currency.sourceCount
                || currency.coveredDayCount < self.payload.days
            return isPartial ? "≥\(knownSpend)" : knownSpend
        }
        guard !pricedCurrencies.isEmpty else { return "—" }
        let shown = pricedCurrencies.prefix(2).joined(separator: " · ")
        if pricedCurrencies.count > 2 {
            return "\(shown) +\(pricedCurrencies.count - 2)"
        }
        return shown
    }

    private var spendDetail: String {
        guard self.pricedSourceCount > 0 else {
            return "estimated token spend unavailable · \(self.payload.providers.count) sources tracked"
        }
        let coverage = self.payload.currencies.contains {
            $0.estimatedCost != nil
                && ($0.pricedSourceCount < $0.sourceCount || $0.coveredDayCount < self.payload.days)
        } ? "known lower bound · " : ""
        return "estimated token spend · \(coverage)pricing for \(self.pricedSourceCount) "
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
                Text("MODEL ROUTES")
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
                        Text("via \(model.sourceName)")
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
        return "\(min(3, self.payload.topModels.count)) OF \(self.payload.topModels.count) ROUTES"
    }

    private var routeOverflowDetail: String {
        var details: [String] = []
        let overflowCount = max(0, self.payload.topModels.count - 3)
        if overflowCount > 0 {
            details.append("+\(overflowCount) more route\(overflowCount == 1 ? "" : "s")")
        }
        let collapsedCount = max(0, self.payload.shareableModelRouteCount - self.payload.topModels.count)
        if collapsedCount > 0 {
            details.append("\(collapsedCount) grouped")
        }
        if self.payload.hiddenModelRouteCount > 0 {
            details.append("\(self.payload.hiddenModelRouteCount) private")
        }
        if !self.payload.modelRouteCoverageIsComplete {
            details.append("partial history")
        }
        return details.isEmpty ? "All safe routes shown" : details.joined(separator: " · ")
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
                Text(self.activeDayHeadline)
                    .font(.system(size: 72, weight: .heavy))
                    .tracking(-4.5)
                    .monospacedDigit()
                    .foregroundStyle(ShareStatsBrand.activeGradient)
                if self.payload.dailySourceCount > 0 {
                    Text("of \(self.payload.days)")
                        .font(.system(size: 23, weight: .bold))
                        .foregroundStyle(ShareStatsBrand.secondary)
                        .padding(.bottom, 7)
                }
            }
            .frame(height: 72, alignment: .bottomLeading)
            .padding(.top, 18)

            Text(self.payload.dailySourceCount == 0 ? "daily activity unavailable" : self.activeDayLabel)
                .font(.system(size: 21, weight: .semibold))
                .padding(.top, 8)

            ShareStatsCalendar(
                cells: self.calendarCells,
                start: self.periodStart,
                end: self.periodEnd,
                isPartial: !self.payload.dailyCoverageIsComplete || self.payload.hasUnavailableDailyTotals)
                .frame(maxWidth: .infinity)
                .padding(.top, 24)

            Spacer(minLength: 10)

            HStack {
                Text(self.payload.dailyCoverageIsComplete ? "DAILY TOKEN ACTIVITY" : "KNOWN DAILY ACTIVITY")
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
        self.payload.dailyTokens.count { ($0.totalTokens ?? 0) > 0 }
    }

    private var activeDayHeadline: String {
        guard self.payload.dailySourceCount > 0 else { return "—" }
        let isLowerBound = !self.payload.dailyCoverageIsComplete || self.payload.hasUnavailableDailyTotals
        return isLowerBound ? "≥\(self.activeDayCount)" : "\(self.activeDayCount)"
    }

    private var activeDayLabel: String {
        !self.payload.dailyCoverageIsComplete || self.payload.hasUnavailableDailyTotals
            ? "known active days"
            : "days active"
    }

    private var sourceCoverage: String {
        guard self.payload.dailySourceCount > 0 else { return "NO SOURCE DATA" }
        if self.payload.dailyCoverageIsComplete {
            return "FULL · \(self.payload.dailySourceCount) OF \(self.payload.providers.count) SOURCES"
        }
        return "PARTIAL · \(self.payload.dailyFullSourceCount) OF \(self.payload.providers.count) FULL"
    }

    private var calendarCells: [ShareStatsCalendarCell] {
        var dailyTokens: [Date: ShareStatsDailyPayload] = [:]
        for point in self.payload.dailyTokens {
            dailyTokens[self.calendar.startOfDay(for: point.day)] = point
        }
        let maximum = dailyTokens.values.compactMap(\.totalTokens).max() ?? 0
        let leadingCount = max(0, self.calendar.component(.weekday, from: self.periodStart) - 1)
        let requiredCount = leadingCount + self.payload.days
        let totalCount = Int(ceil(Double(requiredCount) / 7.0)) * 7

        return (0..<totalCount).map { index in
            let dayOffset = index - leadingCount
            guard dayOffset >= 0,
                  dayOffset < self.payload.days,
                  let day = self.calendar.date(byAdding: .day, value: dayOffset, to: self.periodStart)
            else {
                return ShareStatsCalendarCell(id: index, level: nil, isUnavailable: false)
            }
            let normalizedDay = self.calendar.startOfDay(for: day)
            let tokens: Int? = if let recordedPoint = dailyTokens[normalizedDay] {
                recordedPoint.totalTokens
            } else {
                self.payload.dailyCoverageIsComplete ? 0 : nil
            }
            return ShareStatsCalendarCell(
                id: index,
                level: tokens.map { ShareStatsModelActivityCardView.activityLevel(totalTokens: $0, maximum: maximum) },
                isUnavailable: tokens == nil)
        }
    }
}

private struct ShareStatsCalendarCell: Identifiable {
    let id: Int
    let level: Int?
    let isUnavailable: Bool
}

private struct ShareStatsCalendar: View {
    let cells: [ShareStatsCalendarCell]
    let start: Date
    let end: Date
    let isPartial: Bool

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
                                    .fill(cell.isUnavailable
                                        ? Color.white.opacity(0.025)
                                        : ShareStatsBrand.activity(level: cell.level))
                                    .overlay {
                                        if cell.isUnavailable {
                                            RoundedRectangle(cornerRadius: 6)
                                                .stroke(Color.white.opacity(0.16), lineWidth: 1)
                                        } else if cell.level != nil {
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
                if self.isPartial {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.white.opacity(0.025))
                        .overlay {
                            RoundedRectangle(cornerRadius: 2)
                                .stroke(Color.white.opacity(0.16), lineWidth: 1)
                        }
                        .frame(width: 11, height: 11)
                    Text("Unknown")
                }
                Text("Less")
                ForEach(0...5, id: \.self) { level in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(ShareStatsBrand.activity(level: level))
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

@MainActor
private enum ShareStatsBrand {
    static let appIcon: NSImage = Bundle.module
        .url(forResource: "Icon-classic", withExtension: "icns")
        .flatMap(NSImage.init(contentsOf:))
        ?? NSApplication.shared.applicationIconImage

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
