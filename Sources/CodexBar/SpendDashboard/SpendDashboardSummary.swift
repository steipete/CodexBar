import CodexBarCore
import SwiftUI

struct SpendDashboardSummary: View {
    let group: SpendDashboardModel.CurrencyGroup
    var caption: String?
    let onClearSelectedDay: (() -> Void)?

    init(
        group: SpendDashboardModel.CurrencyGroup,
        caption: String? = nil,
        onClearSelectedDay: (() -> Void)?)
    {
        self.group = group
        self.caption = caption
        self.onClearSelectedDay = onClearSelectedDay
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                self.hero
                Spacer(minLength: 0)
                self.selectedDayControl
            }

            HStack(alignment: .top, spacing: 16) {
                SpendSummaryValue(
                    title: L("Tracked tokens"),
                    value: spendDashboardGroupTokenText(self.group))
                if let metered = self.group.meteredCost {
                    Divider()
                    SpendSummaryValue(
                        title: L("Plan metered"),
                        value: UsageFormatter.currencyString(metered, currencyCode: self.group.currencyCode))
                }
                Divider()
                SpendSummaryValue(
                    title: spendDashboardProviderCountTitle(self.group),
                    value: codexBarLocalizedInteger(self.group.providers.count))
            }
            .fixedSize(horizontal: false, vertical: true)

            if spendDashboardHasTokenMix(self.group) {
                Divider()
                SpendTokenMixValues(mix: self.group.tokenMix)
            }

            Text(
                "\(spendDashboardCoverageChipText(self.group.coverage)) · "
                    + spendDashboardProvenanceText(self.group.provenance))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var hero: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(L("Estimated spend"))
                .font(.subheadline)
                .foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(self.group.totalCost == nil ? "—" : spendDashboardGroupCostText(self.group))
                    .font(.system(size: 34, weight: .semibold))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .contentTransition(.numericText())
                Text(self.group.currencyCode)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            if let caption {
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
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
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help(L("Clear"))
                    .accessibilityIdentifier("spend-dashboard-clear-selected-day")
                }
            }
            .font(.caption.weight(.medium))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(.tint.opacity(0.14), in: Capsule())
            .fixedSize()
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
                .lineLimit(1)
            Text(self.value)
                .font(.title3.weight(.semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

private struct SpendTokenMixValues: View {
    let mix: CostUsageTokenMix

    private struct Segment: Identifiable {
        let id: String
        let title: String
        let tokens: Int?
        let color: Color
    }

    private var segments: [Segment] {
        [
            Segment(id: "input", title: L("Input"), tokens: self.mix.inputTokens, color: .blue),
            Segment(id: "output", title: L("Output"), tokens: self.mix.outputTokens, color: .green),
            Segment(id: "cacheRead", title: L("Cache read"), tokens: self.mix.cacheReadTokens, color: .teal),
            Segment(id: "cacheWrite", title: L("Cache write"), tokens: self.mix.cacheCreationTokens, color: .orange),
            Segment(id: "reasoning", title: L("Reasoning"), tokens: self.mix.reasoningTokens, color: .purple),
        ]
    }

    var body: some View {
        let segments = self.segments
        VStack(alignment: .leading, spacing: 10) {
            Text(L("Tokens"))
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)

            // Cache and reasoning counters can overlap input and output; keep them separate.
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 100, maximum: 160), spacing: 12)],
                alignment: .leading,
                spacing: 8)
            {
                ForEach(segments) { segment in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Circle()
                            .fill(segment.color)
                            .frame(width: 7, height: 7)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(segment.title)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Text(spendDashboardTokenMixValue(segment.tokens))
                                .font(.subheadline.weight(.medium))
                                .monospacedDigit()
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }
}
