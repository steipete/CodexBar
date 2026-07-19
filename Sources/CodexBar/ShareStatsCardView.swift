import SwiftUI

struct ShareStatsCardView: View {
    static let size = CGSize(width: 1200, height: 630)

    let payload: ShareStatsPayload

    static func providerDisplayLimit(for providerCount: Int) -> Int {
        providerCount > 5 ? 4 : min(providerCount, 5)
    }

    static func providerPaletteIndex(
        for model: ShareStatsModelPayload,
        providers: [ShareStatsProviderPayload]) -> Int?
    {
        providers.firstIndex { $0.provider == model.provider }
    }

    private let background = Color(red: 0.078, green: 0.067, blue: 0.063)
    private let primary = Color(red: 0.96, green: 0.94, blue: 0.91)
    private let secondary = Color(red: 0.70, green: 0.66, blue: 0.62)
    private let accent = Color(red: 0.93, green: 0.56, blue: 0.36)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            self.header
            self.hero
                .padding(.top, 16)
            Rectangle()
                .fill(self.secondary.opacity(0.22))
                .frame(height: 1)
                .padding(.vertical, 17)
            self.rankings
                .frame(height: 286, alignment: .top)
            Spacer(minLength: 10)
            self.footer
        }
        .padding(.horizontal, 52)
        .padding(.vertical, 34)
        .frame(width: Self.size.width, height: Self.size.height, alignment: .topLeading)
        .background(self.background)
        .foregroundStyle(self.primary)
        .environment(\.colorScheme, .dark)
    }

    private var header: some View {
        HStack(alignment: .center) {
            HStack(spacing: 14) {
                ShareStatsMark(accent: self.accent)
                    .frame(width: 34, height: 34)
                Text("CodexBar")
                    .font(.system(size: 26, weight: .semibold, design: .rounded))
            }
            Spacer()
            Text("LOCAL SNAPSHOT")
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .tracking(1.8)
                .foregroundStyle(self.secondary)
                .padding(.horizontal, 15)
                .padding(.vertical, 9)
                .overlay {
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(self.secondary.opacity(0.45), lineWidth: 1)
                }
        }
    }

    private var hero: some View {
        HStack(alignment: .bottom, spacing: 52) {
            VStack(alignment: .leading, spacing: 2) {
                Text("TRACKED TOKENS · \(self.payload.days) DAYS")
                    .font(.system(size: 20, weight: .semibold, design: .rounded))
                    .tracking(1.8)
                    .foregroundStyle(self.secondary)
                Text(self.payload.totalTokens.map(ShareStatsFormatting.compactCount) ?? "—")
                    .font(.system(size: 104, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .leading, spacing: 9) {
                Text("EST. \(self.payload.days)-DAY SPEND")
                    .font(.system(size: 18, weight: .semibold, design: .rounded))
                    .tracking(1.2)
                    .foregroundStyle(self.secondary)
                ForEach(self.payload.currencies.prefix(2)) { currency in
                    HStack(alignment: .firstTextBaseline) {
                        Text("\(currency.currencyCode) · \(currency.coveredDayCount)/\(self.payload.days)d")
                            .font(.system(size: 17, weight: .semibold, design: .rounded))
                            .foregroundStyle(self.secondary)
                        Spacer()
                        Text(currency.estimatedCost.map {
                            ShareStatsFormatting.currency($0, code: currency.currencyCode)
                        } ?? "Unavailable")
                            .font(.system(size: 32, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .lineLimit(1)
                            .minimumScaleFactor(0.72)
                    }
                }
                Text(self.currencySummary)
                    .font(.system(size: 16, weight: .medium, design: .rounded))
                    .foregroundStyle(self.secondary)
            }
            .frame(width: 390, alignment: .leading)
        }
        .frame(height: 132, alignment: .bottom)
    }

    private var currencySummary: String {
        let hiddenCount = self.payload.currencies.count - min(self.payload.currencies.count, 2)
        return hiddenCount > 0
            ? "+\(hiddenCount) more currencies · see subscription rows"
            : "\(self.payload.providers.count) subscriptions · native currencies kept separate"
    }

    private var rankings: some View {
        HStack(alignment: .top, spacing: 46) {
            VStack(alignment: .leading, spacing: 6) {
                self.sectionHeader("SUBSCRIPTIONS", detail: "\(self.payload.providers.count) CONNECTED")
                ForEach(
                    Array(self.payload.providers.prefix(self.providerDisplayLimit).enumerated()),
                    id: \.offset)
                { index, provider in
                    ShareStatsProviderRow(
                        rank: index + 1,
                        provider: provider,
                        days: self.payload.days,
                        color: ShareStatsPalette.color(at: index))
                }
                if self.payload.providers.count > self.providerDisplayLimit {
                    Text("+\(self.payload.providers.count - self.providerDisplayLimit) more configured")
                        .font(.system(size: 16, weight: .medium, design: .rounded))
                        .foregroundStyle(self.secondary)
                        .padding(.leading, 20)
                }
            }
            .frame(width: 554, alignment: .topLeading)

            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 6) {
                    self.sectionHeader("TOP MODELS", detail: "BY USAGE")
                    if self.payload.topModels.isEmpty {
                        Text("No model-level history in this local snapshot")
                            .font(.system(size: 18, weight: .medium, design: .rounded))
                            .foregroundStyle(self.secondary)
                            .padding(.top, 4)
                    } else {
                        ForEach(
                            Array(self.payload.topModels.prefix(3).enumerated()),
                            id: \.offset)
                        { index, model in
                            ShareStatsModelRow(
                                rank: index + 1,
                                model: model,
                                color: self.color(for: model))
                        }
                    }
                }
                Text("Only aggregate usage, plan tier, and estimated spend are included.")
                    .font(.system(size: 16, weight: .medium, design: .rounded))
                    .foregroundStyle(self.secondary)
                    .padding(.top, 18)
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    private var providerDisplayLimit: Int {
        Self.providerDisplayLimit(for: self.payload.providers.count)
    }

    private func color(for model: ShareStatsModelPayload) -> Color {
        guard let index = Self.providerPaletteIndex(for: model, providers: self.payload.providers) else {
            return self.secondary
        }
        return ShareStatsPalette.color(at: index)
    }

    private func sectionHeader(_ title: String, detail: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.system(size: 18, weight: .semibold, design: .rounded))
                .tracking(1.5)
            Spacer()
            Text(detail)
                .font(.system(size: 16, weight: .semibold, design: .rounded))
                .tracking(1.0)
        }
        .foregroundStyle(self.secondary)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Label("LOCAL · AGGREGATE ONLY", systemImage: "lock.shield")
            Spacer()
            Text("DATA THROUGH \(ShareStatsFormatting.dataThrough(self.payload.periodEnd).uppercased())")
        }
        .font(.system(size: 14, weight: .medium, design: .rounded))
        .tracking(0.7)
        .foregroundStyle(self.secondary)
    }
}

private struct ShareStatsModelRow: View {
    let rank: Int
    let model: ShareStatsModelPayload
    let color: Color

    var body: some View {
        HStack(spacing: 9) {
            Capsule()
                .fill(self.color)
                .frame(width: 5, height: 34)
            Text(String(format: "%02d", self.rank))
                .font(.system(size: 17, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(Color(red: 0.70, green: 0.66, blue: 0.62))
                .frame(width: 27, alignment: .leading)
            VStack(alignment: .leading, spacing: 1) {
                Text(self.model.modelName)
                    .font(.system(size: 20, weight: .semibold, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
                Text(self.model.providerName)
                    .font(.system(size: 16, weight: .medium, design: .rounded))
                    .foregroundStyle(Color(red: 0.70, green: 0.66, blue: 0.62))
                    .lineLimit(1)
            }
            Spacer(minLength: 10)
            Text(self.detail)
                .font(.system(size: 17, weight: .medium, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(Color(red: 0.78, green: 0.74, blue: 0.69))
                .lineLimit(1)
        }
        .padding(.horizontal, 9)
        .frame(height: 48)
        .background(Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 9))
        .overlay {
            RoundedRectangle(cornerRadius: 9)
                .stroke(Color.white.opacity(0.10), lineWidth: 1)
        }
    }

    private var detail: String {
        if let cost = self.model.estimatedCost, cost.isFinite {
            return "~\(ShareStatsFormatting.currency(cost, code: self.model.currencyCode))"
        }
        return self.model.totalTokens.map(ShareStatsFormatting.compactCount) ?? "used"
    }
}

private struct ShareStatsProviderRow: View {
    let rank: Int
    let provider: ShareStatsProviderPayload
    let days: Int
    let color: Color

    var body: some View {
        HStack(spacing: 9) {
            Capsule()
                .fill(self.color)
                .frame(width: 6, height: 30)
            Text(String(format: "%02d", self.rank))
                .font(.system(size: 17, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(Color(red: 0.70, green: 0.66, blue: 0.62))
                .frame(width: 27, alignment: .leading)
            HStack(spacing: 8) {
                Text(self.provider.providerName)
                    .font(.system(size: 20, weight: .semibold, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
                if let subscriptionName = self.provider.subscriptionName {
                    Text("· \(subscriptionName)")
                        .font(.system(size: 17, weight: .medium, design: .rounded))
                        .foregroundStyle(Color(red: 0.70, green: 0.66, blue: 0.62))
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 12)
            Text(self.detail)
                .font(.system(size: 18, weight: .medium, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(Color(red: 0.78, green: 0.74, blue: 0.69))
                .lineLimit(1)
                .minimumScaleFactor(0.82)
        }
        .padding(.horizontal, 9)
        .frame(height: 44)
        .background(Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 9))
        .overlay {
            RoundedRectangle(cornerRadius: 9)
                .stroke(Color.white.opacity(0.10), lineWidth: 1)
        }
    }

    private var detail: String {
        var metrics: [String] = []
        if let tokens = self.provider.totalTokens {
            metrics.append(ShareStatsFormatting.compactCount(tokens))
        }
        if let cost = self.provider.estimatedCost, cost.isFinite {
            metrics.append("~\(ShareStatsFormatting.currency(cost, code: self.provider.currencyCode))")
            if self.provider.coveredDayCount < self.days {
                metrics.append("\(self.provider.coveredDayCount)/\(self.days)d")
            }
        } else {
            metrics.append("Spend unavailable")
        }
        return metrics.isEmpty ? "connected" : metrics.joined(separator: " · ")
    }
}

private enum ShareStatsPalette {
    static let colors = [
        Color(red: 1.00, green: 0.60, blue: 0.38),
        Color(red: 0.60, green: 0.66, blue: 1.00),
        Color(red: 0.38, green: 0.84, blue: 0.72),
        Color(red: 0.95, green: 0.79, blue: 0.41),
        Color(red: 0.44, green: 0.77, blue: 0.96),
        Color(red: 0.95, green: 0.55, blue: 0.67),
    ]

    static func color(at index: Int) -> Color {
        self.colors[index % self.colors.count]
    }
}

private struct ShareStatsMark: View {
    let accent: Color

    var body: some View {
        HStack(alignment: .bottom, spacing: 4) {
            ForEach(Array([0.38, 0.68, 1.0].enumerated()), id: \.offset) { _, height in
                Capsule()
                    .fill(self.accent)
                    .frame(width: 5, height: 28 * height)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }
}
