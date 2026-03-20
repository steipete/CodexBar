import CodexBarCore
import SwiftUI

/// Menu card showing plan/tier info for every connected Codex account.
struct AccountCostsMenuCardView: View {
    let entries: [AccountCostEntry]
    let isLoading: Bool
    let width: CGFloat

    @Environment(\.menuItemHighlighted) private var isHighlighted

    static let nameWidth: CGFloat = 70
    static let badgeWidth: CGFloat = 42
    static let colWidth: CGFloat = 72

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                // Mirror the row layout: icon(small) + name + badge, then columns
                Spacer()
                    .frame(width: 14) // icon space
                Spacer()
                    .frame(width: Self.nameWidth)
                Spacer()
                    .frame(width: Self.badgeWidth)
                Text("Session")
                    .font(.caption2)
                    .foregroundStyle(MenuHighlightStyle.secondary(self.isHighlighted))
                    .frame(width: Self.colWidth, alignment: .leading)
                Text("Weekly")
                    .font(.caption2)
                    .foregroundStyle(MenuHighlightStyle.secondary(self.isHighlighted))
                    .frame(width: Self.colWidth, alignment: .leading)
                Text("Credits")
                    .font(.caption2)
                    .foregroundStyle(MenuHighlightStyle.secondary(self.isHighlighted))
                    .frame(width: Self.colWidth, alignment: .trailing)
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .padding(.bottom, 6)

            Divider()
                .padding(.horizontal, 16)

            if self.isLoading && self.entries.isEmpty {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Loading…")
                        .font(.footnote)
                        .foregroundStyle(MenuHighlightStyle.secondary(self.isHighlighted))
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            } else if self.entries.isEmpty {
                Text("No accounts connected.")
                    .font(.footnote)
                    .foregroundStyle(MenuHighlightStyle.secondary(self.isHighlighted))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(self.entries) { entry in
                        AccountCostRow(entry: entry, isHighlighted: self.isHighlighted)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 10)
            }
        }
        .frame(width: self.width, alignment: .leading)
    }
}

private struct AccountCostRow: View {
    let entry: AccountCostEntry
    let isHighlighted: Bool

    private static let colWidth: CGFloat = AccountCostsMenuCardView.colWidth

    private static let nameWidth: CGFloat = AccountCostsMenuCardView.nameWidth
    private static let badgeWidth: CGFloat = AccountCostsMenuCardView.badgeWidth

    var body: some View {
        HStack(alignment: .center, spacing: 4) {
            Image(systemName: self.entry.isDefault ? "person.circle.fill" : "person.circle")
                .imageScale(.small)
                .foregroundStyle(MenuHighlightStyle.secondary(self.isHighlighted))

            Text(self.entry.label)
                .font(.footnote)
                .foregroundStyle(MenuHighlightStyle.primary(self.isHighlighted))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: Self.nameWidth, alignment: .leading)

            if self.entry.error == nil {
                if self.entry.isUnlimited {
                    self.planBadge("Unlimited")
                        .frame(width: Self.badgeWidth, alignment: .leading)
                } else if let plan = self.entry.planType {
                    self.planBadge(plan)
                        .frame(width: Self.badgeWidth, alignment: .leading)
                } else {
                    Spacer()
                        .frame(width: Self.badgeWidth)
                }
            } else {
                Spacer()
                    .frame(width: Self.badgeWidth)
            }

            // Right columns: Session | Weekly
            if let error = self.entry.error {
                Text(self.shortError(error))
                    .font(.caption2)
                    .foregroundStyle(MenuHighlightStyle.error(self.isHighlighted))
                    .frame(width: Self.colWidth * 3 + 16, alignment: .trailing)
            } else {
                self.percentCell(
                    usedPercent: self.entry.primaryUsedPercent,
                    resetDescription: self.entry.primaryResetDescription)
                self.percentCell(
                    usedPercent: self.entry.secondaryUsedPercent,
                    resetDescription: self.entry.secondaryResetDescription)
                self.creditsCell()
            }
        }
    }

    private static let pctWidth: CGFloat = 30

    @ViewBuilder
    private func creditsCell() -> some View {
        if self.entry.isUnlimited {
            Text("∞")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(MenuHighlightStyle.secondary(self.isHighlighted))
                .frame(width: Self.colWidth, alignment: .trailing)
        } else if let balance = self.entry.creditsRemaining, balance > 0 {
            let isLow = balance < 5
            Text(UsageFormatter.creditsBalanceString(from: balance))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(isLow ? Color.orange : MenuHighlightStyle.secondary(self.isHighlighted))
                .frame(width: Self.colWidth, alignment: .trailing)
        } else {
            Text("—")
                .font(.caption2)
                .foregroundStyle(MenuHighlightStyle.secondary(self.isHighlighted).opacity(0.5))
                .frame(width: Self.colWidth, alignment: .trailing)
        }
    }

    @ViewBuilder
    private func percentCell(usedPercent: Double?, resetDescription: String?) -> some View {
        if let used = usedPercent {
            let remaining = max(0, 100 - used)
            let isLow = remaining < 20
            let pctColor: Color = isLow ? .orange : MenuHighlightStyle.secondary(self.isHighlighted)
            HStack(alignment: .firstTextBaseline, spacing: 1) {
                Text(String(format: "%.0f%%", remaining))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(pctColor)
                    .frame(width: Self.pctWidth, alignment: .leading)
                if let reset = resetDescription {
                    Text(reset)
                        .font(.system(size: 9).monospacedDigit())
                        .foregroundStyle(pctColor.opacity(0.65))
                }
            }
            .frame(width: Self.colWidth, alignment: .leading)
        } else {
            Text("—")
                .font(.caption2)
                .foregroundStyle(MenuHighlightStyle.secondary(self.isHighlighted).opacity(0.5))
                .frame(width: Self.colWidth, alignment: .leading)
        }
    }

    private func planBadge(_ text: String) -> some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .foregroundStyle(MenuHighlightStyle.secondary(self.isHighlighted))
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(MenuHighlightStyle.secondary(self.isHighlighted).opacity(0.12)))
    }

    private func shortError(_ error: String) -> String {
        if error.contains("not found") || error.contains("notFound") { return "Not signed in" }
        if error.contains("unauthorized") || error.contains("401") { return "Token expired" }
        return "Error"
    }
}
