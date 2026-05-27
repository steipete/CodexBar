import CodexBarCore
import SwiftUI

struct OnboardingMenuBarLivePreview: View {
    let preferences: OnboardingDisplayPreferences
    let providers: [UsageProvider]

    var body: some View {
        VStack(alignment: .trailing, spacing: 0) {
            self.menuBar
            VStack(spacing: 0) {
                OnboardingPopoverArrow()
                    .fill(Color.white.opacity(0.16))
                    .frame(width: 18, height: 9)
                    .padding(.trailing, self.arrowTrailingPadding)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .offset(y: 1)
                self.openMenu
                    .scaleEffect(self.previewScale, anchor: .topTrailing)
                    .frame(
                        width: 390 * self.previewScale,
                        height: self.openMenuHeight * self.previewScale,
                        alignment: .topTrailing)
            }
            .frame(height: 448, alignment: .top)
        }
        .frame(height: 490, alignment: .top)
    }

    private var menuBar: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(Color.white.opacity(0.32))
                .frame(width: 10, height: 10)
            Capsule()
                .fill(Color.white.opacity(0.14))
                .frame(width: 46, height: 7)

            Spacer()

            if self.preferences.mergeIcons {
                OnboardingPreviewStatusItem(
                    provider: self.activeProvider,
                    preferences: self.preferences,
                    isMerged: true)
            } else {
                ForEach(self.visibleProviders.prefix(2), id: \.self) { provider in
                    OnboardingPreviewStatusItem(
                        provider: provider,
                        preferences: self.preferences,
                        isMerged: false)
                }
            }

            Text("Wed, May 20 8:03 PM")
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.white.opacity(0.78))
                .lineLimit(1)
        }
        .padding(.horizontal, 12)
        .frame(width: 390, height: 36)
        .background {
            Capsule()
                .fill(.ultraThinMaterial)
            Capsule()
                .fill(Color.white.opacity(0.045))
        }
        .overlay {
            Capsule()
                .stroke(Color.white.opacity(0.12), lineWidth: 1)
        }
    }

    private var openMenu: some View {
        VStack(alignment: .leading, spacing: 9) {
            if self.preferences.mergeIcons {
                self.switcherTabs
                OnboardingPreviewDivider()
            }

            self.header

            OnboardingPreviewUsageSection(
                title: self.preferences.menuBarShowsHighestUsage ? "Weekly" : "Session",
                color: self.primaryColor,
                fill: self.preferences.menuBarShowsHighestUsage ? 0.83 : 0.93,
                left: self.preferences.menuBarShowsHighestUsage ? "83% left" : "93% left",
                right: self.preferences.menuBarShowsHighestUsage ? "Resets in 6d 4h" : "Resets in 4h 52m",
                detail: self.preferences.menuBarShowsHighestUsage ? "Runs out in 3d 23h" : nil)

            OnboardingPreviewUsageSection(
                title: self.secondaryUsageTitle,
                color: self.primaryColor.opacity(0.86),
                fill: self.preferences.menuBarShowsHighestUsage ? 0.93 : 0.83,
                left: self.preferences.menuBarShowsHighestUsage ? "93% left" : "83% left",
                right: self.preferences.menuBarShowsHighestUsage ? "Resets in 4h 52m" : "Resets in 6d 4h",
                detail: self.preferences.menuBarShowsHighestUsage ? nil : "Runs out in 3d 23h")

            self.metrics
            OnboardingPreviewMiniChart(color: self.primaryColor)
            Text("Top model: gpt-5.5")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.55))
            Text("Estimated from local logs · may differ from your bill")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.44))

            if self.preferences.showOptionalCreditsAndExtraUsage {
                OnboardingPreviewDivider()
                OnboardingPreviewCreditsSection()
            }

            OnboardingPreviewDivider()
            OnboardingPreviewActionRow(systemImage: "chart.bar", title: "Usage Dashboard")
            OnboardingPreviewActionRow(systemImage: "waveform.path.ecg", title: "Status Page")
            OnboardingPreviewActionRow(systemImage: "arrow.clockwise", title: "Refresh", trailing: "⌘R")
            OnboardingPreviewActionRow(systemImage: "gearshape", title: "Settings…", trailing: "⌘,")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(width: 390)
        .background {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(.regularMaterial)
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Color.black.opacity(0.42))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(Color.white.opacity(0.18), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.38), radius: 26, y: 18)
    }

    private var previewScale: CGFloat {
        if self.preferences.mergeIcons, self.preferences.showOptionalCreditsAndExtraUsage {
            0.82
        } else if self.preferences.showOptionalCreditsAndExtraUsage {
            0.86
        } else {
            0.91
        }
    }

    private var openMenuHeight: CGFloat {
        if self.preferences.mergeIcons, self.preferences.showOptionalCreditsAndExtraUsage {
            480
        } else if self.preferences.showOptionalCreditsAndExtraUsage {
            436
        } else {
            374
        }
    }

    private var switcherTabs: some View {
        HStack(spacing: 4) {
            OnboardingPreviewSwitcherTab(
                title: "Overview",
                systemImage: "square.grid.2x2",
                isSelected: false,
                showsIcons: self.preferences.switcherShowsIcons,
                provider: nil)

            ForEach(self.visibleProviders.prefix(4), id: \.self) { provider in
                OnboardingPreviewSwitcherTab(
                    title: Self.displayName(provider),
                    systemImage: nil,
                    isSelected: provider == self.activeProvider,
                    showsIcons: self.preferences.switcherShowsIcons,
                    provider: provider)
            }
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(Self.displayName(self.activeProvider))
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(.white.opacity(0.94))
                Text("Updated just now")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.54))
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                Text("you@example.com")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.54))
                    .lineLimit(1)
                Text(self.planName)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.54))
            }
        }
    }

    private var metrics: some View {
        HStack(spacing: 22) {
            OnboardingPreviewMetric(title: "Today", value: "$447.82")
            OnboardingPreviewMetric(title: "60d cost", value: "$9,245.35")
            OnboardingPreviewMetric(title: "Latest tokens", value: "502M")
        }
    }

    private var visibleProviders: [UsageProvider] {
        var ordered: [UsageProvider] = []
        for provider in self.providers where !ordered.contains(provider) {
            ordered.append(provider)
        }
        if ordered.isEmpty {
            ordered.append(.codex)
        }
        for provider in [UsageProvider.openai, .claude, .cursor] where !ordered.contains(provider) {
            ordered.append(provider)
        }
        return ordered
    }

    private var arrowTrailingPadding: CGFloat {
        self.preferences.mergeIcons ? 168 : 184
    }

    private var activeProvider: UsageProvider {
        self.visibleProviders.first ?? .codex
    }

    var previewProvidersForTesting: [UsageProvider] {
        self.visibleProviders
    }

    var activeProviderForTesting: UsageProvider {
        self.activeProvider
    }

    private var primaryColor: Color {
        OnboardingPalette.codexTeal
    }

    private var secondaryUsageTitle: String {
        self.preferences.menuBarShowsHighestUsage ? "Session" : "Weekly"
    }

    private var planName: String {
        switch self.activeProvider {
        case .cursor:
            "Cursor Pro"
        case .codex, .openai:
            "Plus"
        default:
            "Active"
        }
    }

    private static func displayName(_ provider: UsageProvider) -> String {
        ProviderDescriptorRegistry.descriptor(for: provider).metadata.displayName
    }
}

private struct OnboardingPreviewStatusItem: View {
    let provider: UsageProvider
    let preferences: OnboardingDisplayPreferences
    let isMerged: Bool

    var body: some View {
        HStack(spacing: 6) {
            if self.preferences.menuBarShowsBrandIconWithPercent {
                OnboardingProviderMiniIcon(provider: self.provider, size: 15)
                Text(self.displayValue)
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.92))
            } else {
                OnboardingUsageGlyph(color: self.color)
            }
        }
        .frame(height: 22)
    }

    private var displayValue: String {
        let percent = self.percentValue
        return switch self.preferences.menuBarDisplayMode {
        case .percent:
            "\(percent)%"
        case .pace:
            self.paceValue
        case .both:
            if self.supportsPace {
                "\(percent)% · \(self.paceValue)"
            } else {
                "\(percent)%"
            }
        }
    }

    private var supportsPace: Bool {
        self.provider == .codex || self.provider == .openai
    }

    private var paceValue: String {
        self.provider == .openai ? "+8%" : "+10%"
    }

    private var percentValue: Int {
        switch self.provider {
        case .codex:
            96
        case .openai:
            96
        case .claude:
            100
        case .cursor:
            100
        default:
            68
        }
    }

    private var color: Color {
        self.preferences.menuBarShowsBrandIconWithPercent ? ProviderDescriptorRegistry.descriptor(for: self.provider)
            .branding
            .color.swiftUIColor : Color.white.opacity(0.9)
    }
}

private struct OnboardingPreviewSwitcherTab: View {
    let title: String
    let systemImage: String?
    let isSelected: Bool
    let showsIcons: Bool
    let provider: UsageProvider?

    var body: some View {
        VStack(spacing: 3) {
            if self.showsIcons {
                self.icon
                    .frame(height: 17)
            }
            Text(self.title)
                .font(.system(size: 10, weight: .bold))
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
        .foregroundStyle(self.isSelected ? .white : Color.white.opacity(0.56))
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        .background {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(self.isSelected ? OnboardingPalette.brandBlue.opacity(0.88) : Color.clear)
        }
    }

    @ViewBuilder
    private var icon: some View {
        if let provider {
            OnboardingProviderMiniIcon(provider: provider, size: 17)
        } else if let systemImage {
            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .semibold))
        }
    }
}

private struct OnboardingPreviewUsageSection: View {
    let title: String
    let color: Color
    let fill: CGFloat
    let left: String
    let right: String
    let detail: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(self.title)
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(.white.opacity(0.9))
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.white.opacity(0.09))
                    .frame(height: 7)
                Capsule()
                    .fill(self.color)
                    .frame(width: max(12, 336 * self.fill), height: 7)
                ForEach([0.2, 0.5, 0.78], id: \.self) { marker in
                    Rectangle()
                        .fill(marker > 0.75 ? Color.red.opacity(0.9) : Color.white.opacity(0.62))
                        .frame(width: 2, height: 9)
                        .offset(x: 336 * marker)
                }
            }
            HStack(alignment: .top) {
                Text(self.left)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white.opacity(0.82))
                Spacer()
                VStack(alignment: .trailing, spacing: 1) {
                    Text(self.right)
                    if let detail {
                        Text(detail)
                    }
                }
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.54))
            }
        }
    }
}

private struct OnboardingPreviewMetric: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(self.title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.5))
            Text(self.value)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.white.opacity(0.88))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct OnboardingPreviewMiniChart: View {
    let color: Color

    var body: some View {
        HStack(alignment: .bottom, spacing: 3) {
            ForEach(
                [
                    0.18,
                    0.24,
                    0.36,
                    0.62,
                    0.28,
                    0.44,
                    0.66,
                    0.38,
                    0.90,
                    0.42,
                    0.46,
                    0.58,
                    0.32,
                    0.22,
                    0.56,
                    0.52,
                    0.34,
                    0.40,
                    0.72,
                    0.70,
                    0.68,
                    0.48,
                    0.74,
                ],
                id: \.self)
            { height in
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(self.color.opacity(0.72))
                    .frame(width: 11, height: 58 * height)
            }
        }
        .frame(height: 58, alignment: .bottom)
    }
}

private struct OnboardingPreviewCreditsSection: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Credits")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(.white.opacity(0.9))
            Capsule()
                .fill(Color.white.opacity(0.09))
                .frame(height: 7)
            HStack {
                Text("0 left")
                Spacer()
                Text("1K tokens")
            }
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Color.white.opacity(0.76))
            OnboardingPreviewActionRow(systemImage: "plus.circle", title: "Buy Credits...")
                .padding(.top, 1)
        }
    }
}

private struct OnboardingPreviewActionRow: View {
    let systemImage: String
    let title: String
    var trailing: String?

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: self.systemImage)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.82))
                .frame(width: 16)
            Text(self.title)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(Color.white.opacity(0.84))
            Spacer()
            if let trailing {
                Text(trailing)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.46))
            }
        }
        .frame(height: 19)
    }
}

private struct OnboardingPreviewDivider: View {
    var body: some View {
        Rectangle()
            .fill(Color.white.opacity(0.13))
            .frame(height: 1)
    }
}

private struct OnboardingPopoverArrow: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}
