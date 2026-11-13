import CodexBarCore
import SwiftUI

/// Sections in display order, with each run of alternative sections folded into one switchable group.
enum ProviderDetailBlock: Equatable {
    case section(ProviderDetailSection)
    case group(ProviderDetailVariantGroup)

    static func blocks(_ sections: [ProviderDetailSection]) -> [Self] {
        var blocks: [Self] = []
        for section in sections {
            guard let variant = section.variant else {
                blocks.append(.section(section))
                continue
            }
            // A repeated variant starts a new group instead of becoming unreachable behind its twin.
            if case let .group(group) = blocks.last,
               group.sections[0].variant?.count == variant.count,
               !group.sections.contains(where: { $0.variant == variant })
            {
                blocks[blocks.count - 1] = .group(.init(sections: group.sections + [section]))
            } else {
                blocks.append(.group(.init(sections: [section])))
            }
        }
        return blocks
    }

    var isGroup: Bool {
        if case .group = self {
            true
        } else {
            false
        }
    }
}

struct ProviderDetailVariantGroup: Equatable {
    /// Never empty, and every section has a variant with the same number of labels.
    let sections: [ProviderDetailSection]

    /// One list of choices per label position, in first-seen order.
    var pickers: [[String]] {
        let variants = self.sections.compactMap(\.variant)
        return (variants.first ?? []).indices.map { position in
            var options: [String] = []
            for variant in variants where !options.contains(variant[position]) {
                options.append(variant[position])
            }
            return options
        }
    }

    /// The stored choice when a section still matches it, otherwise the first section's.
    func selection(_ stored: [String]?) -> [String] {
        if let stored, self.sections.contains(where: { $0.variant == stored }) {
            return stored
        }
        return self.sections[0].variant ?? []
    }

    /// The selection after one picker changes. When no section has the exact combination, the first one
    /// offering the new choice wins, so a picker never leads to an empty card.
    func selection(_ current: [String], choosing option: String, at position: Int) -> [String] {
        var next = current
        guard next.indices.contains(position) else { return current }
        next[position] = option
        if self.sections.contains(where: { $0.variant == next }) {
            return next
        }
        return self.sections.first { $0.variant?[position] == option }?.variant ?? current
    }
}

/// Lets card content whose height depends on its own view state ask the hosting menu row to re-measure.
struct MenuCardLayoutAction {
    var invalidate: (@MainActor @Sendable () -> Void)?
}

extension EnvironmentValues {
    @Entry var menuCardLayout = MenuCardLayoutAction()
}

extension SettingsStore {
    private static let detailVariantSelectionsKey = "providerDetailVariantSelections"

    /// `group` counts a provider's variant groups from zero, in display order.
    func detailVariantSelection(for provider: ProviderInstanceID, group: Int) -> [String]? {
        let selections = self.userDefaults.dictionary(forKey: Self.detailVariantSelectionsKey) as? [String: [String]]
        return selections?[Self.detailVariantSelectionKey(provider, group: group)]
    }

    func setDetailVariantSelection(_ selection: [String], for provider: ProviderInstanceID, group: Int) {
        var selections = self.userDefaults
            .dictionary(forKey: Self.detailVariantSelectionsKey) as? [String: [String]] ?? [:]
        selections[Self.detailVariantSelectionKey(provider, group: group)] = selection
        self.userDefaults.set(selections, forKey: Self.detailVariantSelectionsKey)
    }

    private static func detailVariantSelectionKey(_ provider: ProviderInstanceID, group: Int) -> String {
        "\(provider.rawValue)#\(group)"
    }
}

struct ProviderDetailSectionsContent: View {
    let sections: [ProviderDetailSection]
    let chartColor: Color
    var paceVisible: Bool = true
    /// Remembers variant picker choices for this provider; without it they last as long as the view.
    var provider: ProviderInstanceID?
    @Environment(\.menuItemHighlighted) private var isHighlighted
    @Environment(\.providerMenuChartSettings) private var settings
    @Environment(\.menuCardLayout) private var layout
    /// Keyed by provider and the group's position among the variant groups. A recycled menu row keeps this
    /// state when it changes provider, so the position alone would hand one provider's choice to another.
    @State private var localSelections: [String: [String]] = [:]

    var body: some View {
        let blocks = ProviderDetailBlock.blocks(self.sections)
        return VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { index, block in
                if index > 0 {
                    Divider()
                }
                switch block {
                case let .section(section):
                    self.section(section)
                case let .group(group):
                    self.group(group, ordinal: blocks[..<index].count(where: \.isGroup))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func group(_ group: ProviderDetailVariantGroup, ordinal: Int) -> some View {
        let key = "\(self.provider?.rawValue ?? "")#\(ordinal)"
        let stored = self.localSelections[key]
            ?? self.provider.flatMap { self.settings?.detailVariantSelection(for: $0, group: ordinal) }
        let selection = group.selection(stored)
        return VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(group.pickers.enumerated()), id: \.offset) { position, options in
                if options.count > 1 {
                    ProviderDetailVariantPicker(
                        options: options,
                        selection: Binding(
                            get: { selection[position] },
                            set: { option in
                                // NSMenu tracking does not drain main-actor Tasks; update view state in this event.
                                let next = group.selection(selection, choosing: option, at: position)
                                self.localSelections[key] = next
                                if let provider = self.provider {
                                    self.settings?.setDetailVariantSelection(next, for: provider, group: ordinal)
                                }
                                // Alternatives differ in height, so the menu row is measured again.
                                self.layout.invalidate?()
                            }))
                }
            }
            if let section = group.sections.first(where: { $0.variant == selection }) {
                self.section(section)
            }
        }
    }

    private static func progressColor(_ severity: ProviderDetailSection.Row.Severity?, fallback: Color) -> Color {
        switch severity {
        case .normal: Color(nsColor: .systemGreen)
        case .warning: Color(nsColor: .systemOrange)
        case .critical: Color(nsColor: .systemRed)
        case nil: fallback
        }
    }

    private func section(_ section: ProviderDetailSection) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let title = section.title {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(MenuHighlightStyle.secondary(self.isHighlighted))
                    .textCase(.uppercase)
                    .lineLimit(1)
            }
            ForEach(Array(section.rows.enumerated()), id: \.offset) { _, row in
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(row.label)
                            .foregroundStyle(MenuHighlightStyle.secondary(self.isHighlighted))
                        Spacer(minLength: 8)
                        VStack(alignment: .trailing, spacing: 1) {
                            HStack(spacing: 4) {
                                if let severity = row.severity, severity != .normal {
                                    Label(
                                        severity == .critical ? L("quota_warning_critical") :
                                            L("quota_warning_warning"),
                                        systemImage: severity == .critical
                                            ? "exclamationmark.octagon.fill" : "exclamationmark.triangle.fill")
                                        .labelStyle(.iconOnly)
                                        .foregroundStyle(self.isHighlighted
                                            ? .white : Self.progressColor(severity, fallback: self.chartColor))
                                }
                                Text(row.value)
                                    .foregroundStyle(MenuHighlightStyle.primary(self.isHighlighted))
                                    .fontWeight(.medium)
                            }
                            if let secondaryValue = row.secondaryValue {
                                Text(secondaryValue)
                                    .font(.caption2)
                                    .foregroundStyle(MenuHighlightStyle.secondary(self.isHighlighted))
                            }
                        }
                    }
                    .font(.caption)
                    .lineLimit(1)
                    if let progress = row.progress {
                        // The ratio is provider data left unclamped by contract; only the bar's fill
                        // is clamped here, the "used / total" caption keeps the raw numbers.
                        UsageProgressBar(
                            percent: min(100, max(0, progress.usedPercent)),
                            tint: Self.progressColor(row.severity, fallback: self.chartColor),
                            accessibilityLabel: row.label,
                            pacePercent: self.paceVisible ? progress.expectedUsedPercent : nil,
                            paceOnTop: progress.usedPercent <= progress.expectedUsedPercent ?? .infinity)
                    }
                }
            }
            if let chart = section.chart {
                ProviderDetailChartContent(chart: chart, color: self.chartColor)
            }
        }
    }
}

private struct ProviderDetailVariantPicker: View {
    let options: [String]
    @Binding var selection: String
    @Environment(\.menuItemHighlighted) private var isHighlighted

    var body: some View {
        // Plain SwiftUI buttons on purpose: an AppKit segmented control runs its own mouse-tracking loop,
        // and NSMenu drops the hosting row's highlight while that loop owns the press.
        HStack(spacing: 0) {
            ForEach(self.options, id: \.self) { option in
                let isSelected = option == self.selection
                Button {
                    self.selection = option
                } label: {
                    Text(option)
                        .font(.caption)
                        .fontWeight(isSelected ? .semibold : .regular)
                        .foregroundStyle(MenuHighlightStyle.primary(self.isHighlighted).opacity(isSelected ? 1 : 0.7))
                        .lineLimit(1)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background {
                            if isSelected {
                                Capsule().fill(MenuHighlightStyle.primary(self.isHighlighted)
                                    .opacity(self.isHighlighted ? 0.24 : 0.14))
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .padding(2)
        .background(Capsule().fill(MenuHighlightStyle.secondary(self.isHighlighted).opacity(0.12)))
        .fixedSize()
        .menuCardInteractiveControl()
        .accessibilityElement(children: .contain)
    }
}

private struct ProviderDetailChartContent: View {
    let chart: ProviderDetailSection.Chart
    let color: Color
    @Environment(\.menuItemHighlighted) private var isHighlighted

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if self.chart.title != nil || self.chart.unit != nil {
                HStack(spacing: 6) {
                    if let title = self.chart.title {
                        Text(title)
                            .font(.caption2.weight(.semibold))
                    }
                    Spacer(minLength: 0)
                    if let unit = self.chart.unit {
                        Text(unit)
                            .font(.caption2)
                            .monospacedDigit()
                    }
                }
                .foregroundStyle(MenuHighlightStyle.secondary(self.isHighlighted))
                .lineLimit(1)
            }
            Group {
                switch self.chart.kind {
                case .bars:
                    self.bars
                case .line:
                    self.line
                }
            }
            .frame(height: 58)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(self.accessibilityLabel)
        }
    }

    private var bars: some View {
        MenuUsageBarStrip(
            points: self.chart.points.enumerated().map { index, point in
                .init(id: String(index), value: point.value)
            },
            baseColor: self.color)
    }

    private var line: some View {
        GeometryReader { _ in
            Canvas { context, size in
                let scale = UsageChartScale(values: self.chart.points.map(\.value))
                let points = self.chart.points.enumerated().map { index, point in
                    let x = self.chart.points.count == 1
                        ? size.width / 2
                        : size.width * CGFloat(index) / CGFloat(self.chart.points.count - 1)
                    let y = size.height * (1 - CGFloat(scale.fraction(for: point.value)))
                    return CGPoint(x: x, y: y)
                }
                guard let first = points.first else { return }
                var path = Path()
                path.move(to: first)
                for point in points.dropFirst() {
                    path.addLine(to: point)
                }
                context.stroke(
                    path,
                    with: .color(self.isHighlighted ? .white.opacity(0.82) : self.color),
                    style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                for point in points {
                    context.fill(
                        Path(ellipseIn: CGRect(x: point.x - 1.5, y: point.y - 1.5, width: 3, height: 3)),
                        with: .color(self.isHighlighted ? .white : self.color))
                }
            }
            .overlay(alignment: .bottomLeading) {
                Rectangle()
                    .fill(MenuHighlightStyle.secondary(self.isHighlighted).opacity(0.22))
                    .frame(height: 1)
            }
        }
    }

    private var accessibilityLabel: String {
        let title = self.chart.title.map { "\($0): " } ?? ""
        let unit = self.chart.unit.map { " \($0)" } ?? ""
        let points = self.chart.points.map { "\($0.label) \($0.value)\(unit)" }.joined(separator: ", ")
        return title + points
    }
}
