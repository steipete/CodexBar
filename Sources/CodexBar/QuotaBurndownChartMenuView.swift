import Charts
import CodexBarCore
import SwiftUI

@MainActor
struct QuotaBurndownChartMenuView: View {
    private struct Series: Identifiable {
        let id: String
        let title: String
        let model: QuotaBurndownModel
        let lastKnownUsageMessage: String
    }

    private let series: [Series]
    private let width: CGFloat
    private let color: Color

    @State private var selectedSeriesID: String?

    init(
        provider: UsageProvider,
        histories: [PlanUtilizationSeriesHistory],
        width: CGFloat,
        referenceDate: Date = Date())
    {
        self.series = PlanUtilizationHistoryChartMenuView.visibleSeries(
            histories: histories, provider: provider, snapshot: nil).compactMap { series in
            let history = series.history
            guard [.session, .weekly, .monthly, .opus].contains(history.name),
                  let latest = history.entries.last,
                  let reset = latest.resetsAt,
                  latest.capturedAt <= referenceDate,
                  reset > referenceDate
            else { return nil }
            let window = ProviderDescriptorRegistry.descriptor(for: provider).pace.resolvedResetWindowForPace(
                RateWindow(
                    usedPercent: latest.usedPercent,
                    windowMinutes: history.windowMinutes,
                    resetsAt: reset,
                    resetDescription: nil))
            guard let model = QuotaBurndownModel(history: history, window: window, now: latest.capturedAt)
            else { return nil }
            return Series(
                id: series.id,
                title: series.title,
                model: model,
                lastKnownUsageMessage: LastKnownUsagePresentation.message(
                    capturedAt: latest.capturedAt,
                    now: referenceDate))
        }
        self.width = width
        let accent = ProviderAccentPalette.color(for: provider)
        self.color = Color(red: accent.red, green: accent.green, blue: accent.blue)
    }

    var body: some View {
        let selected = self.series.first(where: { $0.id == self.selectedSeriesID }) ?? self.series.first

        VStack(alignment: .leading, spacing: 10) {
            if self.series.count > 1 {
                Picker(selection: Binding(
                    get: { selected?.id ?? "" },
                    set: { self.selectedSeriesID = $0 }))
                {
                    ForEach(self.series) { series in
                        Text(series.title).tag(series.id)
                    }
                } label: {
                    EmptyView()
                }
                .labelsHidden()
                .pickerStyle(.segmented)
            }

            if let selected {
                Chart {
                    ForEach(selected.model.ideal, id: \.date) { point in
                        LineMark(
                            x: .value("Time", point.date),
                            y: .value(L("Usage remaining"), point.remainingPercent),
                            series: .value("Series", "Ideal"))
                            .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    }
                    ForEach(selected.model.samples, id: \.date) { point in
                        LineMark(
                            x: .value("Time", point.date),
                            y: .value(L("Usage remaining"), point.remainingPercent),
                            series: .value("Series", "Observed"))
                            .foregroundStyle(self.color)
                            .lineStyle(StrokeStyle(lineWidth: 2))
                    }
                    if let current = selected.model.samples.last {
                        PointMark(
                            x: .value("Time", current.date),
                            y: .value(L("Usage remaining"), current.remainingPercent))
                            .foregroundStyle(self.color)
                            .symbolSize(35)
                    }
                }
                .chartXScale(domain: selected.model.start...selected.model.reset)
                .chartYScale(domain: 0...100)
                .chartYAxis {
                    AxisMarks(values: [0, 50, 100])
                }
                .chartXAxis(.hidden)
                .chartLegend(.hidden)
                .frame(height: 130)
                .accessibilityLabel(L("Usage remaining"))

                HStack {
                    self.axisLabel(for: selected.model.start, model: selected.model, alignment: .leading)
                    Spacer()
                    self.axisLabel(for: selected.model.reset, model: selected.model, alignment: .trailing)
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                if let remaining = selected.model.samples.last?.remainingPercent {
                    Text("\(remaining.formatted(.number.precision(.fractionLength(0))))% \(L("Usage remaining"))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(selected.lastKnownUsageMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(L("No data"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 146)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(minWidth: self.width, maxWidth: .infinity, alignment: .topLeading)
        .codexBarLocalized()
    }

    var hasSeries: Bool {
        !self.series.isEmpty
    }

    private func axisLabel(
        for date: Date,
        model: QuotaBurndownModel,
        alignment: HorizontalAlignment) -> some View
    {
        VStack(alignment: alignment, spacing: 2) {
            if model.reset.timeIntervalSince(model.start) >= 86400 {
                Text(date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()
                        .locale(codexBarLocalizedLocale())))
            }
            Text(date.formatted(.dateTime.hour().minute().locale(codexBarLocalizedLocale())))
        }
        .accessibilityElement(children: .combine)
    }

    #if DEBUG
    var _seriesTitlesForTesting: [String: String] {
        Dictionary(uniqueKeysWithValues: self.series.map { ($0.id, $0.title) })
    }

    var _seriesSampleCountsForTesting: [String: Int] {
        Dictionary(uniqueKeysWithValues: self.series.map { ($0.id, $0.model.samples.count) })
    }

    var _seriesLastKnownMessagesForTesting: [String: String] {
        Dictionary(uniqueKeysWithValues: self.series.map { ($0.id, $0.lastKnownUsageMessage) })
    }

    var _seriesStartsForTesting: [String: Date] {
        Dictionary(uniqueKeysWithValues: self.series.map { ($0.id, $0.model.start) })
    }

    var _seriesRemainingForTesting: [String: Double] {
        Dictionary(uniqueKeysWithValues: self.series.compactMap { series in
            series.model.samples.last.map { (series.id, $0.remainingPercent) }
        })
    }
    #endif
}
