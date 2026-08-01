import Accessibility
import AppKit
import Charts
import CodexBarCore
import SwiftUI

enum CodexModelsColorRegistry {
    private static let tones: [Double] = [1.00, 0.90, 0.82, 0.74, 0.66, 0.58, 0.50]

    static func color(canonicalID: String, isSelected: Bool, isLeading: Bool = false) -> Color {
        if isSelected { return .accentColor }
        if isLeading { return .accentColor.opacity(0.72) }
        let hash = canonicalID.utf8.reduce(0) { (($0 << 5) &+ $0) &+ Int($1) }
        return .secondary.opacity(self.tones[abs(hash) % self.tones.count])
    }
}

struct CodexModelsAnalysis: View {
    let model: CodexModelsDashboardModel

    var body: some View {
        switch self.model.layout {
        case .wide:
            HStack(alignment: .top, spacing: 0) {
                CodexModelsRankingChart(model: self.model)
                    .frame(minWidth: 620, maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                VStack(spacing: 0) {
                    CodexModelsTimelineChart(model: self.model)
                        .frame(height: CodexModelsDashboardTokens.Height.wideTimeline)
                    Divider()
                    CodexModelsConcentrationView(model: self.model)
                        .frame(height: CodexModelsDashboardTokens.Height.wideConcentration)
                }
                .frame(width: CodexModelsDashboardTokens.Width.wideAnalysisTrailing)
            }
            .frame(height: CodexModelsDashboardTokens.Height.wideAnalysisBody)
        case .medium:
            VStack(spacing: 0) {
                CodexModelsRankingChart(model: self.model)
                    .frame(height: CodexModelsDashboardTokens.Height.mediumRanking)
                Divider()
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 0) {
                        CodexModelsTimelineChart(model: self.model)
                            .frame(minWidth: 540, maxWidth: .infinity, maxHeight: .infinity)
                        Divider()
                        CodexModelsConcentrationView(model: self.model)
                            .frame(
                                minWidth: 360,
                                maxWidth: CodexModelsDashboardTokens.Width.mediumConcentration,
                                maxHeight: .infinity)
                    }
                    .frame(minWidth: 917, maxWidth: .infinity)
                    .frame(height: CodexModelsDashboardTokens.Height.mediumAnalysisLower)
                    VStack(spacing: 0) {
                        CodexModelsTimelineChart(model: self.model)
                            .frame(height: CodexModelsDashboardTokens.Height.wideTimeline)
                        Divider()
                        CodexModelsConcentrationView(model: self.model)
                    }
                }
            }
        case .compact:
            VStack(spacing: 0) {
                CodexModelsRankingChart(model: self.model).frame(minHeight: 330)
                Divider()
                CodexModelsTimelineChart(model: self.model).frame(minHeight: 200)
                Divider()
                CodexModelsConcentrationView(model: self.model)
            }
        }
    }
}

private struct CodexModelsRankingChart: View {
    let model: CodexModelsDashboardModel

    var body: some View {
        let model = self.model
        let groups = model.rankingGroups
        let maximum = max(1, groups.map(\.value).max() ?? 1)
        let axis = self.axisScale(maximum: maximum)
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(L("codex_models_usage_by_model")).font(.subheadline.weight(.semibold))
                Text(L("codex_models_sorted_by", model.metric.analyticsNoun))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(groups.last?.isOther == true
                    ? L("codex_models_top_seven_other")
                    : L("codex_models_model_count", groups.count))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Chart(groups) { group in
                BarMark(
                    xStart: .value(L("codex_models_track_start"), 0),
                    xEnd: .value(L("codex_models_track_end"), axis.upperBound),
                    y: .value(L("codex_models_canonical_model"), group.id))
                    .foregroundStyle(Color.secondary.opacity(0.10))
                    .cornerRadius(CodexModelsDashboardTokens.Radius.chartBar)
                    .annotation(position: .trailing, alignment: .leading, spacing: 6) {
                        HStack(spacing: 4) {
                            Text(self.value(group))
                            Text(L("codex_models_bullet_value", CodexModelsFormatters.percentage(group.share)))
                                .foregroundStyle(.secondary)
                        }
                        .font(.caption2)
                        .monospacedDigit()
                    }
                    .accessibilityHidden(true)
                BarMark(
                    xStart: .value(L("codex_models_value_start"), 0),
                    xEnd: .value(model.metric.localizedTitle, group.value),
                    y: .value(L("codex_models_canonical_model"), group.id))
                    .foregroundStyle(self.color(group))
                    .cornerRadius(CodexModelsDashboardTokens.Radius.chartBar)
                    .accessibilityLabel(group.displayName)
                    .accessibilityValue(
                        L(
                            "codex_models_value_share_accessibility",
                            self.value(group),
                            CodexModelsFormatters.percentage(group.share))
                            + (self.isSelected(group) ? L("codex_models_selected_suffix") : ""))
            }
            .chartLegend(.hidden)
            .chartXScale(domain: 0...(axis.upperBound * 1.18))
            .chartXAxis {
                AxisMarks(position: .bottom, values: axis.ticks) { value in
                    AxisGridLine().foregroundStyle(.secondary.opacity(0.12))
                    AxisValueLabel {
                        if let number = value.as(Double.self) { Text(self.axisValue(number)) }
                    }
                }
            }
            .chartYAxis {
                AxisMarks(values: groups.map(\.id)) { value in
                    AxisValueLabel {
                        if let id = value.as(String.self), let group = groups.first(where: { $0.id == id }) {
                            HStack(spacing: 4) {
                                Text(group.displayName).lineLimit(1)
                                if model.topModel?.id == group.canonicalModelID {
                                    Text(L("codex_models_top"))
                                        .font(.caption2.weight(.semibold))
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
            .chartOverlay { proxy in
                GeometryReader { geometry in
                    let plotFrame = geometry[proxy.plotAreaFrame]
                    Rectangle()
                        .fill(.clear)
                        .contentShape(Rectangle())
                        .frame(width: plotFrame.width, height: plotFrame.height)
                        .position(x: plotFrame.midX, y: plotFrame.midY)
                        .gesture(
                            SpatialTapGesture(coordinateSpace: .local)
                                .onEnded { value in
                                    self.selectModel(
                                        at: value.location.y,
                                        proxy: proxy,
                                        groups: groups)
                                })
                }
            }
            .accessibilityChartDescriptor(CodexModelsRankingChartDescriptor(
                groups: groups,
                metric: model.metric,
                currencyCode: model.snapshot.cost.currencyCode))
        }
        .padding(CodexModelsDashboardTokens.Spacing.large)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L("codex_models_ranking_by", model.metric.localizedTitle))
        .accessibilityHint(L("codex_models_ranking_hint"))
    }

    private func selectModel(
        at yPosition: CGFloat,
        proxy: ChartProxy,
        groups: [CodexModelsVisualGroup])
    {
        guard let groupID = proxy.value(atY: yPosition, as: String.self),
              let group = groups.first(where: { $0.id == groupID }),
              let canonicalModelID = group.canonicalModelID
        else { return }
        self.model.selectModel(canonicalModelID)
    }

    private func color(_ group: CodexModelsVisualGroup) -> Color {
        if self.isSelected(group) { return .accentColor }
        guard let id = group.canonicalModelID else { return .secondary.opacity(0.42) }
        return CodexModelsColorRegistry.color(
            canonicalID: id,
            isSelected: false,
            isLeading: self.model.selectedModelID == nil && self.model.topModel?.id == id)
    }

    private func isSelected(_ group: CodexModelsVisualGroup) -> Bool {
        guard let selectedModelID = self.model.selectedModelID else { return false }
        return group.rows.contains { $0.id == selectedModelID }
    }

    private func value(_ group: CodexModelsVisualGroup) -> String {
        switch self.model.metric {
        case .tokens:
            return CodexModelsFormatters.compactInteger(Int64(group.value))
        case .knownCost:
            let cost = group.rows.reduce(CodexModelsCost.zero) { $0.adding($1.cost) }
            let tokens = group.rows.reduce(Int64.zero) { $0 + $1.totalTokens }
            return CodexModelsFormatters.cost(cost, usageTokens: tokens).primary
        case .sessionReferences:
            return Int(group.value).formatted()
        }
    }

    private func axisValue(_ value: Double) -> String {
        switch self.model.metric {
        case .tokens: CodexModelsFormatters.compactInteger(Int64(value))
        case .knownCost:
            CodexModelsFormatters.currency(
                Decimal(value),
                code: self.model.snapshot.cost.currencyCode,
                compact: true)
        case .sessionReferences: CodexModelsFormatters.compactNumber(value)
        }
    }

    private func axisScale(maximum: Double) -> (upperBound: Double, ticks: [Double]) {
        let rawStep = maximum / 4
        let exponent = pow(10, floor(log10(max(rawStep, .leastNonzeroMagnitude))))
        let normalized = rawStep / exponent
        let multiplier = if normalized <= 1 {
            1.0
        } else if normalized <= 2 {
            2.0
        } else if normalized <= 5 {
            5.0
        } else {
            10.0
        }
        let step = multiplier * exponent
        let upperBound = max(step, ceil(maximum / step) * step)
        return (upperBound, stride(from: 0, through: upperBound, by: step).map(\.self))
    }
}

private struct CodexModelsTimelineChart: View {
    let model: CodexModelsDashboardModel
    @State private var hoverSelectionTask: Task<Void, Never>?
    @State private var pendingHoverBucketStart: Date?

    var body: some View {
        let model = self.model
        let timeline = model.timelineData
        let buckets = timeline.buckets
        let plottedBuckets = timeline.plottedBuckets
        let presentation = timeline.presentation
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(model.selectedRow.map {
                    L("codex_models_named_metric_over_time", $0.displayName, model.metric.analyticsNoun)
                } ?? L("codex_models_metric_over_time", model.metric.localizedTitle))
                    .font(.subheadline.weight(.semibold))
                Text(L("codex_models_bucket_count", buckets.count, model.granularity.localizedTitle.lowercased()))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if timeline.inProgressBucket != nil {
                    Text(L("codex_models_current_period_in_progress", self.periodNoun))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if let changeFromPeak = timeline.changeFromPeak,
                          let peakBucket = timeline.peakBucket
                {
                    Text(L(
                        "codex_models_change_from_peak",
                        changeFromPeak.formatted(.percent.precision(.fractionLength(0...1))),
                        peakBucket.day.formatted(.dateTime.month(.abbreviated))))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if let selectedRow = model.selectedRow {
                HStack(spacing: 6) {
                    Label(selectedRow.displayName, systemImage: "checkmark.circle.fill")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(Color.accentColor)
                    Button(L("Clear")) {
                        model.selectModel(nil)
                        model.selectedBucketStart = nil
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(L("codex_models_selected_clear_available", selectedRow.displayName))
            }
            if case let .sparse(observedBuckets) = presentation {
                Text(L("codex_models_trend_unavailable_observed_buckets", observedBuckets))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Chart {
                if presentation == .trend {
                    ForEach(timeline.completedPlottedBuckets) { bucket in
                        AreaMark(
                            x: .value(L("codex_models_date"), bucket.day),
                            y: .value(model.metric.localizedTitle, self.metricValue(bucket)))
                            .foregroundStyle(.linearGradient(
                                colors: [self.seriesColor.opacity(0.10), self.seriesColor.opacity(0.01)],
                                startPoint: .top,
                                endPoint: .bottom))
                        LineMark(
                            x: .value(L("codex_models_date"), bucket.day),
                            y: .value(model.metric.localizedTitle, self.metricValue(bucket)))
                            .foregroundStyle(self.seriesColor)
                            .lineStyle(.init(lineWidth: 1.5))
                    }
                    if let bucket = timeline.inProgressBucket {
                        PointMark(
                            x: .value(L("codex_models_date"), bucket.day),
                            y: .value(model.metric.localizedTitle, self.metricValue(bucket)))
                            .foregroundStyle(self.seriesColor.opacity(0.45))
                            .symbolSize(42)
                        PointMark(
                            x: .value(L("codex_models_date"), bucket.day),
                            y: .value(model.metric.localizedTitle, self.metricValue(bucket)))
                            .foregroundStyle(Color(nsColor: .controlBackgroundColor))
                            .symbolSize(20)
                    }
                } else {
                    ForEach(plottedBuckets) { bucket in
                        BarMark(
                            x: .value(L("codex_models_date"), bucket.day),
                            y: .value(model.metric.localizedTitle, self.metricValue(bucket)),
                            width: .fixed(18))
                            .foregroundStyle(self.seriesColor.opacity(0.55))
                        PointMark(
                            x: .value(L("codex_models_date"), bucket.day),
                            y: .value(model.metric.localizedTitle, self.metricValue(bucket)))
                            .foregroundStyle(self.seriesColor)
                            .symbolSize(36)
                    }
                }
                if let bucket = timeline.selectedBucket,
                   model.metric != .knownCost || bucket.cost.pricedTokens > 0
                {
                    PointMark(
                        x: .value(L("codex_models_selected_date"), bucket.day),
                        y: .value(model.metric.localizedTitle, self.metricValue(bucket)))
                        .foregroundStyle(self.seriesColor)
                        .symbolSize(44)
                }
                if let bucket = timeline.selectedBucket,
                   model.metric != .knownCost || bucket.cost.pricedTokens > 0
                {
                    RuleMark(x: .value(L("codex_models_selected_bucket"), bucket.day))
                        .foregroundStyle(.secondary)
                        .annotation(
                            position: .top,
                            alignment: bucket.day == plottedBuckets.last?.day ? .trailing : .leading)
                        {
                            self.bucketPopover(bucket)
                        }
                }
            }
            .chartLegend(.hidden)
            .chartYAxis {
                AxisMarks(position: .leading) { value in
                    AxisGridLine().foregroundStyle(.secondary.opacity(0.12))
                    AxisValueLabel {
                        if let number = value.as(Double.self) { Text(self.axisValue(number)) }
                    }
                }
            }
            .chartOverlay { proxy in
                GeometryReader { geometry in
                    let plotFrame = geometry[proxy.plotAreaFrame]
                    Rectangle()
                        .fill(.clear)
                        .contentShape(Rectangle())
                        .frame(width: plotFrame.width, height: plotFrame.height)
                        .position(x: plotFrame.midX, y: plotFrame.midY)
                        .gesture(
                            SpatialTapGesture(coordinateSpace: .local)
                                .onEnded { value in
                                    self.commitSelection(
                                        at: value.location.x,
                                        proxy: proxy,
                                        timeline: timeline)
                                })
                        .onContinuousHover(coordinateSpace: .local) { phase in
                            switch phase {
                            case let .active(location):
                                self.scheduleHoverSelection(
                                    at: location.x,
                                    proxy: proxy,
                                    timeline: timeline)
                            case .ended:
                                self.cancelHoverSelection()
                            }
                        }
                }
            }
            .accessibilityChartDescriptor(CodexModelsTimelineChartDescriptor(
                buckets: buckets,
                metric: model.metric,
                granularity: model.granularity,
                currencyCode: model.snapshot.cost.currencyCode,
                selectedModelName: model.selectedRow?.displayName,
                selectedBucket: timeline.selectedBucket))
            .frame(minHeight: 145)
        }
        .padding(CodexModelsDashboardTokens.Spacing.large)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L(
            "codex_models_timeline_accessibility",
            model.granularity.localizedTitle,
            model.metric.localizedTitle))
        .accessibilityHint(L("codex_models_timeline_hint"))
        .onDisappear { self.cancelHoverSelection() }
    }

    private func commitSelection(
        at xPosition: CGFloat,
        proxy: ChartProxy,
        timeline: CodexModelsTimelineData)
    {
        self.cancelHoverSelection()
        guard let date = proxy.value(atX: xPosition, as: Date.self) else { return }
        self.model.selectedBucketStart = timeline.selectionStart(nearest: date)
    }

    private func scheduleHoverSelection(
        at xPosition: CGFloat,
        proxy: ChartProxy,
        timeline: CodexModelsTimelineData)
    {
        let bucketStart = proxy.value(atX: xPosition, as: Date.self)
            .flatMap { timeline.selectionStart(nearest: $0) }
        guard self.pendingHoverBucketStart != bucketStart else { return }

        self.hoverSelectionTask?.cancel()
        self.pendingHoverBucketStart = bucketStart
        guard let bucketStart else { return }

        self.hoverSelectionTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled, self.pendingHoverBucketStart == bucketStart else { return }
            self.model.selectedBucketStart = bucketStart
            self.hoverSelectionTask = nil
        }
    }

    private func cancelHoverSelection() {
        self.hoverSelectionTask?.cancel()
        self.hoverSelectionTask = nil
        self.pendingHoverBucketStart = nil
    }

    private func bucketPopover(_ bucket: CodexModelsDailyBucket) -> some View {
        let cost = CodexModelsFormatters.cost(bucket.cost, usageTokens: bucket.tokens)
        return VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(CodexModelsFormatters.interval(bucket.effectiveInterval)).fontWeight(.semibold)
                Spacer(minLength: 8)
                Button(L("Close"), systemImage: "xmark") { self.model.selectedBucketStart = nil }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.plain)
            }
            Text(L("codex_models_token_count", bucket.tokens.formatted()))
            Text(L("codex_models_session_reference_count", bucket.sessionReferences.formatted()))
            Text(L(
                "codex_models_cost_status_currency",
                cost.primary,
                cost.secondary ?? L("codex_models_fully_priced"),
                bucket.cost.currencyCode))
        }
        .font(.caption2)
        .monospacedDigit()
        .padding(CodexModelsDashboardTokens.Spacing.medium)
        .frame(width: 225, alignment: .leading)
        .background(
            .regularMaterial,
            in: RoundedRectangle(
                cornerRadius: CodexModelsDashboardTokens.Radius.tooltip,
                style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: CodexModelsDashboardTokens.Radius.tooltip, style: .continuous)
                .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
    }

    private var seriesColor: Color {
        self.model.selectedRow == nil ? .accentColor.opacity(0.78) : .accentColor
    }

    private var periodNoun: String {
        switch self.model.granularity {
        case .daily: L("codex_models_day_lowercase")
        case .weekly: L("codex_models_week_lowercase")
        case .monthly: L("codex_models_month_lowercase")
        }
    }

    private func metricValue(_ bucket: CodexModelsDailyBucket) -> Double {
        switch self.model.metric {
        case .tokens: Double(bucket.tokens)
        case .knownCost: NSDecimalNumber(decimal: bucket.cost.knownAmount).doubleValue
        case .sessionReferences: Double(bucket.sessionReferences)
        }
    }

    private func axisValue(_ value: Double) -> String {
        switch self.model.metric {
        case .tokens: CodexModelsFormatters.compactInteger(Int64(value))
        case .knownCost:
            CodexModelsFormatters.currency(
                Decimal(value),
                code: self.model.snapshot.cost.currencyCode,
                compact: true)
        case .sessionReferences: CodexModelsFormatters.compactNumber(value)
        }
    }
}

private struct CodexModelsConcentrationView: View {
    let model: CodexModelsDashboardModel

    var body: some View {
        let concentration = self.model.concentrationData
        let groups = concentration.groups
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(L("codex_models_model_concentration")).font(.subheadline.weight(.semibold))
                Text(L("codex_models_share_of", self.model.metric.shareBasisTitle))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 14) {
                    self.insight(topTwoShare: concentration.topTwoShare).frame(width: 112, alignment: .leading)
                    self.distribution(groups)
                }
                .frame(minWidth: 350)
                VStack(alignment: .leading, spacing: 8) {
                    self.insight(topTwoShare: concentration.topTwoShare)
                    self.distribution(groups)
                }
            }
        }
        .padding(CodexModelsDashboardTokens.Spacing.large)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L("codex_models_model_concentration"))
        .accessibilityValue(self.headline(topTwoShare: concentration.topTwoShare))
    }

    private func headline(topTwoShare: Double) -> String {
        let share = CodexModelsFormatters.percentage(topTwoShare)
        return L("codex_models_top_two_account_for", share, self.model.metric.analyticsNoun)
    }

    private func insight(topTwoShare: Double) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(CodexModelsFormatters.percentage(topTwoShare))
                .font(.title2.weight(.semibold))
                .monospacedDigit()
            Text(L("codex_models_top_two_of", self.model.metric.shareBasisTitle))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func distribution(_ groups: [CodexModelsVisualGroup]) -> some View {
        VStack(spacing: 7) {
            GeometryReader { proxy in
                let gaps = CGFloat(max(0, groups.count - 1))
                let availableWidth = max(0, proxy.size.width - gaps)
                HStack(spacing: 1) {
                    ForEach(groups) { group in
                        self.segment(group)
                            .frame(width: max(0, availableWidth * group.share))
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 4))
            }
            .frame(height: 18)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 8)], spacing: 2) {
                ForEach(groups) { group in
                    self.legendItem(group)
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func segment(_ group: CodexModelsVisualGroup) -> some View {
        if let id = group.canonicalModelID {
            Button { self.model.selectModel(id) } label: {
                Rectangle().fill(self.color(group))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L("codex_models_select_model", group.displayName))
            .accessibilityValue(CodexModelsFormatters.percentage(group.share))
        } else {
            Rectangle()
                .fill(self.color(group))
                .accessibilityLabel(group.displayName)
                .accessibilityValue(
                    CodexModelsFormatters.percentage(group.share)
                        + (self.isSelected(group) ? L("codex_models_contains_selected_suffix") : ""))
        }
    }

    private func color(_ group: CodexModelsVisualGroup) -> Color {
        if self.isSelected(group) { return .accentColor }
        guard let id = group.canonicalModelID else { return .secondary.opacity(0.42) }
        return CodexModelsColorRegistry.color(
            canonicalID: id,
            isSelected: false,
            isLeading: self.model.selectedModelID == nil && self.model.topModel?.id == id)
    }

    private func isSelected(_ group: CodexModelsVisualGroup) -> Bool {
        guard let selectedModelID = self.model.selectedModelID else { return false }
        return group.rows.contains { $0.id == selectedModelID }
    }

    private func legendItem(_ group: CodexModelsVisualGroup) -> some View {
        Group {
            if let id = group.canonicalModelID {
                Button { self.model.selectModel(id) } label: { self.legendLabel(group) }
                    .buttonStyle(.plain)
            } else {
                self.legendLabel(group)
            }
        }
        .frame(minHeight: 28)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(L(
            "codex_models_name_value_accessibility",
            group.displayName,
            CodexModelsFormatters.percentage(group.share)))
    }

    private func legendLabel(_ group: CodexModelsVisualGroup) -> some View {
        HStack(spacing: 7) {
            RoundedRectangle(cornerRadius: 2)
                .fill(self.color(group))
                .frame(width: 12, height: 12)
            Text(group.displayName).lineLimit(1)
            Spacer(minLength: 4)
            Text(CodexModelsFormatters.percentage(group.share)).monospacedDigit()
        }
        .font(.caption)
        .contentShape(Rectangle())
    }
}

private struct CodexModelsRankingChartDescriptor: AXChartDescriptorRepresentable {
    let groups: [CodexModelsVisualGroup]
    let metric: CodexModelsMetric
    let currencyCode: String

    func makeChartDescriptor() -> AXChartDescriptor {
        let upperBound = max(1, self.groups.map(\.value).max() ?? 1)
        let categories = self.groups.map(self.identity)
        let modelAxis = AXCategoricalDataAxisDescriptor(
            title: L("codex_models_canonical_model"),
            categoryOrder: categories)
        let valueAxis = AXNumericDataAxisDescriptor(
            title: self.metric.localizedTitle,
            range: 0...upperBound,
            gridlinePositions: []) { self.axisDescription($0) }
        let points = zip(self.groups, categories).map { group, identity in
            let share = CodexModelsFormatters.percentage(group.share)
            return AXDataPoint(
                x: identity,
                y: group.value,
                label: L("codex_models_ranking_point_accessibility", identity, self.description(group), share))
        }
        return AXChartDescriptor(
            title: L("codex_models_usage_by_model"),
            summary: L("codex_models_ranking_summary", self.metric.analyticsNoun),
            xAxis: modelAxis,
            yAxis: valueAxis,
            series: [AXDataSeriesDescriptor(
                name: self.metric.localizedTitle,
                isContinuous: false,
                dataPoints: points)])
    }

    private func identity(_ group: CodexModelsVisualGroup) -> String {
        group.canonicalModelID.map { L("codex_models_name_canonical_id", group.displayName, $0) }
            ?? group.displayName
    }

    private func axisDescription(_ value: Double) -> String {
        switch self.metric {
        case .tokens: L("codex_models_token_count", Int64(value).formatted())
        case .knownCost: value.formatted(.currency(code: self.currencyCode))
        case .sessionReferences: L("codex_models_session_reference_count", Int(value).formatted())
        }
    }

    private func description(_ group: CodexModelsVisualGroup) -> String {
        switch self.metric {
        case .tokens: return L("codex_models_token_count", Int64(group.value).formatted())
        case .knownCost:
            let cost = group.rows.reduce(CodexModelsCost.zero) { $0.adding($1.cost) }
            let tokens = group.rows.reduce(Int64.zero) { $0 + $1.totalTokens }
            return CodexModelsFormatters.cost(cost, usageTokens: tokens).accessibility
        case .sessionReferences: return L("codex_models_session_reference_count", Int(group.value).formatted())
        }
    }
}

private struct CodexModelsTimelineChartDescriptor: AXChartDescriptorRepresentable {
    let buckets: [CodexModelsDailyBucket]
    let metric: CodexModelsMetric
    let granularity: CodexModelsGranularity
    let currencyCode: String
    let selectedModelName: String?
    let selectedBucket: CodexModelsDailyBucket?

    func makeChartDescriptor() -> AXChartDescriptor {
        let describedBuckets = self.buckets.filter { self.metric != .knownCost || $0.cost.pricedTokens > 0 }
        let dates = describedBuckets.map(\.day.timeIntervalSinceReferenceDate)
        let lowerBound = dates.min() ?? 0
        let upperBound = max(lowerBound + 1, dates.max() ?? 1)
        let values = describedBuckets.map(self.value)
        let dateAxis = AXNumericDataAxisDescriptor(
            title: L("codex_models_bucket_interval"),
            range: lowerBound...upperBound,
            gridlinePositions: [])
        {
            Date(timeIntervalSinceReferenceDate: $0).formatted(date: .abbreviated, time: .omitted)
        }
        let valueAxis = AXNumericDataAxisDescriptor(
            title: self.metric.localizedTitle,
            range: 0...max(1, values.max() ?? 1),
            gridlinePositions: []) { self.description($0) }
        let points = zip(describedBuckets, values).map { bucket, value in
            let interval = CodexModelsFormatters.interval(bucket.effectiveInterval)
            let metricValue = CodexModelsFormatters.metricValue(bucket, metric: self.metric)
            let cost = CodexModelsFormatters.cost(bucket.cost, usageTokens: bucket.tokens)
            return AXDataPoint(
                x: bucket.day.timeIntervalSinceReferenceDate,
                y: value,
                label: L(
                    "codex_models_timeline_point_accessibility",
                    interval,
                    metricValue,
                    bucket.tokens.formatted(),
                    bucket.sessionReferences.formatted(),
                    cost.accessibility,
                    bucket.cost.currencyCode))
        }
        let subject = self.selectedModelName ?? L("codex_models_all_models")
        let selection = self.selectedBucket.map {
            let interval = CodexModelsFormatters.interval($0.effectiveInterval)
            let metricValue = CodexModelsFormatters.metricValue($0, metric: self.metric)
            let cost = CodexModelsFormatters.cost($0.cost, usageTokens: $0.tokens)
            return L(
                "codex_models_selected_bucket_accessibility",
                interval,
                metricValue,
                $0.tokens.formatted(),
                $0.sessionReferences.formatted(),
                cost.accessibility,
                $0.cost.currencyCode)
        } ?? ""
        return AXChartDescriptor(
            title: L("codex_models_subject_over_time", subject),
            summary: L(
                "codex_models_timeline_summary",
                self.granularity.localizedTitle,
                self.metric.analyticsNoun,
                selection),
            xAxis: dateAxis,
            yAxis: valueAxis,
            series: [AXDataSeriesDescriptor(
                name: subject,
                isContinuous: describedBuckets.count >= 3,
                dataPoints: points)])
    }

    private func value(_ bucket: CodexModelsDailyBucket) -> Double {
        switch self.metric {
        case .tokens: Double(bucket.tokens)
        case .knownCost: NSDecimalNumber(decimal: bucket.cost.knownAmount).doubleValue
        case .sessionReferences: Double(bucket.sessionReferences)
        }
    }

    private func description(_ value: Double) -> String {
        switch self.metric {
        case .tokens: L("codex_models_token_count", Int64(value).formatted())
        case .knownCost: value.formatted(.currency(code: self.currencyCode))
        case .sessionReferences: L("codex_models_session_reference_count", Int(value).formatted())
        }
    }
}
