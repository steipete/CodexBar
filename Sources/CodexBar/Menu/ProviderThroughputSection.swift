import CodexBarCore
import SwiftUI

struct ProviderThroughputPresentation {
    var limitLine: String?
    var limitPercent: Double?
    var action: MenuDescriptor.MenuAction?
}

struct ProviderThroughputSection {
    let snapshot: ProviderThroughputSnapshot
    var presentation: ProviderThroughputPresentation?

    var summaryLine: String {
        L(
            "Latest %@ · Peak %@ at %@",
            self.snapshot.latestTokensPerMinute.map(Self.count) ?? "—",
            Self.count(self.snapshot.peakTokensPerMinute),
            self.snapshot.peakAt?.formatted(date: .omitted, time: .shortened) ?? "—")
    }

    var points: [MenuUsageBarPoint] {
        self.snapshot.minutes.map { minute in
            let time = minute.start.formatted(date: .omitted, time: .shortened)
            let summary = minute.isPending ? "\(time) · \(L("reporting…"))" : "\(time) · " + L(
                "%@ tokens · %@ requests",
                ProviderThroughputSection.count(minute.totalTokens),
                ProviderThroughputSection.count(minute.requests))
            return .init(
                id: String(minute.start.timeIntervalSince1970),
                value: Double(minute.totalTokens),
                isPending: minute.isPending,
                hoverSummary: summary,
                accessibilityValue: summary)
        }
    }

    func summary(selectedPointID: String?) -> String {
        self.points.first { $0.id == selectedPointID }?.hoverSummary ?? self.summaryLine
    }

    static func count(_ value: Int) -> String {
        UsageFormatter.tokenCountString(value)
    }
}

struct ProviderCardAction {
    var perform: (@MainActor @Sendable (MenuDescriptor.MenuAction) -> Void)?
}

extension EnvironmentValues {
    @Entry var providerCardAction = ProviderCardAction()
}

struct ProviderThroughputContent: View {
    let section: ProviderThroughputSection
    let color: Color
    @Environment(\.providerCardAction) private var performAction
    @Environment(\.menuItemHighlighted) private var isHighlighted
    @State private var selectedPointID: String?
    @Environment(\.menuUsageBarSelection) private var injectedSelection

    private var selection: Binding<String?> {
        self.injectedSelection ?? self.$selectedPointID
    }

    var points: [MenuUsageBarPoint] {
        self.section.points
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(L("Tokens / min · last hour")).font(.subheadline).fontWeight(.medium)
                    .foregroundStyle(MenuHighlightStyle.primary(self.isHighlighted))
                Spacer(minLength: 4)
                if self.section.presentation?.action != nil {
                    Button(L("Live Usage…")) { self.openDetails() }
                        .buttonStyle(.plain).font(.caption)
                        .foregroundStyle(MenuHighlightStyle.secondary(self.isHighlighted))
                        .menuCardInteractiveControl()
                }
            }
            MenuUsageBarStrip(
                points: self.points,
                baseColor: self.color,
                roundedHeadroom: true,
                selection: self.selection)
                .frame(height: 44)
                .contentShape(Rectangle())
                .onTapGesture { self.openDetails() }
                // Register the chart so rows with their own click (Overview) forward this tap to it.
                .menuCardInteractiveControl(isEnabled: self.section.presentation?.action != nil)
                .accessibilityLabel(L("Tokens per minute"))
            // One line in both states so hovering never changes the hosted menu row height.
            Text(self.points.first { $0.id == self.selection.wrappedValue }?.hoverSummary ?? self.section.summaryLine)
                .font(.caption)
                .foregroundStyle(MenuHighlightStyle.secondary(self.isHighlighted))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            if let line = self.section.presentation?.limitLine {
                Text(line).font(.caption)
                    .foregroundStyle(self.isHighlighted
                        ? MenuHighlightStyle.selectionText
                        : Self.limitColor(self.section.presentation?.limitPercent ?? 0))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.bottom, 10)
    }

    private func openDetails() {
        if let action = self.section.presentation?.action { self.performAction.perform?(action) }
    }

    static func limitColor(_ percent: Double) -> Color {
        if percent >= 95 { return .red }
        if percent >= 80 { return .orange }
        return .secondary
    }
}

extension UsageMenuCardView.Model {
    /// Rows with their own click (Overview) must forward presses that land on these hosted controls.
    var containsInteractiveControls: Bool {
        self.showsChartSwitch || self.throughput?.presentation?.action != nil
            || self.subtitleStyle == .error || self.usesLiveSubtitle
    }
}
