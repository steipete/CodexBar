import CodexBarCore
import SwiftUI

extension UsageMenuCardView.Model.Metric {
    /// Remaining share at or below which a limit turns red.
    static let nearLimitRemainingPercent: Double = 10

    /// A forecast this close changes what to do right now. A limit that runs out in days does not.
    static let imminentExhaustionSeconds: TimeInterval = 3600

    var remainingPercent: Double {
        self.percentStyle == .left ? self.percent : 100 - self.percent
    }

    var isExhaustionImminent: Bool {
        self.exhaustionETASeconds.map { $0 <= Self.imminentExhaustionSeconds } ?? false
    }

    var isUrgent: Bool {
        self.remainingPercent <= Self.nearLimitRemainingPercent || self.isExhaustionImminent
    }
}

/// One provider on one line: the limit that stops it next. Detail lives in the flyout, so the height is fixed.
struct OverviewProviderLine: Equatable, Identifiable {
    enum Status: Equatable {
        case normal
        case critical
        case stale
    }

    let id: String
    let provider: UsageProvider
    let name: String
    /// The window the figures describe, or the account on a per-account row.
    let caption: String?
    let captionIsCritical: Bool
    /// Bar fill. Follows the Show Used setting. Nil when the provider reports no limit.
    let percent: Double?
    let accessibilityLabel: String
    let value: String?
    let trailing: String?
    let status: Status
    let remainingPercent: Double?
    let exhaustionETASeconds: TimeInterval?

    init(id: String, model: UsageMenuCardView.Model, account: String? = nil) {
        self.id = id
        self.provider = model.provider
        self.name = model.providerName
        let metrics = model.metrics.filter { $0.statusText == nil }
        let imminent = metrics.filter(\.isExhaustionImminent)
            .min { ($0.exhaustionETASeconds ?? 0) < ($1.exhaustionETASeconds ?? 0) }
        let lowest = metrics.min { $0.remainingPercent < $1.remainingPercent }
        // An exhausted limit has already stopped the provider; a forecast only says when one will.
        let tightest = (lowest?.remainingPercent ?? 100) <= 0 ? lowest : (imminent ?? lowest)
        // Match MetricRow: subtitles can describe diagnostics or a different refresh source.
        let isStale = tightest?.retainedMeasurementOverride
            ?? (model.showsRetainedMeasurement && tightest?.isSyntheticCreditLane != true)

        guard let tightest else {
            self.caption = account
            self.captionIsCritical = false
            self.percent = nil
            self.accessibilityLabel = ""
            self.value = Self.fallbackValue(model)
            self.trailing = nil
            self.status = isStale ? .stale : .normal
            self.remainingPercent = nil
            self.exhaustionETASeconds = nil
            return
        }
        self.percent = tightest.percent
        self.accessibilityLabel = tightest.percentStyle.accessibilityLabel
        self.value = tightest.percentLabel
            .replacingOccurrences(of: tightest.percentStyle.labelSuffix, with: "")
            .trimmingCharacters(in: .whitespaces)
        self.remainingPercent = tightest.remainingPercent
        self.exhaustionETASeconds = tightest.exhaustionETASeconds
        self.status = isStale ? .stale : (tightest.isUrgent ? .critical : .normal)
        // Each column keeps one meaning, so the forecast and the stale note take the caption, not the reset's slot.
        // A per-account row keeps the account: without it two rows from one provider read the same.
        let imminentETA = account == nil && !isStale && tightest.isExhaustionImminent
            ? tightest.exhaustionETASeconds : nil
        self.captionIsCritical = imminentETA != nil
        self.caption = if let account {
            account
        } else if let imminentETA {
            "\u{2192} 0% ~\(UsagePaceText.durationText(seconds: imminentETA, now: Date()))"
        } else if isStale {
            L("stale data")
        } else {
            tightest.title
        }
        self.trailing = tightest.resetText.map(Self.shortReset)
    }

    /// "Resets in 2h 18m" reads as "2h 18m" under a Resets column; the localized template supplies what to strip.
    nonisolated static func shortReset(_ text: String) -> String {
        for template in [L("Resets in %@"), L("Resets %@")] {
            let parts = template.components(separatedBy: "%@")
            guard parts.count == 2,
                  text.hasPrefix(parts[0]),
                  text.hasSuffix(parts[1]),
                  text.count > parts[0].count + parts[1].count
            else { continue }
            return String(text.dropFirst(parts[0].count).dropLast(parts[1].count))
        }
        return text
    }

    private static func fallbackValue(_ model: UsageMenuCardView.Model) -> String? {
        // A balance-only limit has no percentage to compare, but its text is still the row's value.
        model.metrics.lazy.compactMap(\.statusText).first
            ?? model.creditsText
            ?? model.providerCost?.spendLine
            ?? model.providerDetails.first?.rows.first?.value
            ?? model.placeholder
    }

    // MARK: - Urgency

    /// Urgent rows sort by when they stop. Below that, coarse bands keep the user's order so rows hold still.
    var urgencyBand: Int {
        if self.status == .critical { return 0 }
        guard let remaining = self.remainingPercent else { return 4 }
        if remaining <= 25 { return 1 }
        return remaining <= 50 ? 2 : 3
    }

    /// A limit at zero carries no forecast, but it has already stopped: nothing can stop sooner.
    private var effectiveETASeconds: TimeInterval {
        if let remaining = self.remainingPercent, remaining <= 0 { return 0 }
        return self.exhaustionETASeconds ?? .infinity
    }

    static func sortedByUrgency(_ lines: [OverviewProviderLine]) -> [OverviewProviderLine] {
        lines.enumerated().sorted { lhs, rhs in
            let (left, right) = (lhs.element, rhs.element)
            if left.urgencyBand != right.urgencyBand { return left.urgencyBand < right.urgencyBand }
            if left.urgencyBand == 0 {
                if left.effectiveETASeconds != right.effectiveETASeconds {
                    return left.effectiveETASeconds < right.effectiveETASeconds
                }
                let (leftLeft, rightLeft) = (left.remainingPercent ?? 100, right.remainingPercent ?? 100)
                if leftLeft != rightLeft { return leftLeft < rightLeft }
            }
            return lhs.offset < rhs.offset
        }
        .map(\.element)
    }
}

/// Shared columns so the bars, percentages and resets line up down the list.
private enum OverviewLineColumns {
    static let logo: CGFloat = 15
    static let name: CGFloat = 104
    static let value: CGFloat = 30
    static let trailing: CGFloat = 46
    static let spacing: CGFloat = 6
}

struct OverviewProviderLineView: View {
    let line: OverviewProviderLine
    let width: CGFloat
    @Environment(\.menuItemHighlighted) private var isHighlighted

    var body: some View {
        HStack(spacing: OverviewLineColumns.spacing) {
            SpendProviderIcon(
                provider: self.line.provider,
                style: self.isHighlighted ? .monochrome : .brand,
                size: OverviewLineColumns.logo,
                foreground: MenuHighlightStyle.primary(self.isHighlighted))
            self.nameCell
            if let percent = self.line.percent {
                UsageProgressBar(
                    percent: percent,
                    tint: self.barTint,
                    accessibilityLabel: self.line.accessibilityLabel)
                    .frame(maxWidth: .infinity)
                self.valueText
                    .frame(width: OverviewLineColumns.value, alignment: .trailing)
                self.trailingText
                    .frame(width: OverviewLineColumns.trailing, alignment: .trailing)
            } else {
                Spacer(minLength: 0)
                self.valueText
            }
        }
        .frame(height: 17)
        .padding(.horizontal, UsageMenuCardLayout.horizontalPadding)
        .frame(width: self.width, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var nameCell: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(self.line.name)
                .font(.callout)
                .fontWeight(.medium)
                .foregroundStyle(MenuHighlightStyle.primary(self.isHighlighted))
                .lineLimit(1)
                .layoutPriority(1)
            if let caption = self.line.caption {
                Text(caption)
                    .font(.caption2)
                    .foregroundStyle(self.line.captionIsCritical
                        ? MenuHighlightStyle.error(self.isHighlighted)
                        : MenuHighlightStyle.secondary(self.isHighlighted))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .frame(width: OverviewLineColumns.name, alignment: .leading)
    }

    private var valueText: some View {
        Text(self.line.value ?? "")
            .font(.footnote)
            .fontWeight(self.line.status == .critical ? .semibold : .regular)
            .monospacedDigit()
            .foregroundStyle(self.valueColor)
            .lineLimit(1)
    }

    private var trailingText: some View {
        Text(self.line.trailing ?? "")
            .font(.caption)
            .monospacedDigit()
            .foregroundStyle(MenuHighlightStyle.secondary(self.isHighlighted))
            .lineLimit(1)
            .minimumScaleFactor(0.8)
    }

    private var barTint: Color {
        switch self.line.status {
        case .critical: Color(nsColor: .systemRed)
        case .stale: Color.primary.opacity(0.28)
        case .normal: Color.primary.opacity(0.7)
        }
    }

    private var valueColor: Color {
        switch self.line.status {
        case .critical: MenuHighlightStyle.error(self.isHighlighted)
        case .stale: MenuHighlightStyle.secondary(self.isHighlighted)
        case .normal: MenuHighlightStyle.primary(self.isHighlighted)
        }
    }
}

/// Column heads for the list. A bare "8%" only reads correctly if it says whether that is left or used.
struct OverviewLinesHeaderView: View {
    let percentStyle: UsageMenuCardView.Model.PercentStyle
    let width: CGFloat

    var body: some View {
        HStack(spacing: OverviewLineColumns.spacing) {
            Text(L("Usage"))
            Spacer(minLength: 0)
            Text(self.percentStyle.labelSuffix.localizedCapitalized)
                .frame(minWidth: OverviewLineColumns.value, alignment: .trailing)
            Text(L("Resets"))
                .frame(width: OverviewLineColumns.trailing, alignment: .trailing)
        }
        .font(.caption2)
        .foregroundStyle(MenuHighlightStyle.normalSecondaryText)
        .lineLimit(1)
        .padding(.horizontal, UsageMenuCardLayout.horizontalPadding)
        .frame(width: self.width, alignment: .leading)
        .frame(height: 8)
    }
}

/// Providers whose only state is an error. One line however many, so a broken provider cannot push the footer.
struct OverviewAttentionRowView: View {
    let provider: UsageProvider?
    /// Nil on the combined row, where the message already lists every provider.
    let name: String?
    let message: String
    let width: CGFloat
    @Environment(\.menuItemHighlighted) private var isHighlighted

    var body: some View {
        HStack(alignment: .center, spacing: OverviewLineColumns.spacing) {
            if let provider {
                SpendProviderIcon(
                    provider: provider,
                    style: self.isHighlighted ? .monochrome : .brand,
                    size: OverviewLineColumns.logo,
                    foreground: MenuHighlightStyle.primary(self.isHighlighted))
            } else {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(MenuHighlightStyle.error(self.isHighlighted))
                    .frame(width: OverviewLineColumns.logo)
            }
            if let name {
                Text(name)
                    .font(.callout)
                    .fontWeight(.medium)
                    .foregroundStyle(MenuHighlightStyle.primary(self.isHighlighted))
                    .lineLimit(1)
                    .layoutPriority(1)
            }
            Text(self.message)
                .font(.caption)
                .foregroundStyle(MenuHighlightStyle.error(self.isHighlighted))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .frame(height: 17)
        .padding(.horizontal, UsageMenuCardLayout.horizontalPadding)
        .frame(width: self.width, alignment: .leading)
        .help([self.name, self.message].compactMap(\.self).joined(separator: ": "))
        .accessibilityElement(children: .combine)
    }
}
