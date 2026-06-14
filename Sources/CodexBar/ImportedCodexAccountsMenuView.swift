import CodexBarCore
import SwiftUI

struct ImportedCodexAccountsMenuView: View {
    struct Model {
        struct Row: Identifiable {
            let id: String
            let email: String
            let sourceLabel: String
            let metrics: [Metric]
            let statusText: String?
        }

        struct Metric: Identifiable {
            let id: String
            let title: String
            let percent: Double
            let percentText: String
        }

        let rows: [Row]
        let averageUsedPercent: Double?

        static func make(
            snapshots: [ImportedCodexAccountUsageSnapshot],
            showUsed: Bool)
            -> Model
        {
            let metadata = ProviderDescriptorRegistry.descriptor(for: .codex).metadata
            let rows = snapshots.map { imported in
                let metrics = imported.snapshot.map {
                    Self.metrics(snapshot: $0, metadata: metadata, showUsed: showUsed)
                } ?? []
                let health = imported.error.map(CodexAccountHealth.status(forError:))
                return Row(
                    id: imported.id,
                    email: imported.account.email,
                    sourceLabel: imported.sourceLabel ?? L("Imported"),
                    metrics: metrics,
                    statusText: health?.label ?? imported.error)
            }
            let averageWindows = snapshots.compactMap { imported in
                Self.firstVisibleWindow(snapshot: imported.snapshot)
            }
            let average = averageWindows.isEmpty
                ? nil
                : averageWindows.map(\.usedPercent).reduce(0, +) / Double(averageWindows.count)
            return Model(rows: rows, averageUsedPercent: average)
        }

        private static func metrics(
            snapshot: UsageSnapshot,
            metadata: ProviderMetadata,
            showUsed: Bool)
            -> [Metric]
        {
            let projection = Self.projection(snapshot: snapshot)
            return projection.visibleRateLanes.compactMap { lane in
                guard let window = projection.rateWindow(for: lane) else { return nil }
                let title = switch lane {
                case .session:
                    L(metadata.sessionLabel)
                case .weekly:
                    L(metadata.weeklyLabel)
                }
                let percent = showUsed ? window.usedPercent : window.remainingPercent
                return Metric(
                    id: lane.rawValue,
                    title: title,
                    percent: min(100, max(0, percent)),
                    percentText: String(format: "%.0f%%", min(100, max(0, percent))))
            }
        }

        private static func firstVisibleWindow(snapshot: UsageSnapshot?) -> RateWindow? {
            guard let snapshot else { return nil }
            let projection = Self.projection(snapshot: snapshot)
            return projection.visibleRateLanes
                .lazy
                .compactMap { projection.rateWindow(for: $0) }
                .first
        }

        private static func projection(snapshot: UsageSnapshot) -> CodexConsumerProjection {
            CodexConsumerProjection.make(
                surface: .menuBar,
                context: CodexConsumerProjection.Context(
                    snapshot: snapshot,
                    rawUsageError: nil,
                    liveCredits: nil,
                    rawCreditsError: nil,
                    liveDashboard: nil,
                    rawDashboardError: nil,
                    dashboardAttachmentAuthorized: false,
                    dashboardRequiresLogin: false,
                    now: snapshot.updatedAt))
        }
    }

    let model: Model
    let width: CGFloat
    @Environment(\.menuItemHighlighted) private var isHighlighted

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("Imported (\(self.model.rows.count))")
                    .font(.body.weight(.semibold))
                Spacer(minLength: 8)
                if let average = self.model.averageUsedPercent {
                    Text(String(format: "avg %.0f%%", average))
                        .font(.caption.weight(.medium))
                        .foregroundStyle(MenuHighlightStyle.secondary(self.isHighlighted))
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                ForEach(self.model.rows) { row in
                    ImportedCodexAccountMiniRow(row: row)
                }
            }
        }
        .padding(.horizontal, UsageMenuCardLayout.horizontalPadding)
        .padding(.top, UsageMenuCardLayout.sectionTopPadding)
        .padding(.bottom, UsageMenuCardLayout.sectionBottomPadding)
        .frame(width: self.width, alignment: .leading)
    }
}

private struct ImportedCodexAccountMiniRow: View {
    let row: ImportedCodexAccountsMenuView.Model.Row
    @Environment(\.menuItemHighlighted) private var isHighlighted

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(self.row.email)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(self.row.sourceLabel)
                    .font(.caption)
                    .foregroundStyle(MenuHighlightStyle.secondary(self.isHighlighted))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            if let statusText = self.row.statusText {
                Text(statusText)
                    .font(.caption2)
                    .foregroundStyle(MenuHighlightStyle.secondary(self.isHighlighted))
                    .lineLimit(2)
            } else {
                HStack(alignment: .center, spacing: 8) {
                    ForEach(self.row.metrics.prefix(2)) { metric in
                        ImportedCodexAccountMiniMetric(metric: metric)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ImportedCodexAccountMiniMetric: View {
    let metric: ImportedCodexAccountsMenuView.Model.Metric
    @Environment(\.menuItemHighlighted) private var isHighlighted

    var body: some View {
        HStack(alignment: .center, spacing: 4) {
            Text(self.metric.title)
                .font(.caption2)
                .foregroundStyle(MenuHighlightStyle.secondary(self.isHighlighted))
                .lineLimit(1)
                .frame(minWidth: 34, alignment: .leading)
            ImportedCodexMiniGauge(percent: self.metric.percent)
                .frame(width: 38, height: 4)
            Text(self.metric.percentText)
                .font(.caption2.monospacedDigit())
                .lineLimit(1)
                .frame(width: 32, alignment: .trailing)
        }
    }
}

private struct ImportedCodexMiniGauge: View {
    let percent: Double

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.secondary.opacity(0.22))
                Capsule()
                    .fill(UsageMenuCardView.Model.progressColor(for: .codex))
                    .frame(width: proxy.size.width * CGFloat(min(100, max(0, self.percent)) / 100))
            }
        }
    }
}
