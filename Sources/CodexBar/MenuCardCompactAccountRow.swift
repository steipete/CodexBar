import CodexBarCore
import SwiftUI

/// Compact menu row for an inactive account: identity and a mini headroom bar,
/// followed by quota details with their provider-reported reset times.
/// Clicking the row expands it into the full usage card.
struct MenuCardCompactAccountRowView: View {
    struct Model: Equatable {
        let label: String
        let headroomPercent: Double?
        let severity: AccountMenuLayoutPlanner.Severity?
        let detailLines: [String]
        let hasError: Bool
        let showsBestBadge: Bool

        init(
            row: AccountMenuLayoutPlanner.CompactRow,
            resetTimeDisplayStyle: ResetTimeDisplayStyle,
            hidePersonalInfo: Bool = false,
            now: Date = .init())
        {
            self.label = PersonalInfoRedactor.redactEmail(row.label, isEnabled: hidePersonalInfo)
            self.headroomPercent = row.headroomPercent
            self.severity = row.severity
            self.detailLines = row.windowDetails.map { detail in
                let title = localizedSessionQuotaLabel(detail.label, windowMinutes: detail.window.windowMinutes)
                let percent = UsageFormatter.percentText(
                    detail.window.remainingPercent,
                    suffix: L("usage_percent_suffix_left"))
                let reset: String? = switch detail.resetPresentation {
                case .standard:
                    UsageFormatter.resetLine(for: detail.window, style: resetTimeDisplayStyle, now: now)
                case .hidden:
                    nil
                case .providerDescription:
                    detail.window.resetDescription?.trimmingCharacters(in: .whitespacesAndNewlines)
                }
                let line = ["\(title) \(percent)", reset].compactMap(\.self).filter { !$0.isEmpty }
                    .joined(separator: " · ")
                return PersonalInfoRedactor.redactEmails(in: line, isEnabled: hidePersonalInfo) ?? line
            }
            self.hasError = row.hasError
            self.showsBestBadge = row.isBestCandidate
        }

        var accessibilityText: String {
            var parts = [self.label]
            if let label = self.headroomLabel {
                parts.append(String(format: L("%@ remaining"), label))
            }
            parts.append(contentsOf: self.detailLines)
            if self.hasError {
                parts.append(L("Account unavailable"))
            }
            return parts.joined(separator: ", ")
        }

        var headroomLabel: String? {
            self.headroomPercent.map { "\(Int($0.rounded()))%" }
        }

        var heightFingerprint: String {
            [
                "compactAccount",
                self.label,
                self.headroomLabel ?? "-",
                self.detailLines.joined(separator: "|"),
                self.hasError ? "error" : "ok",
                self.showsBestBadge ? "best" : "plain",
            ].joined(separator: "|")
        }
    }

    static let miniBarWidth: CGFloat = 56
    static let miniBarHeight: CGFloat = 4

    let model: Model
    let progressColor: Color
    let width: CGFloat
    @Environment(\.menuItemHighlighted) private var isHighlighted

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(self.model.label)
                    .font(.subheadline)
                    .foregroundStyle(MenuHighlightStyle.primary(self.isHighlighted))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if self.model.showsBestBadge {
                    Image(systemName: "star.fill")
                        .font(.caption2)
                        .foregroundStyle(self.isHighlighted
                            ? MenuHighlightStyle.selectionText
                            : Color(nsColor: .systemYellow))
                        .accessibilityLabel(L("Most usable account"))
                }
                Spacer(minLength: 12)
                if self.model.hasError, self.model.headroomPercent == nil {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(MenuHighlightStyle.error(self.isHighlighted))
                        .accessibilityLabel(L("Account unavailable"))
                } else if let headroom = self.model.headroomPercent, let label = self.model.headroomLabel {
                    Capsule()
                        .fill(MenuHighlightStyle.progressTrack(self.isHighlighted))
                        .frame(width: Self.miniBarWidth, height: Self.miniBarHeight)
                        .overlay(alignment: .leading) {
                            Capsule()
                                .fill(self.severityColor)
                                .frame(width: Self.miniBarWidth * min(100, max(0, headroom)) / 100)
                        }
                        .accessibilityHidden(true)
                    Text(label)
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(self.percentColor)
                        .lineLimit(1)
                        .frame(minWidth: 34, alignment: .trailing)
                }
            }
            ForEach(Array(self.model.detailLines.enumerated()), id: \.offset) { _, detail in
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(self.model.severity == .critical
                        ? MenuHighlightStyle.error(self.isHighlighted)
                        : MenuHighlightStyle.secondary(self.isHighlighted))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, UsageMenuCardLayout.horizontalPadding)
        .padding(.vertical, 5)
        .frame(width: self.width, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(self.model.accessibilityText)
    }

    private var severityColor: Color {
        guard !self.isHighlighted else { return MenuHighlightStyle.selectionText }
        switch self.model.severity {
        case .critical: return Color(nsColor: .systemRed)
        case .warning: return Color(nsColor: .systemOrange)
        case .healthy, .none: return self.progressColor
        }
    }

    private var percentColor: Color {
        guard !self.isHighlighted else { return MenuHighlightStyle.selectionText }
        switch self.model.severity {
        case .critical: return Color(nsColor: .systemRed)
        case .warning: return Color(nsColor: .systemOrange)
        case .healthy, .none: return MenuHighlightStyle.normalSecondaryText
        }
    }
}

/// Summary row standing in for the healthy accounts hidden by the compact
/// multi-account layout; clicking it reveals the individual rows.
struct MenuCardCollapsedAccountsRowView: View {
    let count: Int
    let width: CGFloat
    @Environment(\.menuItemHighlighted) private var isHighlighted

    var title: String {
        String(format: L("%d more accounts ready"), self.count)
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle")
                .font(.footnote)
                .foregroundStyle(MenuHighlightStyle.secondary(self.isHighlighted))
            Text(self.title)
                .font(.footnote)
                .foregroundStyle(MenuHighlightStyle.secondary(self.isHighlighted))
            Spacer(minLength: 12)
            Image(systemName: "chevron.down")
                .font(.caption2)
                .foregroundStyle(MenuHighlightStyle.secondary(self.isHighlighted))
        }
        .padding(.horizontal, UsageMenuCardLayout.horizontalPadding)
        .padding(.vertical, 5)
        .frame(width: self.width, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(self.title)
        .accessibilityHint(L("Shows the hidden accounts"))
    }
}
