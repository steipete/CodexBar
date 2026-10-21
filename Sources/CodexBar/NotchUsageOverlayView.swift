import Observation
import SwiftUI

@MainActor
@Observable
final class NotchUsageOverlayViewState {
    var isExpanded = false
    var notchFrameInHeader: CGRect = .zero
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
@MainActor
struct NotchUsageOverlayContent {
    /// Caps a single tile so one long provider message cannot stretch the whole panel.
    static let maximumTileWidth: CGFloat = 320
    static let columnSpacing: CGFloat = 14
    static let horizontalPadding: CGFloat = 14
    static let bottomPadding: CGFloat = 14
    static let topPadding: CGFloat = 14
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
                    self.sessionsTile(band)
                    if !self.model.items.isEmpty {
                        Divider()
                    }
                } else {
                    if !self.model.items.isEmpty {
                        Divider()
                    }
                    self.sessionsTile(band)
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
                if let provider = row.id.firstPartyProvider,
                   let icon = ProviderBrandIcon.image(for: provider, style: self.model.iconStyle)
                {
                    Image(nsImage: icon)
                        .resizable()
                        .renderingMode(icon.isTemplate ? .template : .original)
                        .scaledToFit()
                        .frame(width: 16, height: 16)
                        .accessibilityHidden(true)
                }
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
                    if bar.showsProgress {
                        UsageProgressBar(
                            percent: bar.percent,
                            tint: row.tint,
                            accessibilityLabel: bar.accessibilityLabel)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(row.accessibilitySummary)
    }

    private func sessionsTile(_ band: NotchUsageOverlayModel.SessionsBand) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(band.title) (\(band.rows.count))")
                .font(.headline)
                .lineLimit(1)
            if band.rows.isEmpty {
                Text(L("No agent sessions found"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                HStack(alignment: .top, spacing: Self.columnSpacing) {
                    ForEach(Array(band.columns.enumerated()), id: \.offset) { _, column in
                        VStack(alignment: .leading, spacing: 6) {
                            if band.groupedByHarness, let harness = column.first?.harness {
                                Text(harness)
                                    .font(.caption.weight(.semibold))
                            }
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
        ZStack(alignment: .top) {
            if self.viewState.isExpanded {
                let model = NotchUsageOverlayModel.make(
                    store: self.store,
                    settings: self.settings,
                    agentSessions: self.agentSessions)
                self.expanded(content: NotchUsageOverlayContent(model: model))
                    .padding(.top, NotchUsageOverlayContent.topPadding)
                    .background(.regularMaterial, in: UnevenRoundedRectangle(
                        bottomLeadingRadius: 18, bottomTrailingRadius: 18, style: .continuous))
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
        GeometryReader { proxy in
            let hasProviders = !content.model.items.isEmpty
            let hasSessions = content.model.sessionsBand != nil
            let spacing = hasProviders && hasSessions ? NotchUsageOverlayContent.sectionSpacing : 0
            let heights = NotchGeometry.sectionHeights(
                availableHeight: proxy.size.height - spacing,
                providerHeight: hasProviders ? self.sectionHeight(
                    self.viewState.gridContentHeight, ceiling: self.settings.notchProvidersMaxHeight) : 0,
                sessionHeight: hasSessions ? self.sectionHeight(
                    self.viewState.bandContentHeight, ceiling: self.settings.notchSessionsMaxHeight) : 0)
            VStack(alignment: .leading, spacing: spacing) {
                if content.model.sessionsAbove {
                    self.band(content, height: heights.sessions)
                }
                if hasProviders {
                    ScrollView(.vertical) {
                        content.grid
                            .background { self.heightReporter(NotchGridHeightKey.self) }
                    }
                    .scrollIndicators(.automatic)
                    .frame(height: heights.providers)
                }
                if !content.model.sessionsAbove {
                    self.band(content, height: heights.sessions)
                }
            }
        }
        .padding(.horizontal, NotchUsageOverlayContent.horizontalPadding)
        .padding(.bottom, NotchUsageOverlayContent.bottomPadding)
    }

    private func sectionHeight(_ natural: CGFloat, ceiling: Double) -> CGFloat {
        natural > 0 ? min(natural, CGFloat(ceiling)) : CGFloat(ceiling)
    }

    /// The panel can be shorter than the configured ceilings. Scroll within the actual allocation.
    @ViewBuilder
    private func band(_ content: NotchUsageOverlayContent, height: CGFloat) -> some View {
        if content.model.sessionsBand != nil {
            ScrollView(.vertical) {
                content.band
                    .background { self.heightReporter(NotchBandHeightKey.self) }
            }
            .scrollIndicators(.automatic)
            .frame(height: height)
        }
    }

    private func heightReporter<K: PreferenceKey>(_ key: K.Type) -> some View where K.Value == CGFloat {
        GeometryReader { proxy in
            Color.clear.preference(key: key, value: proxy.size.height)
        }
    }
}

/// Display-only wings beside the camera; the owning window passes every mouse event through.
struct NotchUsageHeaderView: View {
    static let minimumSideWidth: CGFloat = 160

    let store: UsageStore
    let settings: SettingsStore
    let viewState: NotchUsageOverlayViewState

    var body: some View {
        ZStack {
            if self.viewState.isExpanded {
                let model = NotchUsageOverlayModel.make(store: self.store, settings: self.settings)
                HStack(spacing: 0) {
                    self.summary(model.headerItems.first, style: model.iconStyle)
                        .frame(width: max(0, self.viewState.notchFrameInHeader.minX - 4))
                    Color.clear.frame(width: self.viewState.notchFrameInHeader.width)
                    self.summary(model.headerItems.dropFirst().first, style: model.iconStyle)
                        .frame(maxWidth: .infinity)
                }
                .background(.regularMaterial, in: UnevenRoundedRectangle(
                    topLeadingRadius: 18, topTrailingRadius: 18, style: .continuous))
                .padding(.horizontal, 4)
                .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.easeInOut(duration: 0.2), value: self.viewState.isExpanded)
    }

    @ViewBuilder
    private func summary(_ item: NotchUsageOverlayModel.HeaderItem?, style: ProviderBrandIcon.Style) -> some View {
        if let item {
            HStack(spacing: 8) {
                if let provider = item.provider.firstPartyProvider,
                   let icon = ProviderBrandIcon.image(for: provider, style: style)
                {
                    Image(nsImage: icon)
                        .resizable()
                        .renderingMode(icon.isTemplate ? .template : .original)
                        .scaledToFit()
                        .frame(width: 16, height: 16)
                        .accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.title).font(.caption2).foregroundStyle(.secondary)
                    Text(item.value).font(.caption.weight(.semibold)).monospacedDigit()
                }
                .lineLimit(1)
            }
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(item.accessibilityLabel)
        } else {
            Color.clear
        }
    }
}
