import SwiftUI

/// A single provider summary card, rendered as Liquid Glass.
struct ProviderCardView: View {
    let entry: WidgetSnapshot.ProviderEntry

    private var rows: [WidgetSnapshot.WidgetUsageRowSnapshot] {
        Array(self.entry.displayRows.prefix(3))
    }

    var body: some View {
        HStack(spacing: 14) {
            ProviderIconView(provider: self.entry.provider, size: 44)

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(self.entry.provider.displayName)
                        .font(.headline)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }

                if self.rows.isEmpty {
                    self.costOnlyLine
                } else {
                    ForEach(self.rows) { row in
                        HStack(spacing: 8) {
                            Text(row.title)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .frame(width: 62, alignment: .leading)
                            UsageBar(remainingPercent: row.percentLeft, height: 7)
                            Text(UsageFormat.percent(row.percentLeft))
                                .font(.caption.weight(.semibold).monospacedDigit())
                                .foregroundStyle(UsageTone.color(remainingPercent: row.percentLeft))
                                .frame(width: 40, alignment: .trailing)
                        }
                    }
                }
            }

            if let headline = self.entry.headlineRemainingPercent {
                UsageRing(remainingPercent: headline, lineWidth: 5)
                    .frame(width: 46, height: 46)
            }
        }
        .padding(16)
        .glassCard()
    }

    @ViewBuilder
    private var costOnlyLine: some View {
        if let token = self.entry.tokenUsage,
           let cost = UsageFormat.currency(token.sessionCostUSD, code: token.currencyCode)
        {
            HStack(spacing: 6) {
                Text(token.sessionLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(cost)
                    .font(.caption.weight(.semibold))
            }
        } else {
            Text("No usage windows")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }
}

extension View {
    /// Applies the standard Liquid Glass card treatment with a rounded rect shape.
    func glassCard(cornerRadius: CGFloat = 22) -> some View {
        self
            .glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
    }
}
