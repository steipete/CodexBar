import Observation
import SwiftUI

@MainActor
@Observable
final class NotchUsageOverlayViewState {
    var isExpanded = false
    var notchHeight: CGFloat = 0
    /// Height the provider grid wants at the panel's current width, reported from inside its
    /// scroll view where nothing clamps it. Zero until the first report.
    var gridContentHeight: CGFloat = 0
    /// Same, for the session band.
    var bandContentHeight: CGFloat = 0
}

struct NotchGridHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

struct NotchBandHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// Builds the two sections of the panel — the provider grid and the session band. Not a view
/// itself: the live view and the controller's first-frame estimate both compose ``grid`` and
/// ``band`` directly, so each section keeps its own height budget.
struct NotchUsageOverlayContent {
    /// Caps a single tile so one long provider message cannot stretch the whole panel.
    static let maximumTileWidth: CGFloat = 320
    static let columnSpacing: CGFloat = 14
    static let horizontalPadding: CGFloat = 14
    static let bottomPadding: CGFloat = 14
    /// Gap the panel stack puts between the band and the grid.
    static let sectionSpacing: CGFloat = 10

    let model: NotchUsageOverlayModel

    /// The provider tiles: the part that scrolls when the panel hits its height limit.
    @ViewBuilder
    var grid: some View {
        if self.model.matchesRowHeights {
            self.matchedGrid
        } else {
            self.packedColumns
        }
    }

    /// The session list as a full-width band, with its divider on the grid's side. Empty unless
    /// the session list is switched on.
    @ViewBuilder
    var band: some View {
        if let band = self.model.sessionsBand {
            VStack(alignment: .leading, spacing: 10) {
                if self.model.sessionsAbove {
                    self.sessionsTile(title: band.title, rows: band.rows, columns: self.model.columnCount)
                    if !self.model.items.isEmpty {
                        Divider()
                    }
                } else {
                    if !self.model.items.isEmpty {
                        Divider()
                    }
                    self.sessionsTile(title: band.title, rows: band.rows, columns: self.model.columnCount)
                }
            }
        }
    }

    /// Columns pack independently: a short tile sits directly under the tall one above it.
    private var packedColumns: some View {
        HStack(alignment: .top, spacing: Self.columnSpacing) {
            ForEach(Array(self.model.columns().enumerated()), id: \.offset) { _, column in
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(column.enumerated()), id: \.element.id) { index, row in
                        if index > 0 {
                            Divider()
                        }
                        self.providerTile(row)
                    }
                }
                .frame(maxWidth: Self.maximumTileWidth, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// `Grid` gives every cell in a row the height of that row's tallest cell, which is exactly
    /// the matched-height behaviour; tiles stay top-aligned inside their cell.
    private var matchedGrid: some View {
        Grid(alignment: .topLeading, horizontalSpacing: Self.columnSpacing, verticalSpacing: 10) {
            ForEach(Array(self.model.rows().enumerated()), id: \.offset) { index, row in
                if index > 0 {
                    Divider().gridCellUnsizedAxes(.horizontal)
                }
                GridRow {
                    ForEach(row, id: \.id) { row in
                        self.providerTile(row)
                            .frame(maxWidth: Self.maximumTileWidth, alignment: .topLeading)
                    }
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func providerTile(_ row: NotchUsageOverlayModel.ProviderRow) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(row.name)
                    .font(.headline)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if let statusText = row.statusText {
                    Text(statusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            ForEach(Array(row.bars.enumerated()), id: \.offset) { _, bar in
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(bar.title)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        Text(bar.percentText)
                            .monospacedDigit()
                        if let resetText = bar.resetText {
                            Text(resetText)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .font(.caption)
                    UsageProgressBar(
                        percent: bar.percent,
                        tint: row.tint,
                        accessibilityLabel: bar.accessibilityLabel)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(row.name)
    }

    private func sessionsTile(
        title: String,
        rows: [NotchUsageOverlayModel.SessionRow],
        columns: Int) -> some View
    {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(title) (\(rows.count))")
                .font(.headline)
                .lineLimit(1)
            if rows.isEmpty {
                Text(L("No agent sessions found"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                HStack(alignment: .top, spacing: Self.columnSpacing) {
                    let sliced = NotchUsageOverlayModel.distribute(rows, into: columns)
                    ForEach(Array(sliced.enumerated()), id: \.offset) { _, column in
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(column) { session in
                                self.sessionRow(session)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func sessionRow(_ session: NotchUsageOverlayModel.SessionRow) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(session.isActive ? Color.green : Color.secondary.opacity(0.5))
                .frame(width: 6, height: 6)
            Text(session.title)
                .lineLimit(1)
            Spacer(minLength: 4)
            Text(session.detail)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .font(.caption)
    }
}

struct NotchUsageOverlayView: View {
    let store: UsageStore
    let settings: SettingsStore
    let agentSessions: AgentSessionsStore?
    let viewState: NotchUsageOverlayViewState

    var body: some View {
        let model = NotchUsageOverlayModel.make(
            store: self.store,
            settings: self.settings,
            agentSessions: self.agentSessions)
        ZStack(alignment: .top) {
            if self.viewState.isExpanded {
                VStack(alignment: .leading, spacing: 0) {
                    Color.clear
                        .frame(height: self.viewState.notchHeight)
                    self.expanded(content: NotchUsageOverlayContent(model: model))
                }
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .padding(.horizontal, 4)
                .padding(.bottom, 4)
                .transition(.scale(scale: 0.4, anchor: .top).combined(with: .opacity))
                .onPreferenceChange(NotchGridHeightKey.self) { height in
                    MainActor.assumeIsolated {
                        self.viewState.gridContentHeight = height
                    }
                }
                .onPreferenceChange(NotchBandHeightKey.self) { height in
                    MainActor.assumeIsolated {
                        self.viewState.bandContentHeight = height
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: self.viewState.isExpanded)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L("notch_summary_title"))
    }

    /// Two independently budgeted sections. Each sits in its own scroll view and reports the height
    /// its content wants from *inside* that scroll view, where nothing clamps it — that report is
    /// what sizes the panel, so what the controller believes always matches what SwiftUI laid out.
    private func expanded(content: NotchUsageOverlayContent) -> some View {
        VStack(alignment: .leading, spacing: NotchUsageOverlayContent.sectionSpacing) {
            if content.model.sessionsAbove {
                self.band(content)
            }
            ScrollView(.vertical) {
                content.grid
                    .background { self.heightReporter(NotchGridHeightKey.self) }
            }
            .scrollIndicators(.automatic)
            if !content.model.sessionsAbove {
                self.band(content)
            }
        }
        .padding(.horizontal, NotchUsageOverlayContent.horizontalPadding)
        .padding(.bottom, NotchUsageOverlayContent.bottomPadding)
    }

    /// The band takes its natural height up to its own ceiling and scrolls beyond it, so the
    /// session list stays visible no matter how tall the provider grid is.
    @ViewBuilder
    private func band(_ content: NotchUsageOverlayContent) -> some View {
        if content.model.sessionsBand != nil {
            let natural = self.viewState.bandContentHeight
            let ceiling = CGFloat(self.settings.notchSessionsMaxHeight)
            ScrollView(.vertical) {
                content.band
                    .background { self.heightReporter(NotchBandHeightKey.self) }
            }
            .scrollIndicators(.automatic)
            .scrollDisabled(natural > 0 && natural <= ceiling)
            .frame(height: natural > 0 ? min(natural, ceiling) : nil)
        }
    }

    private func heightReporter<K: PreferenceKey>(_ key: K.Type) -> some View where K.Value == CGFloat {
        GeometryReader { proxy in
            Color.clear.preference(key: key, value: proxy.size.height)
        }
    }
}
