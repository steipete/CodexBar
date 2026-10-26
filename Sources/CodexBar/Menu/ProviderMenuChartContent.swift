import CodexBarCore
import SwiftUI

enum ProviderMenuChartMode: String, CaseIterable {
    case live
    case spend

    var title: String {
        switch self {
        case .live: L("Live")
        case .spend: L("Spend")
        }
    }
}

extension SettingsStore {
    func menuChartMode(for provider: ProviderInstanceID) -> ProviderMenuChartMode {
        let modes = self.userDefaults.dictionary(forKey: "providerMenuChartModes") as? [String: String] ?? [:]
        return modes[provider.rawValue].flatMap(ProviderMenuChartMode.init(rawValue:)) ?? .live
    }

    func setMenuChartMode(_ mode: ProviderMenuChartMode, for provider: ProviderInstanceID) {
        var modes = self.userDefaults.dictionary(forKey: "providerMenuChartModes") as? [String: String] ?? [:]
        modes[provider.rawValue] = mode.rawValue
        self.userDefaults.set(modes, forKey: "providerMenuChartModes")
    }
}

extension UsageMenuCardView.Model {
    var showsChartSwitch: Bool {
        self.throughput != nil && self.inlineUsageDashboard?.points.isEmpty == false
    }
}

extension EnvironmentValues {
    @Entry var providerMenuChartSettings: SettingsStore?
    /// Synchronous selection injection for native fitting-height and render proofs.
    @Entry var providerMenuChartSelection: Binding<ProviderMenuChartMode>?
}

extension InlineUsageDashboardModel {
    func chartSummary(selectedPointID: String?) -> String {
        if let summary = self.points.first(where: { $0.id == selectedPointID })?.hoverDetail?.summary {
            return summary
        }
        guard let currencyCode = self.currencyCode else { return " " }
        let scale = UsageChartScale(values: self.points.compactMap(\.value))
        return scale.maximum > 0
            ? UsageFormatter.compactCurrencyString(scale.maximum, currencyCode: currencyCode) : " "
    }

    var chartColor: Color {
        if let barColor = self.barColor { return barColor }
        switch self.valueStyle {
        case .currencyUSD, .currency: return Color(red: 0.81, green: 0.56, blue: 0.24)
        case .tokens: return Color(red: 0.48, green: 0.41, blue: 0.86)
        case .points: return Color(red: 0.16, green: 0.62, blue: 0.36)
        }
    }
}

struct ProviderMenuChartContent: View {
    let provider: ProviderInstanceID
    let throughput: ProviderThroughputSection
    let dashboard: InlineUsageDashboardModel
    let color: Color
    @Environment(\.providerMenuChartSettings) private var settings
    @Environment(\.providerMenuChartSelection) private var injectedMode
    @Environment(\.menuUsageBarSelection) private var injectedSelection
    @Environment(\.providerCardAction) private var performAction
    @Environment(\.menuItemHighlighted) private var isHighlighted
    @State private var localMode: ProviderMenuChartMode?
    @State private var liveSelection: String?
    @State private var spendSelection: String?

    private var mode: Binding<ProviderMenuChartMode> {
        Binding(
            get: { self.injectedMode?.wrappedValue ?? self.localMode ?? self.settings?.menuChartMode(for: self.provider)
                ?? .live
            },
            set: { mode in
                // NSMenu tracking does not drain main-actor Tasks; update view state in this event.
                self.localMode = mode
                self.injectedMode?.wrappedValue = mode
                self.settings?.setMenuChartMode(mode, for: self.provider)
            })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 4) {
                ZStack(alignment: .leading) {
                    self.title(L("Tokens / min · last hour"), mode: .live)
                    self.title(
                        self.dashboard.chartTitle ?? L("Daily spend · %@", L(
                            "Last %d days",
                            self.dashboard.points.count)),
                        mode: .spend)
                }
                Spacer(minLength: 0)
                ProviderMenuChartPicker(selection: self.mode)
            }
            // Hidden layers still participate in measurement: fingerprint and height describe both modes.
            ZStack(alignment: .topLeading) {
                self.chart(mode: .live, selection: self.injectedSelection ?? self.$liveSelection)
                    .opacity(self.mode.wrappedValue == .live ? 1 : 0)
                    .allowsHitTesting(self.mode.wrappedValue == .live)
                    .accessibilityHidden(self.mode.wrappedValue != .live)
                self.chart(mode: .spend, selection: self.injectedSelection ?? self.$spendSelection)
                    .opacity(self.mode.wrappedValue == .spend ? 1 : 0)
                    .allowsHitTesting(self.mode.wrappedValue == .spend)
                    .accessibilityHidden(self.mode.wrappedValue != .spend)
            }
        }
        .padding(.bottom, 10)
    }

    private func title(_ text: String, mode: ProviderMenuChartMode) -> some View {
        Text(text)
            .font(.subheadline.weight(.medium))
            .foregroundStyle(MenuHighlightStyle.primary(self.isHighlighted))
            .lineLimit(1)
            .minimumScaleFactor(0.72)
            .opacity(self.mode.wrappedValue == mode ? 1 : 0)
            .accessibilityHidden(self.mode.wrappedValue != mode)
    }

    private func chart(mode: ProviderMenuChartMode, selection: Binding<String?>) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            MenuUsageBarStrip(
                points: mode == .live ? self.throughput.points : self.dashboard.points.map(\.menuUsageBarPoint),
                baseColor: mode == .live ? self.color : self.dashboard.chartColor,
                roundedHeadroom: mode == .live,
                selection: selection)
                .frame(height: 44)
                .contentShape(Rectangle())
                .onTapGesture {
                    if mode == .live, let action = self.throughput.presentation?.action {
                        self.performAction.perform?(action)
                    }
                }
                .menuCardInteractiveControl(isEnabled: mode == .live && self.mode.wrappedValue == .live)
                .accessibilityLabel(mode == .live ? L("Tokens per minute") : self.dashboard.accessibilityLabel)
            Text(mode == .live
                ? self.throughput.summary(selectedPointID: selection.wrappedValue)
                : self.dashboard.chartSummary(selectedPointID: selection.wrappedValue))
                .font(.caption)
                .foregroundStyle(MenuHighlightStyle.secondary(self.isHighlighted))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.72)
            if let line = self.throughput.presentation?.limitLine {
                Text(line)
                    .font(.caption)
                    .foregroundStyle(self.isHighlighted ? MenuHighlightStyle.selectionText
                        : ProviderThroughputContent.limitColor(self.throughput.presentation?.limitPercent ?? 0))
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                    .opacity(mode == .live ? 1 : 0)
                    .accessibilityHidden(mode != .live)
            }
        }
    }
}

struct ProviderMenuChartPicker: View {
    @Binding var selection: ProviderMenuChartMode
    @Environment(\.menuItemHighlighted) private var isHighlighted

    var body: some View {
        // Plain SwiftUI buttons on purpose: an AppKit segmented control runs its own mouse-tracking loop,
        // and NSMenu drops the hosting row's highlight while that loop owns the press.
        HStack(spacing: 0) {
            ForEach(ProviderMenuChartMode.allCases, id: \.self) { mode in
                let isSelected = mode == self.selection
                Button {
                    self.selection = mode
                } label: {
                    Text(mode.title)
                        .font(.caption)
                        .fontWeight(isSelected ? .semibold : .regular)
                        .foregroundStyle(MenuHighlightStyle.primary(self.isHighlighted).opacity(isSelected ? 1 : 0.7))
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
        .accessibilityLabel(L("Chart"))
    }
}
