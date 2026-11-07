import CodexBarCore
import SwiftUI

struct ShareStatsCardView: View {
    static let size = CGSize(width: 1200, height: 630)

    let payload: ShareStatsPayload
    @Environment(\.colorScheme) private var colorScheme

    static func providerDisplayLimit(for providerCount: Int) -> Int {
        providerCount > 5 ? 4 : min(providerCount, 5)
    }

    /// "Cursor Pro" already names its provider; "Max" needs "Claude" in front of it.
    static func rollCallName(_ provider: ShareStatsProviderPayload) -> String {
        guard let plan = provider.subscriptionName else { return provider.providerName }
        if plan.localizedCaseInsensitiveContains(provider.providerName) {
            return plan
        }
        return "\(provider.providerName) \(plan)"
    }

    enum Hero: Equatable {
        case spend(ShareStatsCurrencyPayload)
        case tokens
    }

    /// Spend leads only when it is one complete figure; a partial or multi-currency total would
    /// overstate what the snapshot knows, so tokens lead instead.
    static func hero(for payload: ShareStatsPayload) -> Hero {
        guard payload.currencies.count == 1,
              let currency = payload.currencies.first,
              let cost = currency.estimatedCost, cost.isFinite, cost > 0,
              !currency.isPartial,
              currency.coveredDayCount >= payload.days || ShareStatsFormatting.isAllTime(payload)
        else { return .tokens }
        return .spend(currency)
    }

    /// One hero, one ranked list. Four type sizes: hero, value, body, label.
    private enum Scale {
        static let hero: CGFloat = 124
        static let value: CGFloat = 28
        static let body: CGFloat = 20
        static let label: CGFloat = 15
    }

    private var theme: ShareStatsTheme {
        ShareStatsTheme(colorScheme: self.colorScheme)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            self.header
            HStack(alignment: .top, spacing: 64) {
                self.summary
                    .frame(width: 500, alignment: .topLeading)
                self.topModels
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .padding(.top, 30)
            Spacer(minLength: 12)
            self.footer
        }
        .padding(.horizontal, 56)
        .padding(.vertical, 40)
        .frame(width: Self.size.width, height: Self.size.height, alignment: .topLeading)
        .background(self.theme.surface)
        .foregroundStyle(self.theme.ink)
    }

    private var header: some View {
        HStack(spacing: 12) {
            ShareStatsMark(color: self.theme.ink)
                .frame(width: 26, height: 26)
            Text("CodexBar")
                .font(.system(size: Scale.body, weight: .semibold))
        }
    }

    // MARK: Summary

    private var summary: some View {
        VStack(alignment: .leading, spacing: 0) {
            self.label(self.heroLabel)
            Text(self.heroValue)
                .font(.system(size: Scale.hero, weight: .semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.55)
                .padding(.top, -4)
            self.secondary
                .padding(.top, 8)
            Spacer(minLength: 18)
            self.providerRow
        }
        .frame(height: 384, alignment: .topLeading)
    }

    @ViewBuilder
    private var secondary: some View {
        switch Self.hero(for: self.payload) {
        case .spend:
            VStack(alignment: .leading, spacing: 4) {
                self.label(L("TRACKED TOKENS · %@", String(describing: self.periodLabel)))
                Text(self.trackedTokensText)
                    .font(.system(size: Scale.value, weight: .semibold))
                    .monospacedDigit()
            }
        case .tokens:
            VStack(alignment: .leading, spacing: 4) {
                self.label(L("EST. %@", String(describing: self.spendLabel)))
                HStack(alignment: .firstTextBaseline, spacing: 18) {
                    ForEach(self.payload.currencies.prefix(2)) { currency in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(self.spendText(for: currency))
                                .font(.system(size: Scale.value, weight: .semibold))
                                .monospacedDigit()
                                .lineLimit(1)
                            if currency.coveredDayCount < self.payload.days, !self.isAllTime {
                                self.label(L("%d/%dd", currency.coveredDayCount, self.payload.days))
                            }
                        }
                    }
                    if self.payload.currencies.count > 2 {
                        self.label("+\(codexBarLocalizedInteger(self.payload.currencies.count - 2))")
                    }
                }
            }
        }
    }

    /// Each connected provider as its own logo chip with its name: identity by mark, never by a
    /// coloured frame, and no overlap that would hide one logo behind another.
    private var providerRow: some View {
        let shown = Array(self.payload.providers.prefix(self.providerDisplayLimit))
        let hidden = self.payload.providers.count - shown.count
        return ViewThatFits(in: .horizontal) {
            self.providerPills(shown, hidden: hidden, showsNames: true)
            self.providerPills(shown, hidden: hidden, showsNames: false)
        }
    }

    private func providerPills(
        _ providers: [ShareStatsProviderPayload],
        hidden: Int,
        showsNames: Bool) -> some View
    {
        HStack(spacing: 18) {
            ForEach(Array(providers.enumerated()), id: \.offset) { _, provider in
                HStack(spacing: 10) {
                    self.theme.chip(for: provider.provider, size: 36)
                    if showsNames {
                        Text(Self.rollCallName(provider))
                            .font(.system(size: Scale.label + 2, weight: .medium))
                            .foregroundStyle(self.theme.muted)
                            .lineLimit(1)
                            .fixedSize()
                    }
                }
            }
            if hidden > 0 {
                self.label(L("+%@ more configured", String(describing: hidden)))
            }
        }
    }

    // MARK: Top models

    private var topModels: some View {
        let models = Array(self.payload.topModels.prefix(4))
        let shares = ShareStatsModelShares.make(self.payload)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                self.label(L("TOP MODELS"))
                Spacer()
                self.label(self.payload.modelRankingDetail)
            }
            .padding(.bottom, 10)
            if models.isEmpty {
                Text(L("No model-level history in this local snapshot"))
                    .font(.system(size: Scale.body, weight: .medium))
                    .foregroundStyle(self.theme.muted)
                    .padding(.top, 4)
            } else {
                ForEach(Array(models.enumerated()), id: \.offset) { index, model in
                    if index > 0 {
                        Rectangle().fill(self.theme.keyline).frame(height: 1)
                    }
                    ShareStatsModelRow(
                        rank: self.payload.hasPartialModels ? nil : index + 1,
                        model: model,
                        share: shares?[index],
                        theme: self.theme,
                        bodySize: Scale.body,
                        valueSize: Scale.value,
                        labelSize: Scale.label)
                }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Label(L("LOCAL · AGGREGATE ONLY"), systemImage: "lock.shield")
            Spacer()
            Text(L("DATA THROUGH %@", String(describing: ShareStatsFormatting.dataThrough(self.payload).uppercased())))
        }
        .font(.system(size: Scale.label, weight: .medium))
        .tracking(0.7)
        .foregroundStyle(self.theme.muted)
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .font(.system(size: Scale.label, weight: .semibold))
            .tracking(1.2)
            .foregroundStyle(self.theme.muted)
            .lineLimit(1)
    }

    private var heroLabel: String {
        switch Self.hero(for: self.payload) {
        case .spend: L("EST. %@", String(describing: self.spendLabel))
        case .tokens: L("TRACKED TOKENS · %@", String(describing: self.periodLabel))
        }
    }

    private var heroValue: String {
        switch Self.hero(for: self.payload) {
        case let .spend(currency): self.spendText(for: currency)
        case .tokens: self.trackedTokensText
        }
    }

    private var providerDisplayLimit: Int {
        Self.providerDisplayLimit(for: self.payload.providers.count)
    }

    private var isAllTime: Bool {
        self.payload.days >= SpendDashboardSource.scanDays
    }

    private var periodLabel: String {
        self.isAllTime ? L("ALL") : L("%d DAYS", self.payload.days)
    }

    private var spendLabel: String {
        self.isAllTime ? L("ALL-TIME SPEND") : L("%d-DAY SPEND", self.payload.days)
    }

    private var trackedTokensText: String {
        guard let tokens = self.payload.totalTokens else { return "—" }
        let formatted = ShareStatsFormatting.compactCount(tokens)
        return self.payload.hasPartialTokens ? "~\(formatted)" : formatted
    }

    private func spendText(for currency: ShareStatsCurrencyPayload) -> String {
        guard let cost = currency.estimatedCost else { return L("Unavailable") }
        let formatted = ShareStatsFormatting.currency(cost, code: currency.currencyCode)
        return currency.isPartial ? "~\(formatted)" : formatted
    }
}

/// Neutral share-card tokens: paper white or neutral graphite, never a warm black.
/// Colour on the card comes only from provider marks.
struct ShareStatsTheme {
    let surface: Color
    let plate: Color
    let keyline: Color
    let ink: Color
    let muted: Color

    init(colorScheme: ColorScheme) {
        if colorScheme == .dark {
            self.surface = Self.gray(0x17)
            self.plate = Self.gray(0x23)
            self.keyline = Self.gray(0x30)
            self.ink = Self.gray(0xED)
            self.muted = Self.gray(0xA6)
        } else {
            self.surface = Self.gray(0xFF)
            self.plate = Color(red: 0xF4 / 255, green: 0xF4 / 255, blue: 0xF2 / 255)
            self.keyline = Color(red: 0xE9 / 255, green: 0xE9 / 255, blue: 0xE6 / 255)
            self.ink = Self.gray(0x11)
            self.muted = Color(red: 0x6E / 255, green: 0x6E / 255, blue: 0x6B / 255)
        }
    }

    /// The shared provider mark in this card's fixed tokens, so the export never depends on system colours.
    func chip(for provider: UsageProvider, size: CGFloat) -> ProviderMarkChip {
        ProviderMarkChip(
            provider: provider,
            size: size,
            plate: self.plate,
            keyline: self.keyline,
            keylineWidth: 1,
            ink: self.ink)
    }

    private static func gray(_ value: Int) -> Color {
        Color(white: Double(value) / 255)
    }
}

/// Each model family's share of all ranked families' tokens, in `topModels` order.
///
/// The denominator is every family in the payload, not the rows the card has room for. Shares are
/// withheld when the ranking is partial or a family has no token count: a percentage of an
/// unknown whole would overstate what the snapshot knows.
enum ShareStatsModelShares {
    static func make(_ payload: ShareStatsPayload) -> [Double]? {
        guard !payload.hasPartialModels, !payload.topModels.isEmpty else { return nil }
        let tokens = payload.topModels.compactMap(\.totalTokens)
        guard tokens.count == payload.topModels.count else { return nil }
        let total = tokens.reduce(0.0) { $0 + Double(max($1, 0)) }
        guard total > 0, total.isFinite else { return nil }
        return tokens.map { Double(max($0, 0)) / total }
    }

    static func text(_ share: Double) -> String {
        share.formatted(FloatingPointFormatStyle<Double>.Percent()
            .precision(.fractionLength(share > 0 && share < 0.01 ? 1 : 0))
            .locale(codexBarLocalizedResourceLocale()))
    }
}

struct ShareStatsModelRow: View {
    let rank: Int?
    let model: ShareStatsModelPayload
    let share: Double?
    let theme: ShareStatsTheme
    let bodySize: CGFloat
    let valueSize: CGFloat
    let labelSize: CGFloat

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            Text(self.rank.map(ShareStatsModelRow.rankText) ?? "·")
                .font(.system(size: self.labelSize, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(self.theme.muted)
                .frame(width: 22, alignment: .leading)
            self.theme.chip(for: self.model.provider, size: 40)
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(self.model.modelName)
                        .font(.system(size: self.bodySize, weight: .semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    // A family named after its provider ("Claude" by Claude) would only repeat itself.
                    if self.model.providerName.localizedCaseInsensitiveCompare(self.model.modelName) != .orderedSame {
                        Text(self.model.providerName)
                            .font(.system(size: self.labelSize, weight: .medium))
                            .foregroundStyle(self.theme.muted)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 12)
                    Text(self.primaryValue)
                        .font(.system(
                            size: self.share == nil ? self.bodySize : self.valueSize,
                            weight: .semibold))
                        .monospacedDigit()
                        .lineLimit(1)
                }
                if let share {
                    HStack(spacing: 10) {
                        ShareStatsShareBar(share: share, theme: self.theme)
                        if let tokens = self.model.totalTokens {
                            Text(ShareStatsFormatting.compactCount(tokens))
                                .font(.system(size: self.labelSize, weight: .medium))
                                .monospacedDigit()
                                .foregroundStyle(self.theme.muted)
                                .frame(width: 64, alignment: .trailing)
                        }
                    }
                }
            }
        }
        .padding(.vertical, 9)
    }

    /// Two-digit rank ("01") in the card's locale digits.
    nonisolated static func rankText(_ rank: Int) -> String {
        rank.formatted(IntegerFormatStyle<Int>()
            .precision(.integerLength(2))
            .grouping(.never)
            .locale(codexBarLocalizedResourceLocale()))
    }

    /// The share leads when the card knows the whole; otherwise the row's own amount does.
    private var primaryValue: String {
        if let share = self.share {
            return ShareStatsModelShares.text(share)
        }
        return self.amount ?? L("used")
    }

    private var amount: String? {
        if let cost = self.model.estimatedCost, cost.isFinite {
            return "~\(ShareStatsFormatting.currency(cost, code: self.model.currencyCode))"
        }
        return self.model.totalTokens.map(ShareStatsFormatting.compactCount)
    }
}

/// Share of the whole in ink. Provider colour stays in the mark beside it.
struct ShareStatsShareBar: View {
    let share: Double
    let theme: ShareStatsTheme

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(self.theme.keyline)
                Capsule()
                    .fill(self.theme.ink.opacity(0.85))
                    .frame(width: Self.fillWidth(share: self.share, trackWidth: proxy.size.width))
            }
        }
        .frame(height: 5)
    }

    /// A visible sliver keeps tiny shares legible; a zero share draws no fill at all.
    nonisolated static func fillWidth(share: Double, trackWidth: CGFloat) -> CGFloat {
        guard share > 0 else { return 0 }
        return max(trackWidth * min(share, 1), 4)
    }
}

private struct ShareStatsMark: View {
    let color: Color

    var body: some View {
        HStack(alignment: .bottom, spacing: 4) {
            ForEach(Array([0.38, 0.68, 1.0].enumerated()), id: \.offset) { _, height in
                Capsule()
                    .fill(self.color)
                    .frame(width: 5, height: 26 * height)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }
}
