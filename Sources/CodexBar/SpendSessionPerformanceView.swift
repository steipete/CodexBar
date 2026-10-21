import CodexBarCore
import SwiftUI

struct SpendSessionPerformanceView: View {
    let summary: CostUsageTurnPerformanceSummary
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SpendPerformanceMetricStrip(metrics: spendSessionPerformanceMetrics(self.summary))
                .help(L("spend_turn_performance_help"))
            DisclosureGroup(isExpanded: self.$expanded) {
                SpendSessionPerformanceDetailsView(summary: self.summary)
            } label: {
                HStack {
                    Text(L("Performance details"))
                    Spacer()
                    Text(L("spend_performance_turn_count", codexBarLocalizedInteger(self.summary.sampleCount)))
                        .monospacedDigit()
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

struct SpendPerformanceMetric: Identifiable, Equatable {
    let id: String
    let label: String
    let value: String
    var note: String?
    var help: String?
}

private struct SpendPerformanceMetricStrip: View {
    let metrics: [SpendPerformanceMetric]

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 18) {
                ForEach(self.metrics) { metric in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(metric.label).font(.caption).foregroundStyle(.secondary)
                        Text(metric.value)
                            .font(.system(.body, design: .rounded, weight: .semibold))
                            .foregroundStyle(.primary)
                        if let note = metric.note {
                            Text(note).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    .fixedSize()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .help(metric.help ?? "")
                    .accessibilityElement(children: .combine)
                }
            }
            VStack(spacing: 6) {
                ForEach(self.metrics) { metric in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(metric.label).foregroundStyle(.secondary)
                            Spacer(minLength: 12)
                            Text(metric.value).fontWeight(.semibold).foregroundStyle(.primary)
                        }
                        if let note = metric.note {
                            Text(note).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    .font(.caption)
                    .help(metric.help ?? "")
                    .accessibilityElement(children: .combine)
                }
            }
        }
        .monospacedDigit()
    }
}

struct SpendSessionPerformanceDetailsView: View {
    let summary: CostUsageTurnPerformanceSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), alignment: .topLeading), count: 2),
                alignment: .leading,
                spacing: 10)
            {
                ForEach(spendSessionPerformanceDetailMetrics(self.summary)) { metric in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(metric.label).foregroundStyle(.secondary)
                        Text(metric.value).fontWeight(.medium).foregroundStyle(.primary)
                        if let note = metric.note {
                            Text(note).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .help(metric.help ?? "")
                    .accessibilityElement(children: .combine)
                }
            }
            Divider()
            HStack(spacing: 6) {
                Text(L("By model and reasoning effort"))
                    .fontWeight(.medium)
                    .foregroundStyle(.primary)
                Image(systemName: "info.circle")
                    .foregroundStyle(.secondary)
                    .help(L("Observed turns; workload and tools affect these results.") + "\n" +
                        L("Model first token may be reasoning, before visible answer text."))
                    .accessibilityLabel(L("spend_performance_metric_help"))
                    .accessibilityHint(L("Observed turns; workload and tools affect these results.") + "\n" +
                        L("Model first token may be reasoning, before visible answer text."))
            }
            SpendPerformanceModelComparison(groups: self.summary.details.groups)
        }
        .padding(.top, 8)
        .font(.caption)
        .monospacedDigit()
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct SpendPerformanceModelComparison: View {
    let groups: [CostUsageTurnPerformanceDetails.Group]

    var body: some View {
        ViewThatFits(in: .horizontal) {
            self.table
            self.compactRows
        }
    }

    private var table: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
            GridRow {
                Text(L("spend_performance_model_effort"))
                Text(L("spend_performance_turns"))
                Text(L("spend_performance_first_token"))
                Text(L("spend_performance_output") + " (tok/s)")
                Text(L("spend_performance_duration"))
            }
            .foregroundStyle(.secondary)
            .font(.caption2)
            .fixedSize()
            ForEach(Array(self.groups.enumerated()), id: \.offset) { _, group in
                GridRow(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(group.model ?? L("Unknown model"))
                            .fontWeight(.medium)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(group.reasoningEffort ?? L("Unknown reasoning effort"))
                            .foregroundStyle(.secondary)
                            .font(.caption2)
                    }
                    .frame(minWidth: 68, maxWidth: 145, alignment: .leading)
                    Text(codexBarLocalizedInteger(group.sampleCount))
                        .gridColumnAlignment(.trailing)
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(spendPerformanceSeconds(group.medianFirstTokenMilliseconds))
                        if group.firstTokenSampleCount < group.sampleCount {
                            Text(codexBarLocalizedInteger(group.firstTokenSampleCount) + "/" +
                                codexBarLocalizedInteger(group.sampleCount))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .gridColumnAlignment(.trailing)
                    .help(spendPerformanceFirstTokenCoverage(group))
                    Text(spendPerformanceNumber(group.outputTokensPerSecond))
                        .gridColumnAlignment(.trailing)
                    Text(spendPerformanceSeconds(group.medianDurationMilliseconds))
                        .gridColumnAlignment(.trailing)
                }
                .foregroundStyle(.primary)
            }
        }
    }

    private var compactRows: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(self.groups.enumerated()), id: \.offset) { _, group in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(group.model ?? L("Unknown model"))
                            .fontWeight(.medium)
                            .foregroundStyle(.primary)
                        Text(group.reasoningEffort ?? L("Unknown reasoning effort"))
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 4)
                        Text(L("spend_performance_turn_count", codexBarLocalizedInteger(group.sampleCount)))
                            .foregroundStyle(.secondary)
                    }
                    SpendPerformanceMetricStrip(metrics: spendPerformanceGroupMetrics(group))
                }
            }
        }
    }
}

func spendSessionPerformanceMetrics(_ summary: CostUsageTurnPerformanceSummary) -> [SpendPerformanceMetric] {
    let firstTokenCoverage = L(
        "First-token samples: %@ / %@",
        codexBarLocalizedInteger(summary.firstTokenSampleCount),
        codexBarLocalizedInteger(summary.sampleCount))
    return [
        SpendPerformanceMetric(
            id: "first-token",
            label: L("spend_performance_first_token"),
            value: spendPerformanceSeconds(summary.medianFirstTokenMilliseconds),
            note: firstTokenCoverage,
            help: firstTokenCoverage + "\n" +
                L("Model first token may be reasoning, before visible answer text.")),
        SpendPerformanceMetric(
            id: "output",
            label: L("spend_performance_output"),
            value: L("spend_performance_rate", spendPerformanceNumber(summary.outputTokensPerSecond))),
        SpendPerformanceMetric(
            id: "duration",
            label: L("spend_performance_duration"),
            value: spendPerformanceSeconds(summary.medianDurationMilliseconds)),
        SpendPerformanceMetric(
            id: "cached-input",
            label: L("spend_performance_cached_input"),
            value: summary.details.cachedInputFraction.map {
                L("spend_performance_percent", spendPerformanceNumber($0 * 100))
            } ?? "—",
            note: L(
                "spend_performance_coverage",
                codexBarLocalizedInteger(summary.details.cacheSampleCount),
                codexBarLocalizedInteger(summary.sampleCount)),
            help: L("spend_performance_cache_help")),
    ]
}

func spendSessionPerformanceDetailMetrics(_ summary: CostUsageTurnPerformanceSummary) -> [SpendPerformanceMetric] {
    let details = summary.details
    return [
        SpendPerformanceMetric(
            id: "p95-first-token",
            label: L("spend_performance_p95_first_token"),
            value: spendPerformanceSeconds(details.p95FirstTokenMilliseconds),
            note: details.p95FirstTokenMilliseconds == nil ?
                L("spend_performance_p95_samples", codexBarLocalizedInteger(summary.firstTokenSampleCount)) : nil,
            help: L("spend_performance_p95_help")),
        SpendPerformanceMetric(
            id: "p95-duration",
            label: L("spend_performance_p95_duration"),
            value: spendPerformanceSeconds(details.p95DurationMilliseconds),
            note: details.p95DurationMilliseconds == nil ?
                L("spend_performance_p95_samples", codexBarLocalizedInteger(summary.sampleCount)) : nil,
            help: L("spend_performance_p95_help")),
        SpendPerformanceMetric(
            id: "speed-range",
            label: L("spend_performance_speed_range"),
            value: details.outputRateLowerQuartile.flatMap { lower in
                details.outputRateUpperQuartile.map { upper in
                    L("spend_performance_rate_range", spendPerformanceNumber(lower), spendPerformanceNumber(upper))
                }
            } ?? "—",
            note: details.outputRateLowerQuartile == nil ? L("Speed range needs 4 completed turns.") : nil,
            help: L("spend_performance_speed_range_help")),
    ]
}

private func spendPerformanceGroupMetrics(_ group: CostUsageTurnPerformanceDetails.Group) -> [SpendPerformanceMetric] {
    [
        SpendPerformanceMetric(
            id: "first-token",
            label: L("spend_performance_first_token"),
            value: spendPerformanceSeconds(group.medianFirstTokenMilliseconds),
            help: spendPerformanceFirstTokenCoverage(group)),
        SpendPerformanceMetric(
            id: "output",
            label: L("spend_performance_output"),
            value: L("spend_performance_rate", spendPerformanceNumber(group.outputTokensPerSecond))),
        SpendPerformanceMetric(
            id: "duration",
            label: L("spend_performance_duration"),
            value: spendPerformanceSeconds(group.medianDurationMilliseconds)),
    ]
}

private func spendPerformanceFirstTokenCoverage(_ group: CostUsageTurnPerformanceDetails.Group) -> String {
    L(
        "First-token samples: %@ / %@",
        codexBarLocalizedInteger(group.firstTokenSampleCount),
        codexBarLocalizedInteger(group.sampleCount))
}

private func spendPerformanceSeconds(_ milliseconds: Double?) -> String {
    milliseconds.map { L("spend_performance_seconds", spendPerformanceNumber($0 / 1000)) } ?? "—"
}

private func spendPerformanceNumber(_ value: Double) -> String {
    value.formatted(.number.locale(codexBarLocalizedLocale()).precision(.fractionLength(1)))
}
