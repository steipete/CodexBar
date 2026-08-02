import CodexBarCore
import SwiftUI

/// One-line menu row for an inactive account in the compact multi-account layout:
/// label on the left, constraint summary plus a mini headroom bar on the right.
/// Clicking the row expands it into the full usage card.
struct MenuCardCompactAccountRowView: View {
    struct Model: Equatable {
        let label: String
        let headroomPercent: Double?
        let severity: AccountMenuLayoutPlanner.Severity?
        let constraintDetail: String?
        let hasError: Bool
        let showsBestBadge: Bool

        var headroomLabel: String? {
            self.headroomPercent.map { "\(Int($0.rounded()))%" }
        }

        var heightFingerprint: String {
            [
                "compactAccount",
                self.label,
                self.headroomLabel ?? "-",
                self.constraintDetail ?? "-",
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
            if let detail = self.model.constraintDetail {
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(self.model.severity == .critical
                        ? MenuHighlightStyle.error(self.isHighlighted)
                        : MenuHighlightStyle.secondary(self.isHighlighted))
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, UsageMenuCardLayout.horizontalPadding)
        .padding(.vertical, 5)
        .frame(width: self.width, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(self.accessibilityText)
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

    private var accessibilityText: String {
        var parts = [self.model.label]
        if let label = self.model.headroomLabel {
            parts.append(String(format: L("%@ remaining"), label))
        }
        if let detail = self.model.constraintDetail {
            parts.append(detail)
        }
        if self.model.hasError {
            parts.append(L("Account unavailable"))
        }
        return parts.joined(separator: ", ")
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
