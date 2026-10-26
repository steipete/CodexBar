import CodexBarCore
import SwiftUI

struct SpendDashboardSummary: View {
    let group: SpendDashboardModel.CurrencyGroup
    let onClearSelectedDay: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 130, maximum: 220), spacing: 18)],
                alignment: .leading,
                spacing: 12)
            {
                SpendSummaryValue(
                    title: L("Estimated spend"),
                    value: self.group.totalCost == nil ? "—" : spendDashboardGroupCostText(self.group))
                SpendSummaryValue(
                    title: L("Tracked tokens"),
                    value: spendDashboardGroupTokenText(self.group))
                if let metered = self.group.meteredCost {
                    SpendSummaryValue(
                        title: L("Plan metered"),
                        value: UsageFormatter.currencyString(metered, currencyCode: self.group.currencyCode))
                }
                SpendSummaryValue(
                    title: spendDashboardProviderCountTitle(self.group),
                    value: codexBarLocalizedInteger(self.group.providers.count))
            }

            if spendDashboardHasTokenMix(self.group) {
                Divider()
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 92, maximum: 150), spacing: 14)],
                    alignment: .leading,
                    spacing: 10)
                {
                    SpendTokenMixValue(
                        title: L("Input"),
                        value: spendDashboardTokenMixValue(self.group.tokenMix.inputTokens))
                    SpendTokenMixValue(
                        title: L("Output"),
                        value: spendDashboardTokenMixValue(self.group.tokenMix.outputTokens))
                    SpendTokenMixValue(
                        title: L("Cache read"),
                        value: spendDashboardTokenMixValue(self.group.tokenMix.cacheReadTokens))
                    SpendTokenMixValue(
                        title: L("Cache write"),
                        value: spendDashboardTokenMixValue(self.group.tokenMix.cacheCreationTokens))
                    SpendTokenMixValue(
                        title: L("Reasoning"),
                        value: spendDashboardTokenMixValue(self.group.tokenMix.reasoningTokens))
                }
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    self.metadata
                    Spacer()
                    self.selectedDayControl
                }
                VStack(alignment: .leading, spacing: 8) {
                    self.metadata
                    self.selectedDayControl
                }
            }
        }
        .padding(.vertical, 2)
    }

    private var metadata: some View {
        Text(
            "\(spendDashboardCoverageChipText(self.group.coverage)) · "
                + spendDashboardProvenanceText(self.group.provenance))
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private var selectedDayControl: some View {
        if let selectedDay = self.group.selectedDay {
            HStack(spacing: 5) {
                Label(
                    SpendActivityDateFormatting.mediumDateString(selectedDay, calendar: self.group.calendar),
                    systemImage: "calendar")
                if let onClearSelectedDay {
                    Button {
                        onClearSelectedDay()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .help(L("Clear"))
                    .accessibilityIdentifier("spend-dashboard-clear-selected-day")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(.quaternary.opacity(0.5), in: Capsule())
        }
    }
}

private struct SpendSummaryValue: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(self.title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(self.value)
                .font(.system(.title2, design: .rounded, weight: .semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct SpendTokenMixValue: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(self.title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(self.value)
                .font(.subheadline.weight(.medium))
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
