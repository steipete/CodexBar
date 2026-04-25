import CodexBarCore
import SwiftUI

struct MiniMaxCappedScrollView<Content: View>: View {
    let maxHeight: CGFloat
    @ViewBuilder let content: () -> Content

    var body: some View {
        ScrollView {
            self.content()
        }
        .frame(maxHeight: self.maxHeight, alignment: .top)
    }
}

struct MiniMaxTokenPlanSectionsView: View {
    let sections: [UsageMenuCardView.Model.MiniMaxSection]
    let progressColor: Color
    let onLayoutChange: (() -> Void)?
    @Environment(\.menuItemHighlighted) private var isHighlighted
    @Bindable private var collapseStore = MiniMaxSectionCollapseStore.shared

    init(
        sections: [UsageMenuCardView.Model.MiniMaxSection],
        progressColor: Color,
        onLayoutChange: (() -> Void)? = nil)
    {
        self.sections = sections
        self.progressColor = progressColor
        self.onLayoutChange = onLayoutChange
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(self.sections, id: \.title) { section in
                let rowCount = section.rows.count
                let collapsed = self.collapseStore.isCollapsed(sectionTitle: section.title, rowCount: rowCount)
                VStack(alignment: .leading, spacing: 8) {
                    Button {
                        self.collapseStore.toggle(sectionTitle: section.title, rowCount: rowCount)
                        if let onLayoutChange = self.onLayoutChange {
                            Task { @MainActor in
                                await Task.yield()
                                onLayoutChange()
                            }
                        }
                    } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(section.title)
                                .font(.subheadline)
                                .fontWeight(.semibold)
                                .foregroundStyle(MenuHighlightStyle.secondary(self.isHighlighted))
                            Spacer(minLength: 8)
                            if collapsed {
                                Text("\(rowCount) items")
                                    .font(.caption2)
                                    .foregroundStyle(MenuHighlightStyle.secondary(self.isHighlighted))
                                    .monospacedDigit()
                            }
                            Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(MenuHighlightStyle.secondary(self.isHighlighted))
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(collapsed ? "展开 \(section.title)" : "折叠 \(section.title)")

                    if !collapsed {
                        ForEach(section.rows) { row in
                            MiniMaxTokenPlanRowView(row: row, progressColor: self.progressColor)
                        }
                    }
                }
            }
        }
        .padding(.top, 4)
    }
}

struct MiniMaxTokenPlanRowView: View {
    let row: UsageMenuCardView.Model.MiniMaxRow
    let progressColor: Color
    @Environment(\.menuItemHighlighted) private var isHighlighted

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(self.row.title)
                .font(.footnote)
                .fontWeight(.medium)
            if let statusText = self.row.detailText, statusText.isEmpty == false {
                Text(statusText)
                    .font(.caption2)
                    .foregroundStyle(MenuHighlightStyle.secondary(self.isHighlighted))
            }
            if let percent = self.row.percent {
                UsageProgressBar(
                    percent: percent,
                    tint: self.progressColor,
                    accessibilityLabel: self.row.percentStyle.accessibilityLabel)
                HStack(alignment: .firstTextBaseline) {
                    Text(String(format: "%.0f%% %@", percent, self.row.percentStyle.labelSuffix))
                        .font(.caption2)
                    Spacer()
                    if let reset = self.row.resetText {
                        Text(reset)
                            .font(.caption2)
                            .foregroundStyle(MenuHighlightStyle.secondary(self.isHighlighted))
                            .lineLimit(2)
                    }
                }
            } else if let reset = self.row.resetText {
                HStack(alignment: .firstTextBaseline) {
                    Text("Usage unavailable")
                        .font(.caption2)
                        .foregroundStyle(MenuHighlightStyle.secondary(self.isHighlighted))
                    Spacer()
                    Text(reset)
                        .font(.caption2)
                        .foregroundStyle(MenuHighlightStyle.secondary(self.isHighlighted))
                        .lineLimit(2)
                }
            }
            if let secondary = self.row.secondaryLine, !secondary.isEmpty {
                Text(secondary)
                    .font(.caption2)
                    .foregroundStyle(MenuHighlightStyle.secondary(self.isHighlighted))
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
