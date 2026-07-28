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

    static func weekCount(for dayCount: Int) -> Int {
        guard dayCount > 0 else { return 0 }
        return Int(ceil(Double(dayCount) / 7.0))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ShareStatsActivityHeader(payload: self.payload)
            ShareStatsActivityMetrics(payload: self.payload)
                .padding(.top, 24)
            Rectangle()
                .fill(ShareStatsActivityBrand.rule)
                .frame(height: 1)
                .padding(.top, 22)
            ShareStatsRoutes(payload: self.payload)
                .padding(.top, 20)
            ShareStatsWeekActivity(payload: self.payload)
                .padding(.top, 22)
            Spacer(minLength: 18)
            ShareStatsActivityFooter(payload: self.payload)
        }
        .padding(.horizontal, 44)
        .padding(.top, 32)
        .padding(.bottom, 27)
        .frame(width: Self.size.width, height: Self.size.height, alignment: .topLeading)
        .background(ShareStatsActivityBackground())
        .foregroundStyle(ShareStatsActivityBrand.primary)
        .environment(\.colorScheme, .dark)
    }
}

private struct ShareStatsActivityHeader: View {
    let payload: ShareStatsPayload

    private var calendar: Calendar {
        Calendar.current
    }

    private var periodStart: Date {
        self.calendar.date(
            byAdding: .day,
            value: -(self.payload.days - 1),
            to: self.calendar.startOfDay(for: self.payload.periodEnd)) ?? self.payload.periodEnd
    }

    var body: some View {
        HStack(alignment: .center, spacing: 13) {
            Image(nsImage: ShareStatsActivityBrand.appIcon)
                .resizable()
                .interpolation(.high)
                .frame(width: 30, height: 30)
                .clipShape(RoundedRectangle(cornerRadius: 7))
                .overlay {
                    RoundedRectangle(cornerRadius: 7)
                        .stroke(Color.white.opacity(0.14), lineWidth: 1)
                }
            Text("CodexBar")
                .font(.system(size: 21, weight: .semibold))
                .tracking(-0.35)
            Rectangle()
                .fill(ShareStatsActivityBrand.rule)
                .frame(width: 1, height: 24)
                .padding(.horizontal, 2)
            Text("MODEL ACTIVITY")
                .font(ShareStatsActivityBrand.mono(size: 13, weight: .bold))
                .tracking(1.25)
                .foregroundStyle(ShareStatsActivityBrand.secondary)
            Spacer()
            Text(
                "\(ShareStatsFormatting.shortRange(from: self.periodStart, through: self.payload.periodEnd))"
                    + " · \(self.payload.days) DAYS")
                .font(ShareStatsActivityBrand.mono(size: 13, weight: .bold))
                .tracking(0.45)
                .foregroundStyle(ShareStatsActivityBrand.secondary)
        }
        .frame(height: 30)
    }
}

private struct ShareStatsActivityMetrics: View {
    let payload: ShareStatsPayload

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            self.metric(
                value: self.tokenHeadline,
                label: self.payload.tokenCoverageIsComplete ? "TRACKED TOKENS" : "KNOWN TOKENS",
                detail: self.tokenDetail,
                color: ShareStatsActivityBrand.primary)
                .frame(width: 388, alignment: .leading)
            self.separator
            self.metric(
                value: self.spendHeadline,
                label: "ESTIMATED TOKEN SPEND",
                detail: self.spendDetail,
                color: ShareStatsActivityBrand.coral)
                .frame(width: 385, alignment: .leading)
                .padding(.leading, 28)
            self.separator
            self.metric(
                value: self.activeDayHeadline,
                label: self.activeDayLabel,
                detail: self.activityDetail,
                color: ShareStatsActivityBrand.teal)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 28)
        }
        .frame(height: 104, alignment: .top)
    }

    private func metric(value: String, label: String, detail: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.system(size: 47, weight: .semibold))
                .tracking(-2.0)
                .monospacedDigit()
                .foregroundStyle(color)
                .lineLimit(1)
                .minimumScaleFactor(0.62)
            Text(label)
                .font(ShareStatsActivityBrand.mono(size: 12, weight: .bold))
                .tracking(0.75)
                .foregroundStyle(ShareStatsActivityBrand.secondary)
            Text(detail)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(ShareStatsActivityBrand.tertiary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
    }

    private var separator: some View {
        Rectangle()
            .fill(ShareStatsActivityBrand.rule)
            .frame(width: 1, height: 95)
    }

    private var tokenHeadline: String {
        guard let totalTokens = self.payload.totalTokens else { return "—" }
        let value = ShareStatsFormatting.compactCount(totalTokens)
        return self.payload.tokenCoverageIsComplete ? value : "≥\(value)"
    }

    private var tokenDetail: String {
        "\(self.payload.tokenSourceCount) of \(self.payload.providers.count) sources reported totals"
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
        return pricedCurrencies.count > 2 ? "\(shown) +\(pricedCurrencies.count - 2)" : shown
    }

    private var spendDetail: String {
        let pricedSourceCount = self.payload.providers.count { $0.estimatedCost != nil }
        guard pricedSourceCount > 0 else { return "Pricing unavailable for tracked routes" }
        let isPartial = self.payload.currencies.contains {
            $0.estimatedCost != nil
                && ($0.pricedSourceCount < $0.sourceCount || $0.coveredDayCount < self.payload.days)
        }
        let coverage = isPartial ? "Known lower bound · " : ""
        return "\(coverage)\(pricedSourceCount) of \(self.payload.providers.count) sources priced"
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
        let qualifier = !self.payload.dailyCoverageIsComplete || self.payload.hasUnavailableDailyTotals
            ? "KNOWN ACTIVE DAYS"
            : "DAYS ACTIVE"
        return "\(qualifier) · OF \(self.payload.days)"
    }

    private var activityDetail: String {
        guard self.payload.dailySourceCount > 0 else { return "Daily activity unavailable" }
        if self.payload.dailyCoverageIsComplete {
            return "\(self.payload.dailySourceCount) of \(self.payload.providers.count) sources with full history"
        }
        return "\(self.payload.dailyFullSourceCount) of \(self.payload.providers.count) sources with full history"
    }
}

private struct ShareStatsRoutes: View {
    let payload: ShareStatsPayload

    private var visibleModels: [ShareStatsModelPayload] {
        Array(self.payload.topModels.prefix(3))
    }

    private var maximumTokens: Int {
        self.visibleModels.compactMap(\.totalTokens).max() ?? 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("TOP MODEL ROUTES")
                Spacer()
                Text(self.routeHeaderDetail)
            }
            .font(ShareStatsActivityBrand.mono(size: 12, weight: .bold))
            .tracking(0.75)
            .foregroundStyle(ShareStatsActivityBrand.secondary)
            .padding(.bottom, 10)

            if self.visibleModels.isEmpty {
                Text("Model breakdown unavailable for this local snapshot")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(ShareStatsActivityBrand.secondary)
                    .frame(height: 120, alignment: .leading)
            } else {
                ForEach(Array(self.visibleModels.enumerated()), id: \.offset) { index, model in
                    ShareStatsRouteRow(
                        model: model,
                        maximumTokens: self.maximumTokens,
                        color: ShareStatsActivityBrand.routeColor(at: index))
                }
            }

            HStack(spacing: 8) {
                Text(self.routeOverflowDetail)
                Spacer()
                Text(
                    "\(self.payload.trackedSourceCount) tracked · "
                        + "\(self.payload.providers.count) with cost history")
            }
            .font(ShareStatsActivityBrand.mono(size: 11, weight: .semibold))
            .foregroundStyle(ShareStatsActivityBrand.tertiary)
            .padding(.top, 8)
        }
    }

    private var routeHeaderDetail: String {
        guard !self.payload.topModels.isEmpty else { return "UNAVAILABLE" }
        return "\(self.visibleModels.count) OF \(self.payload.topModels.count) SHAREABLE ROUTES"
    }

    private var routeOverflowDetail: String {
        var details: [String] = []
        let overflowCount = max(0, self.payload.topModels.count - self.visibleModels.count)
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

private struct ShareStatsRouteRow: View {
    let model: ShareStatsModelPayload
    let maximumTokens: Int
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Circle()
                    .fill(self.color)
                    .frame(width: 8, height: 8)
                Text(self.model.modelName)
                    .font(.system(size: 18, weight: .semibold))
                    .tracking(-0.25)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Text("via \(self.model.sourceName)")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(ShareStatsActivityBrand.secondary)
                    .lineLimit(1)
                Spacer(minLength: 12)
                Text(self.detail)
                    .font(ShareStatsActivityBrand.mono(size: 13, weight: .bold))
                    .foregroundStyle(ShareStatsActivityBrand.secondary)
                    .lineLimit(1)
            }
            GeometryReader { proxy in
                Capsule()
                    .fill(Color.white.opacity(0.065))
                    .overlay(alignment: .leading) {
                        if let totalTokens = self.model.totalTokens, self.maximumTokens > 0 {
                            Capsule()
                                .fill(self.color.opacity(0.9))
                                .frame(
                                    width: max(
                                        4,
                                        proxy.size.width * CGFloat(totalTokens) / CGFloat(self.maximumTokens)))
                        }
                    }
            }
            .frame(height: 4)
        }
        .frame(height: 49)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(ShareStatsActivityBrand.rule.opacity(0.65))
                .frame(height: 1)
        }
    }

    private var detail: String {
        if let totalTokens = self.model.totalTokens {
            return "\(ShareStatsFormatting.compactCount(totalTokens)) TOKENS"
        }
        if let estimatedCost = self.model.estimatedCost, estimatedCost.isFinite {
            return "~\(ShareStatsFormatting.currency(estimatedCost, code: self.model.currencyCode))"
        }
        return "USED"
    }
}

private struct ShareStatsWeekActivity: View {
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

    private var cells: [ShareStatsWeekCell] {
        var points: [Date: Int?] = [:]
        for point in self.payload.dailyTokens {
            points[self.calendar.startOfDay(for: point.day)] = point.totalTokens
        }

        let weekCount = ShareStatsModelActivityCardView.weekCount(for: self.payload.days)
        let totals = (0..<weekCount).map { weekIndex -> (total: Int?, isPartial: Bool) in
            let firstOffset = weekIndex * 7
            let lastOffset = min(self.payload.days, firstOffset + 7)
            var knownTotal = 0
            var hasKnownValue = false
            var isPartial = false
            var overflowed = false

            for dayOffset in firstOffset..<lastOffset {
                guard let day = self.calendar.date(byAdding: .day, value: dayOffset, to: self.periodStart)
                else {
                    isPartial = true
                    continue
                }
                let value: Int? = if let recorded = points[self.calendar.startOfDay(for: day)] {
                    recorded
                } else {
                    self.payload.dailyCoverageIsComplete ? 0 : nil
                }
                guard let value else {
                    isPartial = true
                    continue
                }
                hasKnownValue = true
                let result = knownTotal.addingReportingOverflow(value)
                knownTotal = result.partialValue
                overflowed = overflowed || result.overflow
            }
            return (hasKnownValue && !overflowed ? knownTotal : nil, isPartial || overflowed)
        }
        let maximum = totals.compactMap(\.total).max() ?? 0
        return totals.enumerated().map { index, week in
            ShareStatsWeekCell(
                id: index,
                level: week.total.map {
                    ShareStatsModelActivityCardView.activityLevel(totalTokens: $0, maximum: maximum)
                },
                isPartial: week.isPartial)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("\(self.cells.count)-WEEK ACTIVITY")
                Spacer()
                if !self.payload.dailyCoverageIsComplete || self.payload.hasUnavailableDailyTotals {
                    Text("OUTLINED WEEKS INCLUDE UNKNOWN DAYS")
                } else {
                    Text("DAILY TOKEN TOTALS · LOCAL")
                }
            }
            .font(ShareStatsActivityBrand.mono(size: 11, weight: .bold))
            .tracking(0.55)
            .foregroundStyle(ShareStatsActivityBrand.secondary)

            HStack(alignment: .bottom, spacing: 4) {
                ForEach(self.cells) { cell in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(ShareStatsActivityBrand.activity(level: cell.level))
                        .overlay {
                            if cell.isPartial {
                                RoundedRectangle(cornerRadius: 2)
                                    .stroke(Color.white.opacity(0.28), lineWidth: 1)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: self.barHeight(for: cell.level))
                }
            }
            .frame(height: 50, alignment: .bottom)

            HStack {
                Text(ShareStatsFormatting.shortDay(self.periodStart))
                Spacer()
                Text(ShareStatsFormatting.shortDay(self.periodEnd))
            }
            .font(ShareStatsActivityBrand.mono(size: 10, weight: .bold))
            .foregroundStyle(ShareStatsActivityBrand.tertiary)
        }
    }

    private func barHeight(for level: Int?) -> CGFloat {
        guard let level else { return 8 }
        return level == 0 ? 8 : 8 + CGFloat(level) * 8
    }
}

private struct ShareStatsWeekCell: Identifiable {
    let id: Int
    let level: Int?
    let isPartial: Bool
}

private struct ShareStatsActivityFooter: View {
    let payload: ShareStatsPayload

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "lock.shield")
                .font(.system(size: 11, weight: .semibold))
            Text("\(self.payload.days) DAYS · AGGREGATED LOCALLY · NO PROMPTS SHARED")
            Spacer()
            Text("DATA THROUGH \(ShareStatsFormatting.dataThrough(self.payload.periodEnd).uppercased())")
        }
        .font(ShareStatsActivityBrand.mono(size: 11, weight: .bold))
        .tracking(0.35)
        .foregroundStyle(ShareStatsActivityBrand.secondary)
    }
}

private struct ShareStatsActivityBackground: View {
    var body: some View {
        ZStack {
            ShareStatsActivityBrand.canvas
            RadialGradient(
                colors: [ShareStatsActivityBrand.coral.opacity(0.10), .clear],
                center: .topLeading,
                startRadius: 0,
                endRadius: 520)
            LinearGradient(
                colors: [Color.white.opacity(0.018), .clear],
                startPoint: .top,
                endPoint: .bottom)
        }
    }
}

@MainActor
private enum ShareStatsActivityBrand {
    static let appIcon: NSImage = Bundle.module
        .url(forResource: "Icon-classic", withExtension: "icns")
        .flatMap(NSImage.init(contentsOf:))
        ?? NSApplication.shared.applicationIconImage

    static let canvas = Color(red: 20.0 / 255.0, green: 18.0 / 255.0, blue: 16.0 / 255.0)
    static let primary = Color(red: 246.0 / 255.0, green: 241.0 / 255.0, blue: 234.0 / 255.0)
    static let secondary = Color(red: 176.0 / 255.0, green: 169.0 / 255.0, blue: 160.0 / 255.0)
    static let tertiary = Color(red: 132.0 / 255.0, green: 126.0 / 255.0, blue: 119.0 / 255.0)
    static let coral = Color(red: 239.0 / 255.0, green: 131.0 / 255.0, blue: 94.0 / 255.0)
    static let teal = Color(red: 85.0 / 255.0, green: 183.0 / 255.0, blue: 173.0 / 255.0)
    static let amber = Color(red: 226.0 / 255.0, green: 181.0 / 255.0, blue: 102.0 / 255.0)
    static let rule = Color.white.opacity(0.13)

    static func mono(size: CGFloat, weight: Font.Weight) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }

    static func routeColor(at index: Int) -> Color {
        [self.teal, self.coral, self.amber][index % 3]
    }

    static func activity(level: Int?) -> Color {
        guard let level else { return Color.white.opacity(0.025) }
        switch level {
        case 1: return self.teal.opacity(0.26)
        case 2: return self.teal.opacity(0.42)
        case 3: return self.teal.opacity(0.60)
        case 4: return self.teal.opacity(0.78)
        case 5: return self.teal
        default: return Color.white.opacity(0.065)
        }
    }
}
