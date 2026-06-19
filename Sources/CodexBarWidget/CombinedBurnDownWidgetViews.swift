import AppKit
import CodexBarCore
import SwiftUI
import WidgetKit

// MARK: - Entry View

struct CombinedBurnDownWidgetView: View {
    let entry: CombinedBurnDownEntry

    var body: some View {
        let state = BurnDownState(
            snapshot: self.entry.snapshot,
            provider: self.entry.provider,
            selection: .session)

        Group {
            if let state {
                CombinedBurnDownLayout(state: state, provider: self.entry.provider)
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

// MARK: - Layout

private struct CombinedBurnDownLayout: View {
    @Environment(\.widgetRenderingMode) private var renderingMode
    @Environment(\.colorScheme) private var colorScheme

    let state: BurnDownState
    let provider: UsageProvider

    var body: some View {
        let dark = self.colorScheme == .dark
        let isMonochrome = self.renderingMode != .fullColor

        let sessionWindow = self.state.primaryWindow
        let weeklyWindow = self.state.secondaryWindow

        let sessionGeom = sessionWindow.map { BurnGeom(window: $0) }
        let weeklyGeom = weeklyWindow.map { BurnGeom(window: $0) }

        // Use a neutral baseline theme for the header/hairline colors
        let baseGeom = sessionGeom ?? weeklyGeom ?? BurnGeom(
            window: RateWindow(
                usedPercent: 50,
                windowMinutes: 300,
                resetsAt: Date().addingTimeInterval(2.5 * 3600),
                resetDescription: nil))
        let baseTheme = BurnTheme(
            provider: self.provider,
            geom: baseGeom,
            dark: dark,
            isMonochrome: isMonochrome)

        VStack(spacing: 0) {
            // Header
            HStack(alignment: .center) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(baseTheme.brandDot)
                        .frame(width: 7, height: 7)
                        .shadow(color: baseTheme.brandDot.opacity(0.7), radius: 3.5)
                    Text(burnProviderName(self.provider))
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(baseTheme.text)
                        .lineLimit(1)
                }
                Spacer()
                Text("Session & weekly limits")
                    .font(.system(size: 10))
                    .foregroundStyle(baseTheme.sub)
                    .kerning(0.3)
            }

            // Two rows
            VStack(spacing: 0) {
                // 5H row — shows % remaining by default
                if let win = sessionWindow, let geom = sessionGeom {
                    CombinedBurnRow(
                        window: win,
                        geom: geom,
                        theme: BurnTheme(
                            provider: self.provider,
                            geom: geom,
                            dark: dark,
                            isMonochrome: isMonochrome),
                        tag: burnCompactWindowLabel(win.windowMinutes, fallback: "S"),
                        periods: 5,
                        metric: .remaining,
                        dark: dark,
                        blankChart: self.state.blankPrimaryChart,
                        resetsAtOverride: self.state.selectedResetOverride)
                } else {
                    CombinedEmptyRow(tag: "S", theme: baseTheme)
                }

                Rectangle()
                    .fill(baseTheme.hair)
                    .frame(height: 1)

                // 7D row — shows % off pace by default
                if let win = weeklyWindow, let geom = weeklyGeom {
                    CombinedBurnRow(
                        window: win,
                        geom: geom,
                        theme: BurnTheme(
                            provider: self.provider,
                            geom: geom,
                            dark: dark,
                            isMonochrome: isMonochrome),
                        tag: burnCompactWindowLabel(win.windowMinutes, fallback: "W"),
                        periods: 7,
                        metric: .pace,
                        dark: dark)
                } else {
                    CombinedEmptyRow(tag: "W", theme: baseTheme)
                }
            }
            .frame(maxHeight: .infinity)
            .padding(.top, 6)
        }
        .padding(.horizontal, 15)
        .padding(.top, 12)
        .padding(.bottom, 11)
    }
}

// MARK: - Metric

private enum CombinedMetric {
    case remaining // % left (default for 5H)
    case pace // % off ideal pace (default for 7D)
    case used // % consumed
}

// MARK: - Row

private struct CombinedBurnRow: View {
    let window: RateWindow
    let geom: BurnGeom
    let theme: BurnTheme
    let tag: String
    let periods: Int
    let metric: CombinedMetric
    let dark: Bool
    var blankChart = false
    var resetsAtOverride: Date?

    var body: some View {
        let windowMins = self.window.windowMinutes ?? 300
        let isDailyWindow = windowMins >= 1440

        let heroNum = self.metric == .pace ? abs(Int(self.geom.margin.rounded()))
            : self.metric == .used ? Int((100 - self.geom.vNow).rounded())
            : Int(self.geom.vNow.rounded())
        let suffix = self.metric == .remaining ? "left" : self.metric == .used ? "used" : ""
        let prefixArrow = self.metric == .pace

        let paceWord: String = self.geom.depleted ? "spent" : self.geom.fresh ? "full"
            : self.geom.status == .ahead ? "under pace"
            : self.geom.status == .behind ? "over pace" : "on pace"
        let arrow: String = self.geom.depleted ? "■" : self.geom.fresh ? "◆"
            : self.geom.status == .ahead ? "▲" : self.geom.status == .behind ? "▼" : "●"

        let explicitReset = self.blankChart
            ? self.resetsAtOverride
            : self.resetsAtOverride ?? self.window.resetsAt
        let now = Date()
        let estimatedResetMinutes = self.blankChart || self.geom.tNow >= 1
            ? nil
            : (1 - self.geom.tNow) * Double(windowMins)
        let effectiveResetDate = burnEffectiveResetDate(
            explicitResetAt: explicitReset,
            estimatedResetMinutes: estimatedResetMinutes,
            now: now)
        let heroColor = self.geom.depleted ? self.theme.danger : self.theme.statusColor

        HStack(alignment: .center, spacing: 12) {
            // Label column
            VStack(alignment: .leading, spacing: 0) {
                // Line 1: tag + (arrow for non-pace metrics) + pace word
                // For remaining/used: "5H ▼ over pace". For pace: "7D on pace" (arrow is on hero line).
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(self.tag)
                        .font(.system(size: 9.5, weight: .heavy))
                        .foregroundStyle(self.theme.sub)
                        .kerning(1)
                    HStack(alignment: .firstTextBaseline, spacing: 2) {
                        if !prefixArrow {
                            Text(arrow)
                                .font(.system(size: 8))
                                .foregroundStyle(self.theme.statusColor)
                        }
                        Text(paceWord)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(self.theme.statusColor)
                    }
                    .lineLimit(1)
                }

                // Line 2: hero number. Pace metric prefixes an arrow glyph.
                HStack(alignment: .lastTextBaseline, spacing: 2) {
                    if prefixArrow {
                        Text(arrow)
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(heroColor)
                    }
                    Text("\(heroNum)")
                        .font(.system(size: 27, weight: .semibold))
                        .foregroundStyle(heroColor)
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Text("%")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(self.theme.sub)
                    if !suffix.isEmpty {
                        Text(suffix)
                            .font(.system(size: 10))
                            .foregroundStyle(self.theme.sub)
                    }
                }
                .padding(.top, 1)

                // Line 3: reset line — refresh glyph + countdown + compact time
                HStack(spacing: 4) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 9))
                        .foregroundStyle(self.theme.sub.opacity(0.85))
                    if let effectiveResetDate {
                        Text(effectiveResetDate, style: .relative)
                            .font(.system(size: 9.5, weight: .medium))
                            .foregroundStyle(self.theme.text)
                            .monospacedDigit()
                        Text("· \(combinedCompactResetTime(effectiveResetDate, isDailyWindow: isDailyWindow))")
                            .font(.system(size: 9.5, weight: .medium))
                            .foregroundStyle(self.theme.text)
                    } else {
                        Text("—")
                            .font(.system(size: 9.5, weight: .medium))
                            .foregroundStyle(self.theme.text)
                    }
                }
                .padding(.top, 2)
                .lineLimit(1)
            }
            .frame(width: 112, alignment: .leading)

            // Chart column — blanked when the session window is blocked by an exhausted
            // weekly cap; there is no session burn to chart until the weekly resets.
            if self.blankChart {
                Color.clear
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
            } else {
                CombinedBurnChartCanvas(geom: self.geom, theme: self.theme, periods: self.periods, dark: self.dark)
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
            }
        }
        .frame(maxHeight: .infinity)
    }
}

// MARK: - Empty Row

private struct CombinedEmptyRow: View {
    let tag: String
    let theme: BurnTheme

    var body: some View {
        HStack {
            Text(self.tag)
                .font(.system(size: 9.5, weight: .heavy))
                .foregroundStyle(self.theme.sub)
                .kerning(1)
            Text("No data")
                .font(.system(size: 10))
                .foregroundStyle(self.theme.sub)
            Spacer()
        }
        .frame(maxHeight: .infinity)
    }
}

// MARK: - Mini Chart Canvas

private struct CombinedBurnChartCanvas: View {
    let geom: BurnGeom
    let theme: BurnTheme
    let periods: Int
    let dark: Bool

    var body: some View {
        Canvas { context, size in
            let w = size.width
            let h = size.height
            let padT: CGFloat = 5
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
            let barColor = self.dark ? Color.white : Color.black

            // --- Usage bars (background texture) ---
            // Drawn first so the actual line renders on top.
            // Heights are relative-to-ideal: idealPerPeriod maps to ~46% of plot height.
            let plotH = h - padT - padB
            let refH = 0.46 * plotH // reference height = ideal-pace bar height
            let idealPerPeriod = 100.0 / Double(self.periods)
            let burnRate = tNow > 0.001 ? (100.0 - vNow) / tNow : 0.0 // %/unit-t
            let slotW = (w - padL - padR) / CGFloat(self.periods)

            for i in 0..<self.periods {
                let slotStart = Double(i) / Double(self.periods)
                let slotEnd = Double(i + 1) / Double(self.periods)
                let slotX = padL + CGFloat(slotStart) * (w - padL - padR)

                if slotEnd <= tNow {
                    // Completed period — full-width bar
                    let consumed = burnRate * (slotEnd - slotStart)
                    let ratio = consumed / idealPerPeriod
                    let totalBarH = CGFloat(ratio) * refH
                    let baseH = min(totalBarH, refH)

                    if baseH > 0 {
                        let rect = CGRect(
                            x: slotX,
                            y: h - padB - baseH,
                            width: slotW - 1,
                            height: baseH)
                        context.fill(Path(rect), with: .color(barColor.opacity(0.17)))
                    }
                    // Overage segment — above ideal reference line
                    if totalBarH > refH {
                        let overH = totalBarH - refH
                        let rect = CGRect(
                            x: slotX,
                            y: h - padB - totalBarH,
                            width: slotW - 1,
                            height: overH)
                        context.fill(Path(rect), with: .color(barColor.opacity(0.34)))
                    }
                } else if slotStart < tNow {
                    // Current (partial) period — narrower bar ending at tNow
                    let partialFrac = (tNow - slotStart) / (slotEnd - slotStart)
                    let consumed = burnRate * (tNow - slotStart)
                    let ratio = consumed / idealPerPeriod
                    let totalBarH = CGFloat(ratio) * refH
                    let baseH = min(totalBarH, refH)
                    let barW = CGFloat(partialFrac) * (slotW - 1)

                    if baseH > 0 {
                        let rect = CGRect(
                            x: slotX,
                            y: h - padB - baseH,
                            width: barW,
                            height: baseH)
                        context.fill(Path(rect), with: .color(barColor.opacity(0.13)))
                    }
                    if totalBarH > refH {
                        let overH = totalBarH - refH
                        let rect = CGRect(
                            x: slotX,
                            y: h - padB - totalBarH,
                            width: barW,
                            height: overH)
                        context.fill(Path(rect), with: .color(barColor.opacity(0.26)))
                    }
                } else {
                    // Future period — faint full-height placeholder
                    let rect = CGRect(
                        x: slotX,
                        y: h - padB - refH,
                        width: slotW - 1,
                        height: refH)
                    context.fill(Path(rect), with: .color(barColor.opacity(0.045)))
                }
            }

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

            // --- Ideal line (dashed, recedes) ---
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

            // --- Actual line (solid, dominant) ---
            do {
                var p = Path()
                p.move(to: CGPoint(x: X(0), y: Y(100)))
                p.addLine(to: CGPoint(x: X(tNow), y: Y(vNow)))
                context.stroke(
                    p,
                    with: .color(self.theme.chartLine),
                    style: StrokeStyle(lineWidth: 2.4, lineCap: .round, lineJoin: .round))
            }

            // --- Now dot (filled, ringed) ---
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

// MARK: - Compact reset time helper

/// Formats a reset date compactly: "4:30p", "5p", "Sun 9a".
/// Weekday prefix is added for the 7-day window or when the reset is ≥20h away.
private func combinedCompactResetTime(_ date: Date, isDailyWindow: Bool) -> String {
    let includeDay = isDailyWindow || date.timeIntervalSinceNow >= 20 * 3600
    let formatter = DateFormatter()
    formatter.setLocalizedDateFormatFromTemplate(includeDay ? "EEEjm" : "jm")
    return formatter.string(from: date)
}
