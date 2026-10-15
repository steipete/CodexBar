import Charts
import CodexBarCore
import SwiftUI

struct OpenAILiveUsageChart: View {
    let snapshot: OpenAILiveUsageSnapshot
    let filter: OpenAILiveUsageModelFilter
    var tpmLimit: Int?
    @State private var selectedMinute: Date?

    private struct Segment {
        let minute: Date
        let label: String
        let tokens: Int
        var baseline: Int = 0
    }

    var body: some View {
        if case let .model(name) = self.filter {
            self.chart
                .chartForegroundStyleScale(domain: self.modelSeriesNames)
                .chartLegend { Color.clear.frame(height: 12) }
                .chartOverlay(alignment: .bottomLeading) { proxy in
                    let style = proxy.foregroundStyle(for: self.seriesName(name)) ?? AnyShapeStyle(Color.blue)
                    HStack(spacing: 12) {
                        self.legendItem(L("Uncached input"), style: style)
                        self.legendItem(L("Cached input"), style: style, opacity: 0.45)
                        self.legendItem(L("Output"), style: AnyShapeStyle(Color.orange))
                    }
                    .font(.caption2)
                    .allowsHitTesting(false)
                }
        } else {
            self.chart
        }
    }

    private var chart: some View {
        Chart {
            if let pendingStart = self.pendingStart {
                RectangleMark(
                    xStart: .value(L("Minute"), pendingStart),
                    xEnd: .value(L("Minute"), self.domain.upperBound))
                    .foregroundStyle(Color.secondary.opacity(0.08))
                    .annotation(
                        position: .overlay,
                        alignment: .topTrailing,
                        overflowResolution: .init(x: .fit, y: .fit))
                    {
                        Text(L("reporting…")).font(.caption2).foregroundStyle(.secondary).fixedSize().padding(4)
                    }
            }
            ForEach(Array(self.segments.enumerated()), id: \.offset) { _, segment in
                if case let .model(name) = self.filter {
                    if segment.label == L("Output") {
                        self.bar(segment).foregroundStyle(.orange)
                    } else {
                        self.bar(segment)
                            .foregroundStyle(by: .value(L("Model"), self.seriesName(name)))
                            .opacity(segment.label == L("Cached input") ? 0.45 : 1)
                    }
                } else {
                    self.bar(segment).foregroundStyle(by: .value(L("Model"), segment.label))
                }
            }
            if let limit = self.tpmLimit, self.showsLimitRule {
                RuleMark(y: .value(L("Org TPM limit"), limit))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [5, 4]))
                    .foregroundStyle(.secondary)
                    .annotation(position: .top, alignment: .trailing) {
                        Text(L("Org limit %@ TPM", ProviderRateLimitNumber.format(limit))).font(.caption2)
                    }
            }
            if let point = self.selectedPoint {
                RuleMark(x: .value(L("Minute"), point.start.addingTimeInterval(30)))
                    .foregroundStyle(.secondary)
                    .annotation(position: .top, overflowResolution: .init(x: .fit, y: .fit)) {
                        self.tooltip(point)
                    }
            }
        }
        .chartXScale(domain: self.domain)
        .chartYScale(domain: .automatic(includesZero: true))
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 6)) {
                AxisGridLine()
                AxisValueLabel(format: .dateTime.hour().minute())
            }
        }
        .chartYAxis {
            AxisMarks { value in
                AxisGridLine()
                AxisTick()
                AxisValueLabel {
                    if let tokens = value.as(Int.self) {
                        Text(OpenAILiveUsageView.count(tokens))
                    }
                }
            }
        }
        .chartLegend(position: .bottom, alignment: .leading)
        .chartXSelection(value: self.$selectedMinute)
        .accessibilityLabel(L("Tokens per minute"))
        .overlay(alignment: .topLeading) {
            if let limit = self.tpmLimit, !self.showsLimitRule {
                Text(L("Org limit %@ TPM (off scale)", ProviderRateLimitNumber.format(limit)))
                    .font(.caption2).foregroundStyle(.secondary)
                    .padding(4)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 4))
                    .padding(.leading, 4)
            }
        }
    }

    private var showsLimitRule: Bool {
        guard let tpmLimit else { return false }
        return OpenAILiveUsageLimitsPolicy.showsRule(limit: tpmLimit, points: self.snapshot.series(for: self.filter))
    }

    private var segments: [Segment] {
        switch self.filter {
        case .allModels:
            let stacks = self.snapshot.stackedByModel()
            if stacks.isEmpty {
                return self.snapshot.series(for: .allModels).filter { !$0.isPending }.map {
                    Segment(minute: $0.start, label: L("All models"), tokens: 0)
                }
            }
            return stacks.filter { !$0.isPending }.map {
                Segment(
                    minute: $0.minute,
                    label: $0.modelOrOther == "Other" ? L("Other") : $0.modelOrOther,
                    tokens: $0.tokens)
            }
        case .model:
            return self.snapshot.series(for: self.filter).filter { !$0.isPending }.flatMap { point in
                [
                    Segment(
                        minute: point.start,
                        label: L("Uncached input"),
                        tokens: point.uncachedInputTokens),
                    Segment(
                        minute: point.start,
                        label: L("Output"),
                        tokens: point.outputTokens,
                        baseline: point.uncachedInputTokens),
                    Segment(
                        minute: point.start,
                        label: L("Cached input"),
                        tokens: point.cachedInputTokens,
                        baseline: point.uncachedInputTokens + point.outputTokens),
                ]
            }
        }
    }

    @ChartContentBuilder
    private func bar(_ segment: Segment) -> some ChartContent {
        if case .model = self.filter {
            // Keep cached input above the limit-counted stack, independent of chart series ordering.
            BarMark(
                x: .value(L("Minute"), segment.minute, unit: .minute),
                yStart: .value(L("Tokens"), segment.baseline),
                yEnd: .value(L("Tokens"), segment.baseline + segment.tokens),
                width: .ratio(1))
        } else {
            BarMark(
                x: .value(L("Minute"), segment.minute, unit: .minute),
                y: .value(L("Tokens"), segment.tokens),
                width: .ratio(1))
        }
    }

    private var modelSeriesNames: [String] {
        let names = self.snapshot.modelNames
        return Array(names.prefix(5)) + (names.count > 5 ? [L("Other")] : [])
    }

    private func seriesName(_ name: String) -> String {
        self.snapshot.modelNames.prefix(5).contains(name) ? name : L("Other")
    }

    private func legendItem(_ title: String, style: AnyShapeStyle, opacity: Double = 1) -> some View {
        HStack(spacing: 4) {
            Circle().fill(style).opacity(opacity).frame(width: 8, height: 8)
            Text(title).foregroundStyle(.secondary)
        }
    }

    private var pendingStart: Date? {
        self.snapshot.series(for: .allModels).first(where: \.isPending)?.start
    }

    private var domain: ClosedRange<Date> {
        let first = self.snapshot.minutes.first?.start ?? self.snapshot.fetchedAt
        let end = self.snapshot.minutes.last?.start.addingTimeInterval(60) ?? first.addingTimeInterval(60)
        return first...end
    }

    private var selectedPoint: OpenAILiveUsageSnapshot.Point? {
        guard let selectedMinute else { return nil }
        return self.snapshot.series(for: self.filter).first {
            $0.start <= selectedMinute && selectedMinute < $0.start.addingTimeInterval(60)
        }
    }

    private func tooltip(_ point: OpenAILiveUsageSnapshot.Point) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(point.start.formatted(date: .omitted, time: .shortened)).bold()
            if point.isPending {
                Text(L("reporting…"))
            } else {
                Text(L(
                    "%@ tokens · %@ requests",
                    OpenAILiveUsageView.count(point.totalTokens),
                    OpenAILiveUsageView.count(point.requests)))
                Text(L(
                    "Uncached input %@ · cached input %@ · output %@",
                    OpenAILiveUsageView.count(point.uncachedInputTokens),
                    OpenAILiveUsageView.count(point.cachedInputTokens),
                    OpenAILiveUsageView.count(point.outputTokens)))
                if point.batchTokens > 0 {
                    Text(L(
                        "Batch API %@ · not counted in %% of limit",
                        OpenAILiveUsageView.count(point.batchTokens)))
                }
                if self.filter == .allModels {
                    ForEach(
                        self.snapshot.minutes.first(where: { $0.start == point.start })?.models ?? [],
                        id: \.name)
                    { model in
                        Text("\(model.name): \(OpenAILiveUsageView.count(model.totalTokens))")
                    }
                }
            }
        }
        .font(.caption)
        .padding(8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }
}
