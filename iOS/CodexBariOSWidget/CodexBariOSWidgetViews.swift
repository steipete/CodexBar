import CodexBariOSShared
import SwiftUI
import WidgetKit

private let widgetAppURL = URL(string: "codexbarios://dashboard")!

struct UsageWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: UsageWidgetEntry

    var body: some View {
        ZStack {
            WidgetBackground()

            if let providerEntry = self.entry.snapshot.entries.first(where: { $0.provider == self.entry.provider }) {
                ProviderUsageContent(entry: providerEntry, family: self.family, availableProviders: nil)
            } else {
                EmptyWidgetState()
            }
        }
        .containerBackground(.fill.tertiary, for: .widget)
        .widgetURL(widgetAppURL)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct SwitcherWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: SwitcherWidgetEntry

    var body: some View {
        ZStack {
            WidgetBackground()

            if let providerEntry = self.entry.snapshot.entries.first(where: { $0.provider == self.entry.provider }) {
                ProviderUsageContent(
                    entry: providerEntry,
                    family: self.family,
                    availableProviders: self.entry.availableProviders)
            } else {
                EmptyWidgetState()
            }
        }
        .containerBackground(.fill.tertiary, for: .widget)
        .widgetURL(widgetAppURL)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct ProviderUsageContent: View {
    let entry: WidgetSnapshot.ProviderEntry
    let family: WidgetFamily
    let availableProviders: [UsageProvider]?

    var body: some View {
        switch self.family {
        case .systemSmall:
            CompactUsageCard(entry: self.entry, availableProviders: self.availableProviders)
        default:
            ExpandedUsageCard(entry: self.entry, availableProviders: self.availableProviders)
        }
    }
}

private struct CompactUsageCard: View {
    let entry: WidgetSnapshot.ProviderEntry
    let availableProviders: [UsageProvider]?

    private var accent: Color {
        WidgetColors.color(for: self.entry.provider)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let availableProviders {
                ProviderSwitcherRow(
                    providers: availableProviders,
                    selected: self.entry.provider,
                    updatedAt: self.entry.updatedAt,
                    compact: true)
            } else {
                WidgetHeader(provider: self.entry.provider, updatedAt: self.entry.updatedAt, compact: true)
            }

            ConcentricUsageRings(
                session: self.entry.sessionWindow,
                weekly: self.entry.weeklyWindow,
                accent: self.accent,
                size: 88,
                sessionLineWidth: 14,
                weeklyLineWidth: 10)
            .frame(maxWidth: .infinity)

            HStack(spacing: 10) {
                RingLegend(
                    label: "Session",
                    value: self.shortPercent(self.entry.sessionWindow?.remainingPercent),
                    subtitle: self.entry.sessionWindow.flatMap(DisplayFormat.resetLine))
                RingLegend(
                    label: "Week",
                    value: self.shortPercent(self.entry.weeklyWindow?.remainingPercent),
                    subtitle: self.entry.weeklyWindow.flatMap(DisplayFormat.resetLine))
            }

            if let footer = self.footerText {
                Text(footer)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 12)
    }

    private func shortPercent(_ value: Double?) -> String {
        guard let value else { return "--" }
        return "\(Int(value.rounded()))%"
    }

    private var footerText: String? {
        if let credits = self.entry.creditsRemaining {
            return "Credits \(DisplayFormat.credits(credits))"
        }
        return nil
    }
}

private struct ExpandedUsageCard: View {
    let entry: WidgetSnapshot.ProviderEntry
    let availableProviders: [UsageProvider]?

    private var accent: Color {
        WidgetColors.color(for: self.entry.provider)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let availableProviders {
                ProviderSwitcherRow(
                    providers: availableProviders,
                    selected: self.entry.provider,
                    updatedAt: self.entry.updatedAt,
                    compact: false)
            } else {
                WidgetHeader(provider: self.entry.provider, updatedAt: self.entry.updatedAt, compact: false)
            }

            HStack(alignment: .center, spacing: 16) {
                ConcentricUsageRings(
                    session: self.entry.sessionWindow,
                    weekly: self.entry.weeklyWindow,
                    accent: self.accent,
                    size: 108,
                    sessionLineWidth: 16,
                    weeklyLineWidth: 11)
                .frame(width: 108, height: 108)

                VStack(alignment: .leading, spacing: 10) {
                    UsageDetailRow(
                        title: "Session",
                        value: self.shortPercent(self.entry.sessionWindow?.remainingPercent),
                        subtitle: self.entry.sessionWindow.flatMap(DisplayFormat.resetLine))
                    UsageDetailRow(
                        title: "Week",
                        value: self.shortPercent(self.entry.weeklyWindow?.remainingPercent),
                        subtitle: self.entry.weeklyWindow.flatMap(DisplayFormat.resetLine))

                    if let credits = self.entry.creditsRemaining {
                        UsageDetailRow(
                            title: "Credits",
                            value: DisplayFormat.credits(credits),
                            subtitle: nil)
                    } else if let tertiary = self.entry.tertiary, self.entry.secondary != nil {
                        UsageDetailRow(
                            title: "Extra",
                            value: self.shortPercent(tertiary.remainingPercent),
                            subtitle: DisplayFormat.resetLine(for: tertiary))
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 14)
    }

    private func shortPercent(_ value: Double?) -> String {
        guard let value else { return "--" }
        return "\(Int(value.rounded()))%"
    }

}

private struct ConcentricUsageRings: View {
    let session: RateWindow?
    let weekly: RateWindow?
    let accent: Color
    let size: CGFloat
    let sessionLineWidth: CGFloat
    let weeklyLineWidth: CGFloat

    var body: some View {
        ZStack {
            RingLayer(progress: self.ratio(for: self.session), lineWidth: self.sessionLineWidth, color: self.accent)
            RingLayer(progress: self.ratio(for: self.weekly), lineWidth: self.weeklyLineWidth, color: self.accent.opacity(0.5))
                .padding(self.sessionLineWidth + 2)
        }
        .frame(width: self.size, height: self.size)
    }

    private func ratio(for window: RateWindow?) -> Double {
        guard let window else { return 0 }
        return min(max(window.remainingPercent / 100, 0), 1)
    }
}

private struct RingLayer: View {
    let progress: Double
    let lineWidth: CGFloat
    let color: Color

    var body: some View {
        Circle()
            .stroke(Color.primary.opacity(0.08), lineWidth: self.lineWidth)
            .overlay {
                Circle()
                    .trim(from: 0, to: self.progress)
                    .stroke(
                        self.color,
                        style: StrokeStyle(lineWidth: self.lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
    }
}

private struct RingLegend: View {
    let label: String
    let value: String
    let subtitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(self.label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(self.value)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.primary)
            if let subtitle {
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.primary.opacity(0.06)))
    }
}

private struct UsageDetailRow: View {
    let title: String
    let value: String
    let subtitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline) {
                Text(self.title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(self.value)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
            }

            if let subtitle {
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct EmptyWidgetState: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Open CodexBar iOS")
                .font(.body.weight(.semibold))
            Text("Sign in once in the app, then refresh to populate the widget.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(14)
    }
}

private struct ProviderSwitcherRow: View {
    let providers: [UsageProvider]
    let selected: UsageProvider
    let updatedAt: Date
    let compact: Bool

    var body: some View {
        HStack(spacing: self.compact ? 4 : 6) {
            ForEach(self.providers, id: \.self) { provider in
                ProviderSwitchChip(
                    provider: provider,
                    selected: provider == self.selected,
                    compact: self.compact)
            }
            Spacer(minLength: 6)
            Text(DisplayFormat.updateTimestamp(self.updatedAt))
                .font(self.compact ? .caption2 : .caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.78)
        }
    }
}

private struct ProviderSwitchChip: View {
    let provider: UsageProvider
    let selected: Bool
    let compact: Bool

    var body: some View {
        let background = self.selected
            ? WidgetColors.color(for: self.provider).opacity(0.18)
            : Color.primary.opacity(0.08)

        Button(intent: SwitchWidgetProviderIntent(provider: ProviderChoice(provider: self.provider))) {
            Text(self.provider.displayName)
                .font(self.compact ? .caption2.weight(.semibold) : .caption.weight(.semibold))
                .foregroundStyle(self.selected ? Color.primary : Color.secondary)
                .padding(.horizontal, self.compact ? 6 : 8)
                .padding(.vertical, self.compact ? 3 : 4)
                .background(Capsule().fill(background))
        }
        .buttonStyle(.plain)
    }
}

private struct WidgetHeader: View {
    let provider: UsageProvider
    let updatedAt: Date
    let compact: Bool

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(self.provider.displayName)
                    .font(self.compact ? .caption.weight(.semibold) : .headline)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Text("Remaining quota")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(DisplayFormat.updateTimestamp(self.updatedAt))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}

private struct WidgetBackground: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        LinearGradient(
            colors: [
                Color(uiColor: self.colorScheme == .dark ? .secondarySystemBackground : .systemBackground),
                Color(uiColor: self.colorScheme == .dark ? .tertiarySystemBackground : .secondarySystemBackground),
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing)
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(Color.white.opacity(self.colorScheme == .dark ? 0.06 : 0.22), lineWidth: 1)
        }
        .overlay(alignment: .top) {
            LinearGradient(
                colors: [
                    Color.white.opacity(self.colorScheme == .dark ? 0.06 : 0.16),
                    .clear,
                ],
                startPoint: .top,
                endPoint: .bottom)
                .frame(height: 56)
                .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        }
    }
}

private enum WidgetColors {
    static func color(for provider: UsageProvider) -> Color {
        switch provider {
        case .codex:
            Color(red: 73 / 255, green: 163 / 255, blue: 176 / 255)
        case .claude:
            Color(red: 204 / 255, green: 124 / 255, blue: 94 / 255)
        }
    }
}

private extension WidgetSnapshot.ProviderEntry {
    var sessionWindow: RateWindow? {
        self.primary
    }

    var weeklyWindow: RateWindow? {
        self.secondary ?? self.tertiary
    }
}
