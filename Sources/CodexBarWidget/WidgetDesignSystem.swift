import CodexBarCore
import SwiftUI
import WidgetKit

extension EnvironmentValues {
    /// Mirrors the app's "show used instead of remaining" preference into the tiles.
    @Entry var widgetUsageShowsUsed: Bool = false

    /// Snapshot-rendering seam. WidgetKit owns `widgetRenderingMode` and nothing outside a widget
    /// host can set it, so the tinted and clear appearances are unreachable from a preview without
    /// this. Always nil in the shipping widget.
    @Entry var widgetRenderingModeOverride: WidgetRenderingMode?
}

// MARK: - Layout metrics

/// Shared spacing and sizing for the usage and switcher tiles. Widget tiles have a fixed point
/// budget, so every value here is chosen against the macOS tile sizes (155×155, 329×155, 329×345)
/// rather than tuned by eye.
enum WidgetLayout {
    static let tilePadding: CGFloat = 14
    static let sectionSpacing: CGFloat = 10
    static let laneSpacing: CGFloat = 7
    static let barHeight: CGFloat = 7
    static let heroBarHeight: CGFloat = 9
    static let markSizeSmall: CGFloat = 20
    static let markSizeRegular: CGFloat = 23
    static let separatorOpacity: Double = 0.12

    /// The single-metric tile has no lanes to fit around, so its figure runs larger.
    static let compactMetricNumberSize: CGFloat = 36

    /// Remaining percentage at or below which a lane is called out in red.
    static let lowQuotaThreshold: Double = 10
}

// MARK: - Provider monograms

/// Two-character provider marks.
///
/// Widget tiles are far too narrow for provider display names — the previous chips wrapped
/// mid-word on large and truncated to a single ambiguous glyph on small — so the switcher renders
/// a fixed-width monogram that can never wrap or truncate.
enum ProviderMonogram {
    /// Provider-specific by design: the widget-selectable providers get curated marks because a
    /// mechanical abbreviation collides (Codex/Copilot/Cursor/Claude all start with "C").
    private static let curated: [UsageProvider: String] = [
        .alibaba: "AL",
        .alibabatokenplan: "AT",
        .antigravity: "AG",
        .claude: "CL",
        .codex: "CX",
        .copilot: "CP",
        .cursor: "CU",
        .devin: "DV",
        .gemini: "GE",
        .kilo: "KL",
        .kimi: "KM",
        .minimax: "MX",
        .mistral: "MS",
        .opencode: "OC",
        .opencodego: "OG",
        .qwencloud: "QW",
        .zai: "ZA",
    ]

    static func text(for provider: UsageProvider) -> String {
        if let curated = self.curated[provider] { return curated }
        let name = ProviderDefaults.metadata[provider]?.shortDisplayName ?? provider.rawValue
        return self.derived(from: name)
    }

    /// Initials for a two-word name, otherwise the first two letters. Never empty.
    static func derived(from name: String) -> String {
        let words = name.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        if words.count >= 2, let first = words[0].first, let second = words[1].first {
            return String([first, second]).uppercased()
        }
        let letters = Array(words.first ?? "")
        guard let first = letters.first else { return "?" }
        return String([first, letters.dropFirst().first ?? first]).uppercased()
    }
}

// MARK: - Contrast

enum WidgetContrast {
    /// Black-vs-white crossover for WCAG relative luminance: below this a white label wins, above
    /// it a black label wins. Solving 1.05/(L+0.05) = (L+0.05)/0.05 gives L ≈ 0.1791.
    private static let crossoverLuminance: Double = 0.1791

    /// Highest-contrast label colour for text drawn on `color`. Brand palettes span very light
    /// (Gemini lilac) to mid (Claude terracotta); picking per colour keeps every mark legible.
    static func label(on color: ProviderColor) -> Color {
        self.relativeLuminance(of: color) > self.crossoverLuminance ? .black : .white
    }

    static func relativeLuminance(of color: ProviderColor) -> Double {
        func linear(_ value: Double) -> Double {
            let clamped = min(1, max(0, value))
            return clamped <= 0.03928 ? clamped / 12.92 : pow((clamped + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(color.red) + 0.7152 * linear(color.green) + 0.0722 * linear(color.blue)
    }
}

// MARK: - Provider mark

struct ProviderMark: View {
    let provider: UsageProvider
    let isSelected: Bool
    var size: CGFloat = WidgetLayout.markSizeRegular

    @Environment(\.widgetRenderingMode) private var renderingMode
    @Environment(\.widgetRenderingModeOverride) private var renderingModeOverride

    var body: some View {
        let style = ProviderMarkStyle.resolve(
            renderingMode: self.renderingModeOverride ?? self.renderingMode,
            provider: self.provider,
            isSelected: self.isSelected)
        Text(ProviderMonogram.text(for: self.provider))
            .font(.system(size: self.size * 0.44, weight: .bold, design: .rounded))
            .kerning(-0.3)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .foregroundStyle(style.foreground)
            .frame(width: self.size, height: self.size)
            .background(
                RoundedRectangle(cornerRadius: self.size * 0.3, style: .continuous)
                    .fill(style.background))
            .accessibilityLabel(Text(ProviderMarkLabel.text(for: self.provider, isSelected: self.isSelected)))
    }
}

struct ProviderMarkStyle {
    let foreground: Color
    let background: Color

    /// Desktop widgets in tinted and clear appearances render through a luminance mask, so a brand
    /// fill carrying a dark label collapses to an empty white square — the monogram disappears
    /// entirely. Outside full colour the mark inverts: a faint plate with a bright label, which
    /// survives the mask.
    static func resolve(
        renderingMode: WidgetRenderingMode,
        provider: UsageProvider,
        isSelected: Bool) -> ProviderMarkStyle
    {
        guard renderingMode == .fullColor else {
            return ProviderMarkStyle(
                foreground: isSelected ? .primary : .primary.opacity(0.7),
                background: .primary.opacity(isSelected ? 0.22 : 0.1))
        }
        guard isSelected else {
            return ProviderMarkStyle(
                foreground: .primary.opacity(0.62),
                background: .primary.opacity(0.08))
        }
        let brand = ProviderBrandColor.resolve(for: provider.instanceID)
        return ProviderMarkStyle(
            foreground: brand.map(WidgetContrast.label(on:)) ?? .white,
            background: WidgetColors.color(for: provider.instanceID))
    }
}

enum ProviderTitle {
    /// Roughly what fits beside the mark and the pager control on a 155pt tile at subheadline size.
    static let compactCharacterBudget = 13

    /// The provider name a tile of this size can print in full. Small tiles fall back to the
    /// provider's own short name rather than truncating — a clipped identifier is exactly what this
    /// header exists to avoid.
    static func text(for provider: UsageProvider, size: WidgetTileSize) -> String {
        let metadata = ProviderDefaults.metadata[provider]
        let name = metadata?.displayName ?? provider.rawValue.capitalized
        guard size == .small, name.count > self.compactCharacterBudget else { return name }
        let short = metadata?.shortDisplayName ?? name
        return short.count < name.count ? short : name
    }
}

enum ProviderMarkLabel {
    static func text(for provider: UsageProvider, isSelected: Bool) -> String {
        let name = ProviderDefaults.metadata[provider]?.displayName ?? provider.rawValue.capitalized
        return isSelected ? "\(name), selected" : name
    }
}

enum ProviderBrandColor {
    /// The raw brand colour behind `WidgetColors.color(for:)`, needed for contrast maths.
    static func resolve(for instanceID: ProviderInstanceID) -> ProviderColor? {
        guard let provider = instanceID.firstPartyProvider else { return nil }
        return ProviderAccentColors.sharedOverride(for: instanceID)
            ?? ProviderDescriptorRegistry.descriptor(for: provider).branding.widgetColor
    }
}

// MARK: - Quota bar

struct QuotaBar: View {
    let percent: Double?
    let color: Color
    var height: CGFloat = WidgetLayout.barHeight

    var body: some View {
        GeometryReader { proxy in
            let fraction = QuotaBar.fillFraction(self.percent)
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.12))
                if fraction > 0 {
                    // Floor the fill at the bar's own height so a nearly-exhausted lane reads as a
                    // visible nub instead of a sliver indistinguishable from an empty track.
                    Capsule()
                        .fill(self.color)
                        .frame(width: max(self.height, fraction * proxy.size.width))
                }
            }
        }
        .frame(height: self.height)
    }

    static func fillFraction(_ percent: Double?) -> Double {
        guard let percent else { return 0 }
        return min(1, max(0, percent / 100))
    }
}

// MARK: - Quota lanes

/// One quota lane rendered as label + value + bar. The value carries the visual weight; the
/// previous design had it dimmer than its own label.
struct QuotaLaneView: View {
    let title: String
    let percent: Double?
    let remainingPercent: Double?
    let color: Color
    var showsBar: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(self.title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 4)
                Text(WidgetFormat.percent(self.percent))
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(QuotaSeverity.isLow(remaining: self.remainingPercent) ? Color.red : Color.primary)
                    .lineLimit(1)
            }
            if self.showsBar {
                QuotaBar(percent: self.percent, color: self.color)
            }
        }
    }
}

enum QuotaSeverity {
    static func isLow(remaining: Double?) -> Bool {
        guard let remaining else { return false }
        return remaining <= WidgetLayout.lowQuotaThreshold
    }
}

/// The tile's headline: one large figure, what it measures, and when it frees up.
///
/// Tiles lead with the *binding* quota — the lane with the least left — because that is the number
/// that decides whether the user can keep working. The old tiles gave every lane identical weight,
/// so a lane at 3% and a lane at 97% looked equally routine.
struct HeroBlock: View {
    let value: String
    var caption: String?
    var detail: String?
    /// Percentage for the accompanying bar. `nil` draws no bar.
    var barPercent: Double?
    var isLow: Bool = false
    var color: Color = .secondary
    var numberSize: CGFloat = 34
    /// Pushes the bar to the bottom of the available height so a column tile has no dead space
    /// under the headline.
    var spreads: Bool = false

    var isUnavailable: Bool {
        self.value == WidgetFormat.unavailable
    }

    private var unavailableAwareColor: Color {
        if self.isUnavailable { return .secondary }
        return self.isLow ? .red : .primary
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            // A missing figure is drawn small and muted: at headline size the em-dash placeholder
            // reads as a heavy black bar, which looks like a broken tile rather than "no data".
            Text(self.value)
                .font(.system(
                    size: self.isUnavailable ? self.numberSize * 0.5 : self.numberSize,
                    weight: .semibold,
                    design: .rounded))
                .monospacedDigit()
                .foregroundStyle(self.unavailableAwareColor)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
            if let caption = self.caption {
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            if let detail = self.detail {
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            if let barPercent = self.barPercent {
                if self.spreads {
                    Spacer(minLength: 5)
                }
                QuotaBar(percent: barPercent, color: self.color, height: WidgetLayout.heroBarHeight)
                    .padding(.top, self.spreads ? 0 : 5)
            }
        }
    }
}

// MARK: - Value rows

/// A right-aligned figure with a muted label, used for cost and credit rows.
struct MetricLine: View {
    let title: String
    let value: String
    var isProminent: Bool = false

    var body: some View {
        HStack(spacing: 6) {
            Text(self.title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            Text(self.value)
                .font(self.isProminent ? .caption.weight(.semibold) : .caption)
                .monospacedDigit()
                .foregroundStyle(self.isProminent ? Color.primary : Color.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .allowsTightening(true)
                .layoutPriority(1)
        }
    }
}

struct WidgetSeparator: View {
    var body: some View {
        Rectangle()
            .fill(Color.primary.opacity(WidgetLayout.separatorOpacity))
            .frame(height: 1)
    }
}

// MARK: - Header

/// Mark + provider name + freshness. The name is the only text on its line so it never has to
/// compete with the timestamp for space.
struct TileHeader: View {
    let provider: ProviderInstanceID
    let updatedAt: Date
    var size: WidgetTileSize = .medium

    var body: some View {
        HStack(spacing: 7) {
            if let provider = self.provider.firstPartyProvider {
                ProviderMark(provider: provider, isSelected: true, size: WidgetLayout.markSizeSmall)
            }
            Text(self.displayName)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .layoutPriority(1)
            Spacer(minLength: 4)
            if self.showsFreshness {
                FreshnessLabel(updatedAt: self.updatedAt)
            }
        }
    }

    /// A small tile cannot fit the provider name and the timestamp side by side — the name used to
    /// lose, leaving "C…". The name always wins; on small the timestamp appears only once the data
    /// is stale enough to matter.
    private var showsFreshness: Bool {
        self.size != .small || WidgetFreshness.isStale(self.updatedAt)
    }

    private var displayName: String {
        guard let provider = self.provider.firstPartyProvider else {
            return self.provider.rawValue.capitalized
        }
        return ProviderTitle.text(for: provider, size: self.size)
    }
}

/// Snapshot age. Turns amber past a day so a silently stale tile cannot be mistaken for live data.
struct FreshnessLabel: View {
    let updatedAt: Date

    var body: some View {
        Text(WidgetFormat.shortRelativeDate(self.updatedAt))
            .font(.caption2)
            .foregroundStyle(WidgetFreshness
                .isStale(self.updatedAt) ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.secondary))
            .lineLimit(1)
            .fixedSize()
    }
}

enum WidgetFreshness {
    static let staleThreshold: TimeInterval = 24 * 60 * 60

    static func isStale(_ updatedAt: Date, now: Date = Date()) -> Bool {
        now.timeIntervalSince(updatedAt) > self.staleThreshold
    }
}

// MARK: - Empty state

struct WidgetEmptyState: View {
    let message: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Open CodexBar")
                .font(.subheadline.weight(.semibold))
            Text(self.message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
