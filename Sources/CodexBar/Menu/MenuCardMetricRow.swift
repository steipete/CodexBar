import CodexBarCore
import SwiftUI

struct MetricRow: View {
    let metric: UsageMenuCardView.Model.Metric
    let layoutMetric: UsageMenuCardView.Model.Metric
    let title: String
    let progressColor: Color
    var compact = false
    @Environment(\.menuItemHighlighted) private var isHighlighted

    var body: some View {
        let presentation = self.metric.linePresentation(title: self.title)
        let layoutPresentation = self.layoutMetric.linePresentation(title: self.title)
        VStack(alignment: .leading, spacing: 6) {
            if let statusText = self.metric.statusText {
                Text(self.title)
                    .font(.body)
                    .fontWeight(.medium)
                Text(statusText)
                    .font(.footnote)
                    .foregroundStyle(MenuHighlightStyle.secondary(self.isHighlighted))
                    .lineLimit(1)
            } else {
                MetricRowHeader(
                    title: presentation.titleText,
                    layoutTitle: layoutPresentation.titleText,
                    resetText: self.compact ? nil : presentation.resetText,
                    layoutResetText: self.compact ? nil : layoutPresentation.resetText,
                    isHighlighted: self.isHighlighted,
                    isCriticallyLow: self.metric.isCriticallyLow)
                UsageProgressBar(
                    percent: self.metric.percent,
                    tint: self.metric.isCriticallyLow ? Color(nsColor: .systemRed) : self.progressColor,
                    accessibilityLabel: self.metric.percentStyle.accessibilityLabel,
                    pacePercent: self.metric.pacePercent,
                    paceOnTop: self.metric.paceOnTop,
                    warningMarkerPercents: self.metric.warningMarkerPercents,
                    workdayMarkerPercents: self.metric.workdayMarkerPercents,
                    workdayTickAppearance: self.metric.workdayTickAppearance)
                if !self.compact, let layoutMetaText = layoutPresentation.metaText {
                    self.layoutPreservingText(
                        presentation.metaText,
                        layoutText: layoutMetaText,
                        lineLimit: 2)
                }
                if !self.compact, let layoutDetailText = self.layoutMetric.detailText {
                    self.layoutPreservingText(
                        self.metric.detailText,
                        layoutText: layoutDetailText,
                        lineLimit: 1)
                }
                if !self.compact, let layoutTarget = self.layoutMetric.dailyTargetText {
                    self.layoutPreservingText(self.metric.dailyTargetText, layoutText: layoutTarget, lineLimit: 2)
                }
            }
        }
        .help(self.metric.helpText ?? "")
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(self.metric.cardStyle ? 10 : 0)
        .background(self.metric.cardStyle ? Color.secondary.opacity(self.isHighlighted ? 0.2 : 0.08) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: self.metric.cardStyle ? 10 : 0))
    }

    private func layoutPreservingText(
        _ text: String?,
        layoutText: String,
        lineLimit: Int) -> some View
    {
        Text(layoutText)
            .font(.footnote)
            .lineLimit(lineLimit)
            .fixedSize(horizontal: false, vertical: true)
            .hidden()
            // Freeze the measured height, but let updates use the entire metric row width.
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .topLeading) {
                if let text, !text.isEmpty {
                    Text(text)
                        .font(.footnote)
                        .foregroundStyle(MenuHighlightStyle.secondary(self.isHighlighted))
                        .lineLimit(lineLimit)
                        .truncationMode(.tail)
                }
            }
            .clipped()
    }
}

extension UsageMenuCardView.Model.Metric {
    /// Remaining quota at or below the shared critical headroom threshold used by compact account rows.
    /// Only the critical tier is surfaced so healthy bars keep the provider tint.
    var isCriticallyLow: Bool {
        guard self.statusText == nil, !self.isSyntheticCreditLane else { return false }
        let remaining = self.percentStyle == .left ? self.percent : 100 - self.percent
        return AccountMenuLayoutPlanner.severity(forHeadroom: remaining) == .critical
    }
}
