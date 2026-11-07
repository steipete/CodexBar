import AppKit
import CodexBarCore
import Foundation
import SwiftUI
import WidgetKit

/// Widget catalogs are generated from the app catalogs by sync-widget-locales.mjs.
enum WidgetLocalization {
    static let resourceBundle: Bundle = {
        #if SWIFT_PACKAGE
        return .module
        #else
        return .main
        #endif
    }()

    static var currentBundle: Bundle {
        #if SWIFT_PACKAGE
        let defaultLanguage = TestProcessSafety.isRunning ? "en" : ""
        #else
        let defaultLanguage = ""
        #endif
        let language = WidgetLocalizationOverride.language ?? defaultLanguage
        return self.bundle(language: language)
    }

    static func bundle(language: String, resourceBundle: Bundle = WidgetLocalization.resourceBundle) -> Bundle {
        let language = language.isEmpty
            ? Bundle.preferredLocalizations(from: resourceBundle.localizations).first ?? "en"
            : language
        // Native SwiftPM builds lowercase language-directory names, including region and script suffixes.
        for candidate in [language, language.lowercased()] {
            if let path = resourceBundle.path(forResource: candidate, ofType: "lproj"),
               let bundle = Bundle(path: path)
            {
                return bundle
            }
        }
        return resourceBundle
    }
}

enum WidgetLocalizationOverride {
    @TaskLocal static var language: String?
}

func W(_ key: String, _ arguments: CVarArg...) -> String {
    let bundle = WidgetLocalization.currentBundle
    var value = bundle.localizedString(forKey: key, value: nil, table: nil)
    if value.isEmpty || value == key,
       let path = WidgetLocalization.resourceBundle.path(forResource: "en", ofType: "lproj"),
       let english = Bundle(path: path)
    {
        value = english.localizedString(forKey: key, value: nil, table: nil)
    }
    let language = bundle.bundleURL.deletingPathExtension().lastPathComponent
    let locale = bundle.bundleURL.pathExtension == "lproj"
        ? Locale(identifier: language == "ar" ? "ar@numbers=arab" : language)
        : Locale.current
    return arguments.isEmpty ? value : String(format: value, locale: locale, arguments: arguments)
}

extension EnvironmentValues {
    /// Mirrors the app's "show used instead of remaining" preference into the tiles.
    @Entry var widgetUsageShowsUsed: Bool = false

    /// Snapshot-rendering seam. WidgetKit owns `widgetRenderingMode` and nothing outside a widget
    /// host can set it, so the tinted and clear appearances are unreachable from a preview without
    /// this. Always nil in the shipping widget.
    @Entry var widgetRenderingModeOverride: WidgetRenderingMode?

    /// Native previews keep selection local instead of writing shared widget preferences.
    @Entry var widgetProviderSelectionOverride: ((UsageProvider) -> Void)?
}

// MARK: - Layout metrics

/// Shared spacing and sizing for the usage and switcher tiles. Widget tiles have a fixed point
/// budget, so every value here is chosen against the macOS tile sizes (155×155, 329×155, 329×345)
/// rather than tuned by eye.
enum WidgetLayout {
    static let sectionSpacing: CGFloat = 10
    static let laneSpacing: CGFloat = 7
    static let barHeight: CGFloat = 7
    static let heroBarHeight: CGFloat = 9
    static let markSizeSmall: CGFloat = 24
    static let markSizeRegular: CGFloat = 30
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

// MARK: - Provider mark

struct ProviderMark: View {
    let provider: UsageProvider
    let isSelected: Bool
    var size: CGFloat = WidgetLayout.markSizeRegular

    @Environment(\.widgetRenderingMode) private var renderingMode
    @Environment(\.widgetRenderingModeOverride) private var renderingModeOverride

    var body: some View {
        let mode = self.renderingModeOverride ?? self.renderingMode
        let style = ProviderMarkStyle.resolve(
            renderingMode: mode,
            provider: self.provider,
            isSelected: self.isSelected)
        let image = WidgetProviderMarkAsset.image(for: self.provider, fullColor: mode == .fullColor && self.isSelected)
        ZStack {
            RoundedRectangle(cornerRadius: self.size * 0.28, style: .continuous)
                .fill(style.background)
            RoundedRectangle(cornerRadius: self.size * 0.28, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .renderingMode(image.isTemplate ? .template : .original)
                    .scaledToFit()
                    .foregroundStyle(style.foreground)
                    .padding(self.size * 0.2)
                    .widgetAccentable()
            } else {
                Text(ProviderMonogram.text(for: self.provider))
                    .font(.system(size: self.size * 0.44, weight: .bold, design: .rounded))
                    .kerning(-0.3)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .foregroundStyle(style.foreground)
            }
        }
        .frame(width: self.size, height: self.size)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(ProviderMarkLabel.text(for: self.provider, isSelected: self.isSelected)))
    }
}

/// The provider's real mark, bundled for the curated widget providers.
///
/// The files are copies of the app's own `ProviderIcon-*` and `Brand-ProviderIcon-*` resources (a test keeps
/// them byte-identical); providers without a bundled mark keep their monogram.
@MainActor
enum WidgetProviderMarkAsset {
    /// Same normalization as the app's `ProviderBrandIcon`: several marks (Kimi, MiniMax) are `1em`
    /// SVGs that NSImage reads as 1x1 points, which rasterizes them into a smudge before SwiftUI scales.
    static let size = NSSize(width: 18, height: 18)
    private static var cache: [String: NSImage] = [:]

    static func image(for provider: UsageProvider, fullColor: Bool) -> NSImage? {
        let template = ProviderDescriptorRegistry.descriptor(for: provider).branding.iconResourceName
        let names = fullColor
            ? ["Brand-ProviderIcon-" + provider.rawValue, template]
            : [template]
        for name in names {
            if let image = self.load(name, isTemplate: name == template) {
                return image
            }
        }
        return nil
    }

    private static func load(_ name: String, isTemplate: Bool) -> NSImage? {
        if let cached = self.cache[name] {
            return cached
        }
        let bundle = WidgetLocalization.resourceBundle
        let url = ["svg", "png"].lazy.compactMap { fileExtension in
            bundle.url(forResource: name, withExtension: fileExtension)
                ?? bundle.url(forResource: name, withExtension: fileExtension, subdirectory: "ProviderMarks")
        }.first
        guard let url, let image = NSImage(contentsOf: url) else { return nil }
        image.size = self.size
        image.isTemplate = isTemplate
        self.cache[name] = image
        return image
    }
}

struct ProviderMarkStyle {
    let foreground: Color
    let background: Color

    /// Desktop widgets in tinted and clear appearances render through a luminance mask, so a brand
    /// fill would collapse into a solid square. Outside full colour the mark is a bright template glyph
    /// on a faint plate, which survives the mask.
    ///
    /// In full colour the brand tint only washes the plate; it never carries the glyph's contrast. The
    /// glyph is the curated full-colour mark or the template mark in ink, so a pale tint (Gemini) or a
    /// mid tone (Codex) cannot leave a low-contrast logo.
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
        return ProviderMarkStyle(
            foreground: .primary,
            background: WidgetColors.color(for: provider.instanceID).opacity(0.16))
    }
}

enum ProviderTitle {
    static func text(for provider: UsageProvider, size _: WidgetTileSize) -> String {
        ProviderDefaults.metadata[provider]?.displayName ?? provider.rawValue.capitalized
    }
}

enum ProviderMarkLabel {
    static func text(for provider: UsageProvider, isSelected: Bool) -> String {
        let name = ProviderDefaults.metadata[provider]?.displayName ?? provider.rawValue.capitalized
        return isSelected ? W("%@, selected", name) : name
    }
}

// MARK: - Ink

/// Data marks (bars, history) are drawn in ink. Colour is reserved for one meaning: a limit that is
/// running low. Provider identity lives in the mark, not in the bars.
enum WidgetInk {
    static let data = Color.primary.opacity(0.82)

    /// Fill for a bar whose limit is running low. Full colour shows red. Tinted and clear widgets
    /// render through a luminance mask where red reads dimmer than ink, which would invert the
    /// warning, so there the low fill keeps full ink strength and joins the accent group instead.
    static func lowBar(renderingMode: WidgetRenderingMode) -> Color {
        renderingMode == .fullColor ? .red : .primary
    }
}

// MARK: - Quota bar

struct QuotaBar: View {
    let percent: Double?
    let color: Color
    /// A low limit replaces `color` with the rendering-mode-aware warning fill.
    var isLow: Bool = false
    var height: CGFloat = WidgetLayout.barHeight

    @Environment(\.widgetRenderingMode) private var renderingMode
    @Environment(\.widgetRenderingModeOverride) private var renderingModeOverride

    var body: some View {
        GeometryReader { proxy in
            let fraction = QuotaBar.fillFraction(self.percent)
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.12))
                if fraction > 0 {
                    // Floor the fill at the bar's own height so a nearly-exhausted lane reads as a
                    // visible nub instead of a sliver indistinguishable from an empty track.
                    Capsule()
                        .fill(self.isLow
                            ? WidgetInk.lowBar(renderingMode: self.renderingModeOverride ?? self.renderingMode)
                            : self.color)
                        .widgetAccentable(self.isLow)
                        .frame(width: max(self.height, fraction * proxy.size.width))
                }
            }
        }
        .frame(height: self.height)
    }

    nonisolated static func fillFraction(_ percent: Double?) -> Double {
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
                Text(W(self.title))
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
                QuotaBar(
                    percent: self.percent,
                    color: self.color,
                    isLow: QuotaSeverity.isLow(remaining: self.remainingPercent))
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
    var caption: Text?
    var detail: Text?
    /// Percentage for the accompanying bar. `nil` draws no bar.
    var barPercent: Double?
    var isLow: Bool = false
    var color: Color = .secondary
    var numberSize: CGFloat = 34
    var compact: Bool = false
    var inlineQuotaTitle: String?

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
            if let title = self.inlineQuotaTitle {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(title)
                            .font(.headline)
                            .foregroundStyle(self.unavailableAwareColor)
                            .fixedSize()
                        Spacer(minLength: 4)
                        self.detail?
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.trailing)
                            // Native live date text needs a finite proposal for ViewThatFits in WidgetKit.
                            .frame(width: 120, alignment: .trailing)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                            .font(.headline)
                            .foregroundStyle(self.unavailableAwareColor)
                            .lineLimit(2)
                            .minimumScaleFactor(0.75)
                        self.detail?.font(.caption2).foregroundStyle(.secondary)
                    }
                }
            } else if self.compact {
                HStack(alignment: .center, spacing: 5) {
                    self.valueText
                    self.caption?
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .minimumScaleFactor(0.75)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                self.valueText
                if let caption = self.caption {
                    caption
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                }
            }
            if self.inlineQuotaTitle == nil, let detail = self.detail {
                detail
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            if let barPercent = self.barPercent {
                QuotaBar(
                    percent: barPercent,
                    color: self.color,
                    isLow: self.isLow,
                    height: self.compact ? 6 : WidgetLayout.heroBarHeight)
                    .padding(.top, self.compact ? 2 : 5)
            }
        }
    }

    private var valueText: some View {
        Text(self.value)
            .font(.system(
                size: self.isUnavailable ? self.numberSize * 0.5 : self.numberSize,
                weight: .semibold,
                design: .rounded))
            .monospacedDigit()
            .foregroundStyle(self.unavailableAwareColor)
            .lineLimit(1)
            .minimumScaleFactor(0.5)
    }
}

// MARK: - Value rows

/// A right-aligned figure with a muted label, used for cost and credit rows.
struct MetricLine: View {
    let title: Text
    let value: String
    var isProminent: Bool = false

    var body: some View {
        HStack(spacing: 6) {
            self.title
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
                ProviderMark(
                    provider: provider,
                    isSelected: true,
                    size: self.size == .small ? WidgetLayout.markSizeSmall : WidgetLayout.markSizeRegular)
            }
            // Small tiles stack freshness under the name, beside the mark, which leaves room for the
            // quota lanes below the headline.
            VStack(alignment: .leading, spacing: 0) {
                Text(self.displayName)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(self.size == .small ? 1 : 2)
                    .minimumScaleFactor(self.size == .small ? 0.7 : 0.85)
                if self.size == .small {
                    FreshnessLabel(updatedAt: self.updatedAt)
                }
            }
            .layoutPriority(1)
            Spacer(minLength: 0)
            if self.size != .small {
                FreshnessLabel(updatedAt: self.updatedAt)
            }
        }
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
        // WidgetKit advances native date text between reloads; a formatted TimelineView string can freeze.
        // fixedSize on live date text can erase the rest of the tile.
        WidgetDateText.offset(self.updatedAt)
            .font(.caption2)
            .foregroundStyle(WidgetFreshness
                .isStale(self.updatedAt) ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.secondary))
            .lineLimit(1)
    }
}

enum WidgetDateText {
    static func offset(_ date: Date) -> Text {
        if #available(macOS 15, *) {
            return Text(.currentDate, format: self.ageFormat(date))
        }
        return Text(date, style: .relative)
    }

    @available(macOS 15, *)
    static func ageFormat(_ date: Date) -> SystemFormatStyle.DateOffset {
        .init(to: date, allowedFields: [.day, .hour, .minute], maxFieldCount: 2, sign: .never)
    }

    static func reset(_ date: Date) -> Text {
        if #available(macOS 15, *) {
            // System date references update visually in the out-of-process WidgetKit host.
            return Text(
                "Resets \(Text(.currentDate, format: self.resetFormat(date)))",
                bundle: WidgetLocalization.currentBundle)
        }
        return Text("Resets in \(Text(date, style: .relative))", bundle: WidgetLocalization.currentBundle)
    }

    @available(macOS 15, *)
    static func resetFormat(_ date: Date) -> SystemFormatStyle.DateReference {
        .init(to: date, allowedFields: [.day, .hour, .minute], maxFieldCount: 2, thresholdField: .minute)
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
            Text(W("Open CodexBar"))
                .font(.subheadline.weight(.semibold))
            Text(self.message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
