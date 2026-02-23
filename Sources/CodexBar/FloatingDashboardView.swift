import CodexBarCore
import SwiftUI

@MainActor
struct FloatingDashboardView: View {
    let store: UsageStore
    @Bindable var settings: SettingsStore
    @State private var tick: Int = 0
    @State private var isHovered = false
    @Environment(\.colorScheme) private var colorScheme

    private var isHorizontal: Bool { self.settings.floatingDashboardHorizontal }

    var body: some View {
        let horizontal = self.isHorizontal
        let cornerRadius: CGFloat = horizontal ? 8 : 12
        let shadowRadius: CGFloat = horizontal ? 4 : 8

        if horizontal {
            self.horizontalBody
                .fixedSize()
                .background {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(
                            self.colorScheme == .light
                                ? AnyShapeStyle(MenuHighlightStyle.solarizedLightBase3Color)
                                : AnyShapeStyle(.ultraThinMaterial))
                }
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(Color(nsColor: .separatorColor).opacity(0.5), lineWidth: 0.5))
                .shadow(color: Color(nsColor: .shadowColor).opacity(0.2), radius: shadowRadius, x: 0, y: 2)
                .onHover { hovering in
                    withAnimation(.easeInOut(duration: 0.15)) {
                        self.isHovered = hovering
                    }
                }
                .onAppear { self.startTimer() }
                .id(self.tick)
        } else {
            self.verticalBody
                .background {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(
                            self.colorScheme == .light
                                ? AnyShapeStyle(MenuHighlightStyle.solarizedLightBase3Color)
                                : AnyShapeStyle(.ultraThinMaterial))
                }
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(Color(nsColor: .separatorColor).opacity(0.5), lineWidth: 0.5))
                .shadow(color: Color(nsColor: .shadowColor).opacity(0.2), radius: shadowRadius, x: 0, y: 2)
                .onHover { hovering in
                    withAnimation(.easeInOut(duration: 0.15)) {
                        self.isHovered = hovering
                    }
                }
                .onAppear { self.startTimer() }
                .id(self.tick)
        }
    }

    // MARK: - Horizontal compact strip

    @ViewBuilder
    private var horizontalBody: some View {
        let enabledProviders = self.store.enabledProviders()

        HStack(spacing: 0) {
            ForEach(Array(enabledProviders.enumerated()), id: \.element) { index, provider in
                if index > 0 {
                    RoundedRectangle(cornerRadius: 0.5)
                        .fill(Color(nsColor: .separatorColor).opacity(0.4))
                        .frame(width: 1, height: 14)
                        .padding(.horizontal, 6)
                }
                self.compactProviderPill(provider)
            }

            if enabledProviders.isEmpty {
                Text("No providers")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }

            if self.isHovered {
                RoundedRectangle(cornerRadius: 0.5)
                    .fill(Color(nsColor: .separatorColor).opacity(0.4))
                    .frame(width: 1, height: 14)
                    .padding(.horizontal, 6)

                Button {
                    self.settings.floatingDashboardHorizontal.toggle()
                } label: {
                    Image(systemName: "rectangle.split.1x2")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .transition(.opacity)
                .help("Switch to vertical")

                Button {
                    self.settings.floatingDashboardEnabled = false
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .transition(.opacity)
                .padding(.leading, 4)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private func compactProviderPill(_ provider: UsageProvider) -> some View {
        let meta = self.store.metadata(for: provider)
        let snapshot = self.store.snapshot(for: provider)
        let showUsed = self.settings.usageBarsShowUsed
        let brandColor = Self.providerColor(for: provider)

        HStack(spacing: 5) {
            // Provider name with dot
            HStack(spacing: 3) {
                Circle()
                    .fill(brandColor)
                    .frame(width: 5, height: 5)
                Text(meta.displayName)
                    .font(.system(size: 9.5, weight: .semibold))
                    .lineLimit(1)
            }

            if let snapshot {
                // Session + Weekly stacked in two lines
                VStack(alignment: .leading, spacing: 2) {
                    if let primary = snapshot.primary {
                        self.compactMetricRow(
                            label: "S",
                            window: primary,
                            tint: brandColor,
                            showUsed: showUsed)
                    }
                    if let secondary = snapshot.secondary {
                        self.compactMetricRow(
                            label: "W",
                            window: secondary,
                            tint: brandColor.opacity(0.7),
                            showUsed: showUsed)
                    }
                    if snapshot.primary == nil, snapshot.secondary == nil {
                        Text("--")
                            .font(.system(size: 8))
                            .foregroundStyle(.tertiary)
                    }
                }
            } else {
                Text("--")
                    .font(.system(size: 8))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    /// Single compact row: label | bar | pct | reset time
    @ViewBuilder
    private func compactMetricRow(
        label: String,
        window: RateWindow,
        tint: Color,
        showUsed: Bool) -> some View
    {
        let pct = showUsed ? window.usedPercent : window.remainingPercent
        let clamped = min(100, max(0, pct))

        HStack(spacing: 3) {
            Text(label)
                .font(.system(size: 7.5, weight: .medium))
                .foregroundStyle(.tertiary)
                .frame(width: 8, alignment: .leading)

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color(nsColor: .separatorColor).opacity(0.4))
                    .frame(width: 28, height: 3)
                Capsule()
                    .fill(tint)
                    .frame(width: 28 * clamped / 100, height: 3)
            }

            Text(String(format: "%.0f%%", clamped))
                .font(.system(size: 8, weight: .medium, design: .rounded))
                .foregroundStyle(tint)
                .frame(width: 24, alignment: .leading)

            if let resetText = self.shortResetText(for: window) {
                Text(resetText)
                    .font(.system(size: 7.5, design: .rounded))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    /// Compact reset time like "2h", "45m", "3d" or the raw description shortened
    private func shortResetText(for window: RateWindow) -> String? {
        if let date = window.resetsAt {
            let seconds = date.timeIntervalSinceNow
            if seconds <= 0 { return nil }
            let minutes = Int(seconds / 60)
            if minutes < 60 {
                return "\(minutes)m"
            }
            let hours = minutes / 60
            if hours < 24 {
                let remainMin = minutes % 60
                return remainMin > 0 ? "\(hours)h\(remainMin)m" : "\(hours)h"
            }
            let days = hours / 24
            return "\(days)d"
        }
        if let desc = window.resetDescription?.trimmingCharacters(in: .whitespacesAndNewlines),
           !desc.isEmpty
        {
            // Try to shorten common patterns
            let lower = desc.lowercased()
            if lower.contains("hour") || lower.contains("min") || lower.contains("day") {
                // Extract just the number+unit
                let parts = desc.components(separatedBy: .whitespaces)
                if parts.count >= 2 {
                    let num = parts[0]
                    let unit = parts[1].prefix(1).lowercased()
                    return "\(num)\(unit)"
                }
            }
            return String(desc.prefix(6))
        }
        return nil
    }

    // MARK: - Vertical (original layout)

    @ViewBuilder
    private var verticalBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack(alignment: .center, spacing: 6) {
                Image(systemName: "chart.bar.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text("CodexBar")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if self.isHovered {
                    Button {
                        self.settings.floatingDashboardHorizontal.toggle()
                    } label: {
                        Image(systemName: "rectangle.split.2x1")
                            .font(.system(size: 12))
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .transition(.opacity)
                    .help("Switch to horizontal")

                    Button {
                        self.settings.floatingDashboardEnabled = false
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .transition(.opacity)
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 8)

            let enabledProviders = self.store.enabledProviders()

            if enabledProviders.isEmpty {
                HStack {
                    Spacer()
                    VStack(spacing: 4) {
                        Image(systemName: "tray")
                            .font(.system(size: 16))
                            .foregroundStyle(.quaternary)
                        Text("No providers enabled")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                    }
                    Spacer()
                }
                .padding(.vertical, 12)
                .padding(.horizontal, 12)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(enabledProviders.enumerated()), id: \.element) { index, provider in
                        if index > 0 {
                            Divider()
                                .padding(.horizontal, 12)
                        }
                        self.providerCard(provider)
                    }
                }
                .padding(.bottom, 8)
            }
        }
        .frame(width: 240)
    }

    // MARK: - Vertical provider card

    @ViewBuilder
    private func providerCard(_ provider: UsageProvider) -> some View {
        let meta = self.store.metadata(for: provider)
        let snapshot = self.store.snapshot(for: provider)
        let resetStyle = self.settings.resetTimeDisplayStyle
        let showUsed = self.settings.usageBarsShowUsed
        let brandColor = Self.providerColor(for: provider)

        VStack(alignment: .leading, spacing: 6) {
            // Provider name
            HStack(alignment: .firstTextBaseline) {
                Circle()
                    .fill(brandColor)
                    .frame(width: 6, height: 6)
                Text(meta.displayName)
                    .font(.system(size: 11, weight: .semibold))
                Spacer()
                if let snapshot, let primary = snapshot.primary {
                    let pct = showUsed ? primary.usedPercent : primary.remainingPercent
                    Text(String(format: "%.0f%%", min(100, max(0, pct))))
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(brandColor)
                }
            }

            if let snapshot {
                if let primary = snapshot.primary {
                    self.metricBar(
                        label: meta.sessionLabel,
                        window: primary,
                        tint: brandColor,
                        showUsed: showUsed,
                        resetStyle: resetStyle)
                }

                if let secondary = snapshot.secondary {
                    self.metricBar(
                        label: meta.weeklyLabel,
                        window: secondary,
                        tint: brandColor.opacity(0.7),
                        showUsed: showUsed,
                        resetStyle: resetStyle)
                }

                if snapshot.primary == nil, snapshot.secondary == nil {
                    Text("No usage yet")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
            } else {
                Text("No usage yet")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private func metricBar(
        label: String,
        window: RateWindow,
        tint: Color,
        showUsed: Bool,
        resetStyle: ResetTimeDisplayStyle) -> some View
    {
        let percent = showUsed ? window.usedPercent : window.remainingPercent
        let clamped = min(100, max(0, percent))
        let suffix = showUsed ? "used" : "left"

        VStack(alignment: .leading, spacing: 3) {
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color(nsColor: .separatorColor).opacity(0.4))
                    Capsule()
                        .fill(tint)
                        .frame(width: proxy.size.width * clamped / 100)
                }
            }
            .frame(height: 4)

            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("\(label): \(String(format: "%.0f%%", clamped)) \(suffix)")
                    .font(.system(size: 9.5))
                    .foregroundStyle(.secondary)
                Spacer()
                if let resetText = self.compactResetText(for: window, style: resetStyle) {
                    Text(resetText)
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    // MARK: - Helpers

    private func compactResetText(for window: RateWindow, style: ResetTimeDisplayStyle) -> String? {
        if let date = window.resetsAt {
            let text = style == .absolute
                ? UsageFormatter.resetDescription(from: date)
                : UsageFormatter.resetCountdownDescription(from: date)
            return text
        }
        if let desc = window.resetDescription?.trimmingCharacters(in: .whitespacesAndNewlines),
           !desc.isEmpty
        {
            return desc
        }
        return nil
    }

    private static func providerColor(for provider: UsageProvider) -> Color {
        let color = ProviderDescriptorRegistry.descriptor(for: provider).branding.color
        return Color(red: color.red, green: color.green, blue: color.blue)
    }

    private func startTimer() {
        Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                self.tick &+= 1
            }
        }
    }
}
