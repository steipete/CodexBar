import AppKit
import CodexBarCore
import SwiftUI
import WidgetKit

// MARK: - Entry View

struct BurnDownWidgetView: View {
    let entry: BurnDownEntry

    var body: some View {
        let state = BurnDownState(
            snapshot: self.entry.snapshot,
            provider: self.entry.provider,
            selection: self.entry.window)

        Group {
            if let state, let window = state.selectedWindow {
                BurnDownLayout(
                    window: window,
                    provider: self.entry.provider,
                    blankChart: state.blankPrimaryChart,
                    resetsAtOverride: state.selectedResetOverride)
            } else {
                self.emptyState
            }
        }
        .containerBackground(for: .widget) {
            BurnWidgetBackground()
        }
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Text("Open CodexBar")
                .font(.body)
                .fontWeight(.semibold)
            Text("Usage data will appear once the app refreshes.")
                .font(.caption)
                .multilineTextAlignment(.center)
                .opacity(0.55)
        }
        .padding(12)
    }
}

// MARK: - Main Layout

private struct BurnDownLayout: View {
    @Environment(\.widgetRenderingMode) private var renderingMode
    @Environment(\.colorScheme) private var colorScheme

    let window: RateWindow
    let provider: UsageProvider
    /// True when the session window is blocked because the weekly budget is exhausted:
    /// suppress the chart and retarget "Resets in" to the weekly reset.
    var blankChart = false
    /// When set, "Resets in" counts down to this date (the weekly reset) instead of the
    /// session window's own reset.
    var resetsAtOverride: Date?

    var body: some View {
        let dark = self.colorScheme == .dark
        let isMonochrome = self.renderingMode != .fullColor
        let geom = BurnGeom(window: self.window)
        let theme = BurnTheme(provider: self.provider, geom: geom, dark: dark, isMonochrome: isMonochrome)
        let windowMins = self.window.windowMinutes ?? 300
        let isDailyWindow = windowMins >= 1440
        let now = Date()
        let estimatedResetMinutes = self.blankChart || geom.tNow >= 1
            ? nil
            : (1 - geom.tNow) * Double(windowMins)
        let explicitReset = self.blankChart
            ? self.resetsAtOverride
            : self.resetsAtOverride ?? self.window.resetsAt
        let effectiveResetAt = burnEffectiveResetDate(
            explicitResetAt: explicitReset,
            estimatedResetMinutes: estimatedResetMinutes,
            now: now)
        let resetsIn = effectiveResetAt.map { max(0, $0.timeIntervalSince(now) / 60) } ?? 0
        let outInMins = geom.slope < -0.01 ? (geom.vNow / -geom.slope) * Double(windowMins) : Double.infinity
        // Very early in the window a single sample can't forecast a credible run-out: a
        // tiny burst right after reset extrapolates to "runs dry in minutes" even at ~99%
        // remaining. Match the design's fresh-window behaviour ("Runs out: after reset")
        // and only surface the estimate once enough of the window has elapsed to trust the
        // average burn rate.
        let windowEstablished = geom.tNow >= 0.08
        let runsDryBefore = geom.runsOut && outInMins < resetsIn && windowEstablished

        let sign = geom.margin >= 0 ? "+" : "−"
        let badgeNum = "\(sign)\(abs(Int(geom.margin.rounded())))%"
        // Per the design's edge states, "fresh" and "spent" show only the glyph + word
        // (◆ full / ■ spent) with no pace number — the margin is meaningless once the
        // budget is full or gone.
        let showBadgeNumber = !geom.depleted && !geom.fresh
        let statusWord: String = geom.depleted ? "spent" : geom.fresh ? "full"
            : geom.status == .ahead ? "conserving" : geom.status == .behind ? "over pace" : "on pace"
        let arrow: String = geom.depleted ? "■" : geom.fresh ? "◆"
            : geom.status == .ahead ? "▲" : geom.status == .behind ? "▼" : "●"

        let axisDates = burnAxisDateRange(
            effectiveResetAt: effectiveResetAt,
            windowMinutes: windowMins,
            now: now)
        let startLabel = burnAxisLabel(axisDates.start, isDailyWindow: isDailyWindow)
        let resetLabel = burnAxisLabel(axisDates.reset, isDailyWindow: isDailyWindow)

        VStack(spacing: 0) {
            // Header: brand + pace badge
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(theme.brandDot)
                            .frame(width: 7, height: 7)
                            .shadow(color: theme.brandDot.opacity(0.7), radius: 3.5)
                        Text(burnProviderName(self.provider))
                            .font(.system(size: 14.5, weight: .semibold))
                            .foregroundStyle(theme.text)
                            .lineLimit(1)
                    }
                    Text(burnWindowLabel(self.window.windowMinutes))
                        .font(.system(size: 11))
                        .foregroundStyle(theme.sub)
                        .kerning(0.2)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 1) {
                    if showBadgeNumber {
                        Text(badgeNum)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(theme.statusColor)
                            .monospacedDigit()
                    }
                    HStack(spacing: 3) {
                        Text(arrow)
                            .font(.system(size: 8))
                            .foregroundStyle(theme.statusColor)
                        Text(statusWord)
                            .font(.system(size: 10.5))
                            .foregroundStyle(theme.sub)
                    }
                }
            }

            // Body: stats + hero / chart
            HStack(alignment: .bottom, spacing: 13) {
                // Left: stats + hero %
                VStack(alignment: .leading, spacing: 0) {
                    VStack(spacing: 5) {
                        BurnResetStatRow(resetAt: effectiveResetAt, theme: theme)
                        BurnStatRow(
                            label: geom.depleted ? "Ran out" : runsDryBefore ? "Runs out in" : "Runs out",
                            value: geom
                                .depleted ? "budget spent" : runsDryBefore ? "~\(burnFmtDuration(outInMins))" :
                                "after reset",
                            theme: theme,
                            danger: geom.depleted || runsDryBefore)
                    }
                    .padding(.top, 8)

                    Spacer()

                    HStack(alignment: .lastTextBaseline, spacing: 5) {
                        Text("\(Int(geom.vNow.rounded()))")
                            .font(.system(size: 41, weight: .semibold))
                            .foregroundStyle(geom.depleted ? theme.danger : theme.text)
                            .monospacedDigit()
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                        Text("%")
                            .font(.system(size: 19, weight: .medium))
                            .foregroundStyle(theme.sub)
                        Text("left")
                            .font(.system(size: 11))
                            .foregroundStyle(theme.sub)
                    }
                }
                .frame(width: 143, alignment: .leading)

                // Right: chart + axis. Blanked when the session window is blocked by the
                // weekly cap — there's no session burn to chart until the weekly resets.
                VStack(spacing: 2) {
                    if self.blankChart {
                        Color.clear.frame(height: 84)
                        Color.clear.frame(height: 13)
                    } else {
                        BurnChartCanvas(
                            geom: geom,
                            theme: theme)
                            .frame(height: 84)

                        BurnAxisRow(
                            startLabel: startLabel,
                            resetLabel: resetLabel,
                            tNow: geom.tNow,
                            theme: theme)
                            .frame(height: 13)
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal, 15)
        .padding(.top, 13)
        .padding(.bottom, 12)
    }
}

// MARK: - Stat Row

private struct BurnStatRow: View {
    let label: String
    let value: String
    let theme: BurnTheme
    let danger: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(self.label)
                .font(.system(size: 11.5))
                .foregroundStyle(self.theme.sub)
            Spacer()
            Text(self.value)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(self.danger ? self.theme.danger : self.theme.text)
                .monospacedDigit()
                .lineLimit(1)
        }
    }
}

private struct BurnResetStatRow: View {
    let resetAt: Date?
    let theme: BurnTheme

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Resets in")
                .font(.system(size: 11.5))
                .foregroundStyle(self.theme.sub)
            Spacer()
            if let resetAt {
                Text(resetAt, style: .relative)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(self.theme.text)
                    .monospacedDigit()
                    .lineLimit(1)
            } else {
                Text("—")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(self.theme.text)
            }
        }
    }
}

// MARK: - Axis Row

private struct BurnAxisRow: View {
    let startLabel: String
    let resetLabel: String
    let tNow: Double
    let theme: BurnTheme

    var body: some View {
        GeometryReader { geo in
            // Hide "now" when it would collide with the start/reset labels. The edge labels
            // are anchored to the ends, so estimate their widths (≈9.5pt monospaced digits)
            // and only show "now" when it clears both with a small gap — otherwise the
            // now-dot on the chart already conveys position. Matches the design's rule that
            // "now" hides near an end label.
            let w = geo.size.width
            let approxChar: CGFloat = 5.8
            let nowX = self.tNow * w
            let nowHalf: CGFloat = 13
            let gap: CGFloat = 6
            let clearsStart = nowX - nowHalf > CGFloat(self.startLabel.count) * approxChar + gap
            let clearsReset = nowX + nowHalf < w - CGFloat(self.resetLabel.count) * approxChar - gap
            let showNow = self.tNow > 0.05 && self.tNow < 0.95 && clearsStart && clearsReset

            ZStack(alignment: .leading) {
                Text(self.startLabel)
                    .font(.system(size: 9.5))
                    .foregroundStyle(self.theme.sub)
                    .monospacedDigit()
                    .frame(maxWidth: .infinity, alignment: .leading)

                if showNow {
                    Text("now")
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(self.theme.text)
                        .position(x: nowX, y: geo.size.height / 2)
                }

                Text(self.resetLabel)
                    .font(.system(size: 9.5))
                    .foregroundStyle(self.theme.sub)
                    .monospacedDigit()
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
    }
}

// MARK: - Chart Canvas

private struct BurnChartCanvas: View {
    let geom: BurnGeom
    let theme: BurnTheme

    var body: some View {
        Canvas { context, size in
            let w = size.width
            let h = size.height
            let padT: CGFloat = 8
            let padB: CGFloat = 2
            let padL: CGFloat = 1
            let padR: CGFloat = 1

            func X(_ t: Double) -> CGFloat {
                padL + CGFloat(t) * (w - padL - padR)
            }
            func Y(_ v: Double) -> CGFloat {
                padT + CGFloat(1 - v / 100) * (h - padT - padB)
            }

            let tNow = self.geom.tNow
            let vNow = self.geom.vNow

            // --- Now vertical hairline ---
            do {
                var p = Path()
                p.move(to: CGPoint(x: X(tNow), y: Y(100)))
                p.addLine(to: CGPoint(x: X(tNow), y: Y(0)))
                context.stroke(p, with: .color(self.theme.chartGrid), lineWidth: 1)
            }

            // --- Baseline ---
            do {
                var p = Path()
                p.move(to: CGPoint(x: X(0), y: Y(0)))
                p.addLine(to: CGPoint(x: X(1), y: Y(0)))
                context.stroke(p, with: .color(self.theme.chartGrid), lineWidth: 1)
            }

            // --- Area fill (gradient from actual line down to baseline) ---
            do {
                var p = Path()
                p.move(to: CGPoint(x: X(0), y: Y(100)))
                p.addLine(to: CGPoint(x: X(tNow), y: Y(vNow)))
                p.addLine(to: CGPoint(x: X(tNow), y: Y(0)))
                p.addLine(to: CGPoint(x: X(0), y: Y(0)))
                p.closeSubpath()

                let gradient = Gradient(stops: [
                    .init(color: self.theme.chartFillTop.opacity(self.theme.chartFillTopOpacity), location: 0),
                    .init(color: self.theme.chartFillTop.opacity(0), location: 0.92),
                ])
                context.fill(
                    p,
                    with: .linearGradient(
                        gradient,
                        startPoint: CGPoint(x: 0, y: padT),
                        endPoint: CGPoint(x: 0, y: h)))
            }

            // --- Ideal line (dashed, knocked back) ---
            do {
                var p = Path()
                p.move(to: CGPoint(x: X(0), y: Y(100)))
                p.addLine(to: CGPoint(x: X(1), y: Y(0)))
                context.stroke(
                    p,
                    with: .color(self.theme.chartIdeal),
                    style: StrokeStyle(lineWidth: 1.4, lineCap: .round, dash: [2.5, 3]))
            }

            // --- Projection (fine dotted) ---
            if self.geom.slope < -0.01 {
                var p = Path()
                p.move(to: CGPoint(x: X(tNow), y: Y(vNow)))
                p.addLine(to: CGPoint(x: X(self.geom.projT), y: Y(self.geom.projV)))
                context.stroke(
                    p,
                    with: .color(self.theme.chartProj.opacity(0.95)),
                    style: StrokeStyle(lineWidth: 1.6, lineCap: .round, dash: [0.5, 3.5]))
            }

            // --- Actual line (solid, hero) ---
            do {
                var p = Path()
                p.move(to: CGPoint(x: X(0), y: Y(100)))
                p.addLine(to: CGPoint(x: X(tNow), y: Y(vNow)))
                context.stroke(
                    p,
                    with: .color(self.theme.chartLine),
                    style: StrokeStyle(lineWidth: 2.4, lineCap: .round, lineJoin: .round))
            }

            // --- Now dot (filled, with ring punched in bg color) ---
            let dotCenter = CGPoint(x: X(tNow), y: Y(vNow))
            let ringPath = Path(ellipseIn: CGRect(
                x: dotCenter.x - 5.4, y: dotCenter.y - 5.4, width: 10.8, height: 10.8))
            context.fill(ringPath, with: .color(self.theme.chartNowRing))
            let dotPath = Path(ellipseIn: CGRect(
                x: dotCenter.x - 3.4, y: dotCenter.y - 3.4, width: 6.8, height: 6.8))
            context.fill(dotPath, with: .color(self.theme.chartNowDot))
        }
    }
}

// MARK: - Background

struct BurnWidgetBackground: View {
    @Environment(\.widgetRenderingMode) private var renderingMode
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        if self.renderingMode == .fullColor {
            let dark = self.colorScheme == .dark
            LinearGradient(
                colors: dark
                    ? [BurnPalette.darkBgTop, BurnPalette.darkBgBottom]
                    : [BurnPalette.lightBgTop, BurnPalette.lightBgBottom],
                startPoint: .init(x: 0.15, y: 0),
                endPoint: .init(x: 0.85, y: 1))
                .overlay(alignment: .top) {
                    LinearGradient(
                        colors: [
                            Color.white.opacity(dark ? 0.04 : 0.60),
                            Color.white.opacity(0),
                        ],
                        startPoint: .top,
                        endPoint: .center)
                }
        } else {
            Color.clear
        }
    }
}

// MARK: - Theme

struct BurnTheme {
    let text: Color
    let sub: Color
    let hair: Color
    let accent: Color
    let statusColor: Color
    let danger: Color
    let brandDot: Color
    let chartLine: Color
    let chartFillTop: Color
    let chartFillTopOpacity: Double
    let chartIdeal: Color
    let chartProj: Color
    let chartGrid: Color
    let chartNowDot: Color
    let chartNowRing: Color

    init(provider: UsageProvider, geom: BurnGeom, dark: Bool, isMonochrome: Bool) {
        if isMonochrome {
            let fg = dark ? Color.white : Color.black
            self.text = fg.opacity(dark ? 0.95 : 0.90)
            self.sub = fg.opacity(dark ? 0.50 : 0.46)
            self.hair = fg.opacity(dark ? 0.13 : 0.11)
            self.accent = fg.opacity(dark ? 0.95 : 0.85)
            self.statusColor = fg.opacity(dark ? 0.90 : 0.80)
            self.danger = fg.opacity(dark ? 0.95 : 0.85)
            self.brandDot = fg.opacity(dark ? 0.85 : 0.72)
            self.chartLine = fg.opacity(dark ? 0.95 : 0.85)
            self.chartFillTop = fg.opacity(dark ? 0.95 : 0.85)
            self.chartFillTopOpacity = dark ? 0.20 : 0.16
            self.chartIdeal = fg.opacity(dark ? 0.36 : 0.30)
            self.chartProj = fg.opacity(dark ? 0.60 : 0.48)
            self.chartGrid = fg.opacity(dark ? 0.12 : 0.10)
            self.chartNowDot = fg.opacity(dark ? 1.0 : 0.92)
            self.chartNowRing = dark
                ? Color(red: 0.10, green: 0.10, blue: 0.12).opacity(0.92)
                : Color(red: 0.96, green: 0.96, blue: 0.97).opacity(0.95)
        } else {
            let accentColor = Self.accentColor(geom.status, dark: dark)
            self.accent = accentColor
            self.statusColor = accentColor
            self.text = dark ? Color.white.opacity(0.98) : Color(white: 0.20)
            self.sub = dark ? Color(white: 0.60) : Color(white: 0.45)
            self.hair = dark ? Color.white.opacity(0.10) : Color.black.opacity(0.09)
            self.danger = BurnPalette.behindDark
            self.brandDot = Self.brandDotColor(provider)
            self.chartLine = accentColor
            self.chartFillTop = accentColor
            self.chartFillTopOpacity = dark ? 0.30 : 0.22
            self.chartIdeal = dark ? Color.white.opacity(0.45) : Color.black.opacity(0.50)
            // Projection goes red when behind (the one allowed color cue in full-color mode)
            self.chartProj = geom.status == .behind ? BurnPalette.behindDark : accentColor
            self.chartGrid = dark ? Color.white.opacity(0.10) : Color.black.opacity(0.09)
            self.chartNowDot = accentColor
            self.chartNowRing = dark ? BurnPalette.darkBgBottom : BurnPalette.lightBgBottom
        }
    }

    private static func accentColor(_ status: BurnGeom.Status, dark: Bool) -> Color {
        switch status {
        case .ahead: dark ? BurnPalette.aheadDark : BurnPalette.aheadLight
        case .onpace: dark ? BurnPalette.onpaceDark : BurnPalette.onpaceLight
        case .behind: dark ? BurnPalette.behindDark : BurnPalette.behindLight
        }
    }

    private static func brandDotColor(_ provider: UsageProvider) -> Color {
        switch provider {
        case .claude: BurnPalette.claudeDot
        case .codex: BurnPalette.codexDot
        case .gemini: BurnPalette.geminiDot
        default: BurnPalette.genericDot
        }
    }
}

// MARK: - Palette

enum BurnPalette {
    // Status accents — approximated from OKLCH (L=0.80 dark, L=0.62 light)
    // oklch(0.80 0.15 152) / oklch(0.62 0.15 152) — green
    static let aheadDark = Color(red: 0.306, green: 0.800, blue: 0.506)
    static let aheadLight = Color(red: 0.192, green: 0.620, blue: 0.376)
    // oklch(0.80 0.11 236) / oklch(0.62 0.11 236) — blue
    static let onpaceDark = Color(red: 0.408, green: 0.668, blue: 0.910)
    static let onpaceLight = Color(red: 0.264, green: 0.474, blue: 0.712)
    // oklch(0.72 0.19 26) / oklch(0.60 0.19 26) — red-orange
    static let behindDark = Color(red: 0.922, green: 0.420, blue: 0.227)
    static let behindLight = Color(red: 0.762, green: 0.294, blue: 0.137)

    // Brand identity dots — always the LLM's hue
    static let claudeDot = Color(red: 0.880, green: 0.580, blue: 0.180) // clay/amber, hue 48
    static let codexDot = Color(red: 0.120, green: 0.780, blue: 0.598) // teal, hue 168
    static let geminiDot = Color(red: 0.420, green: 0.440, blue: 0.900) // indigo, hue 268
    static let genericDot = Color(white: 0.60)

    // Backgrounds
    static let darkBgTop = Color(red: 0.108, green: 0.108, blue: 0.132)
    static let darkBgBottom = Color(red: 0.132, green: 0.132, blue: 0.156)
    static let lightBgTop = Color(white: 0.990)
    static let lightBgBottom = Color(red: 0.940, green: 0.940, blue: 0.960)
}

// MARK: - Geometry

struct BurnGeom {
    enum Status { case ahead, onpace, behind }

    let vNow: Double // % remaining (0..100)
    let tNow: Double // position in window (0..1)
    let idealNow: Double // what you should have left = 100 * (1 - tNow)
    let margin: Double // vNow - idealNow; + = conserving, − = over pace
    let slope: Double // %/unit-t (negative = burning)
    let projT: Double // t where projection ends
    let projV: Double // v where projection ends
    let runsOut: Bool // projection hits 0 inside the window

    var status: Status {
        self.margin > 4 ? .ahead : self.margin < -4 ? .behind : .onpace
    }

    var depleted: Bool {
        self.vNow <= 0.5
    }

    var fresh: Bool {
        self.vNow >= 99.5
    }

    init(window: RateWindow) {
        let remaining = max(0, min(100, window.remainingPercent))
        self.vNow = remaining

        let t: Double
        if let resetsAt = window.resetsAt, let windowMins = window.windowMinutes, windowMins > 0 {
            let minutesUntilReset = max(0, resetsAt.timeIntervalSinceNow / 60)
            let minutesElapsed = Double(windowMins) - minutesUntilReset
            t = max(0.001, min(0.999, minutesElapsed / Double(windowMins)))
        } else {
            t = max(0.001, min(0.999, window.usedPercent / 100.0))
        }
        self.tNow = t
        self.idealNow = 100.0 * (1.0 - t)
        self.margin = remaining - self.idealNow

        let slope = t > 0.001 ? (remaining - 100.0) / t : -remaining
        self.slope = slope

        if slope < -0.01 {
            let tOut = t + remaining / -slope
            if tOut <= 1.0 {
                self.projT = tOut
                self.projV = 0
                self.runsOut = true
            } else {
                self.projT = 1.0
                self.projV = max(0, remaining + slope * (1.0 - t))
                self.runsOut = false
            }
        } else {
            self.projT = 1.0
            self.projV = remaining
            self.runsOut = false
        }
    }
}

// MARK: - Helpers

func burnWindowLabel(_ windowMinutes: Int?) -> String {
    guard let mins = windowMinutes else { return "Usage limit" }
    if mins < 60 { return "\(mins)-minute limit" }
    let hours = mins / 60
    if hours < 24 { return "\(hours)-hour limit" }
    return "\(hours / 24)-day limit"
}

func burnEffectiveResetDate(
    explicitResetAt: Date?,
    estimatedResetMinutes: Double?,
    now: Date) -> Date?
{
    if let explicitResetAt {
        return explicitResetAt > now ? explicitResetAt : nil
    }
    guard let estimatedResetMinutes, estimatedResetMinutes > 0 else { return nil }
    return now.addingTimeInterval(estimatedResetMinutes * 60)
}

func burnAxisDateRange(
    effectiveResetAt: Date?,
    windowMinutes: Int,
    now: Date) -> (start: Date, reset: Date)
{
    let reset = effectiveResetAt ?? now
    return (reset.addingTimeInterval(-Double(windowMinutes) * 60), reset)
}

func burnCompactWindowLabel(_ windowMinutes: Int?, fallback: String) -> String {
    guard let minutes = windowMinutes else { return fallback }
    if minutes < 60 { return "\(minutes)M" }
    let hours = minutes / 60
    if hours < 24 { return "\(hours)H" }
    return "\(hours / 24)D"
}

func burnFmtDuration(_ minutes: Double) -> String {
    guard minutes.isFinite, minutes > 0 else { return "—" }
    if minutes >= 1440 {
        let d = Int(minutes / 1440)
        let h = Int(minutes / 60) % 24
        return "\(d)d \(h)h"
    }
    let h = Int(minutes / 60)
    let m = Int(minutes) % 60
    if h <= 0 { return "\(max(1, m))m" }
    return "\(h)h \(String(format: "%02d", m))m"
}

func burnAxisLabel(_ date: Date, isDailyWindow: Bool) -> String {
    let f = DateFormatter()
    if isDailyWindow {
        // A rolling multi-day window's start and reset fall on the same weekday, so "EEE"
        // would print the same label at both ends ("Sat … Sat"). Use a numeric date so the
        // two ends are distinguishable.
        f.setLocalizedDateFormatFromTemplate("Md")
    } else {
        f.dateStyle = .none
        f.timeStyle = .short
    }
    return f.string(from: date)
}

func burnProviderName(_ provider: UsageProvider) -> String {
    ProviderDefaults.metadata[provider]?.displayName ?? provider.rawValue.capitalized
}
