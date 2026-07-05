import CodexBarCore
import SwiftUI

/// One expiring reset credit placed on the runway timeline.
struct CodexResetCreditRunwayMarker: Equatable, Identifiable {
    let id: String
    /// 0…1 along the horizon: 0 = now, 1 = a freshly granted credit at the far edge.
    let position: Double
    let isNearest: Bool
    /// Nearest credit expiring within 48h.
    let isUrgent: Bool
    /// Resting label shown above the track for the nearest credit only.
    let restingLabel: String?
    /// Exact values revealed on hover for every credit (countdown · absolute date).
    let hoverText: String
}

extension CodexResetCreditsPresentation {
    private static let runwayUrgencyWindow: TimeInterval = 48 * 3600

    /// Places each dated, still-valid credit on a data-derived horizon (the longest credit
    /// lifetime in the inventory), so a credit's position drifts left predictably as it ages.
    /// Credits with no expiry stay in the count and tooltip but off the track.
    static func runwayMarkers(
        credits: [CodexRateLimitResetCredit],
        resetStyle: ResetTimeDisplayStyle,
        now: Date) -> [CodexResetCreditRunwayMarker]
    {
        let dated = credits
            .compactMap { credit -> (expiresAt: Date, lifetime: TimeInterval)? in
                guard let expiresAt = credit.expiresAt, expiresAt > now else { return nil }
                return (expiresAt, expiresAt.timeIntervalSince(credit.grantedAt))
            }
            .sorted { $0.expiresAt < $1.expiresAt }
        guard let horizon = dated.map(\.lifetime).max(), horizon > 0 else { return [] }

        return dated.enumerated().map { index, entry in
            let remaining = entry.expiresAt.timeIntervalSince(now)
            let isNearest = index == 0
            return CodexResetCreditRunwayMarker(
                id: "codex-reset-runway-\(index)",
                position: min(1, max(0, remaining / horizon)),
                isNearest: isNearest,
                isUrgent: isNearest && remaining < Self.runwayUrgencyWindow,
                restingLabel: isNearest
                    ? Self.compactExpiryText(for: entry.expiresAt, resetStyle: resetStyle, now: now)
                    : nil,
                hoverText: Self.runwayHoverText(for: entry.expiresAt, now: now))
        }
    }

    /// Label for the far end of the axis (the longest lifetime), reusing the countdown formatter.
    static func runwayHorizonLabel(credits: [CodexRateLimitResetCredit], now: Date) -> String? {
        let horizon = credits
            .compactMap { credit -> TimeInterval? in
                guard let expiresAt = credit.expiresAt, expiresAt > now else { return nil }
                return expiresAt.timeIntervalSince(credit.grantedAt)
            }
            .max()
        guard let horizon, horizon > 0 else { return nil }
        let countdown = UsageFormatter.resetCountdownDescription(from: now.addingTimeInterval(horizon), now: now)
        return countdown.hasPrefix("in ") ? String(countdown.dropFirst(3)) : countdown
    }

    private static func runwayHoverText(for expiresAt: Date, now: Date) -> String {
        let countdown = UsageFormatter.resetCountdownDescription(from: expiresAt, now: now)
        let compact = countdown.hasPrefix("in ") ? String(countdown.dropFirst(3)) : countdown
        let absolute = UsageFormatter.resetDescription(from: expiresAt, now: now)
        return compact == absolute ? compact : "\(compact) · \(absolute)"
    }
}

/// Horizontal timeline of reset-credit expiries — an opt-in alternative to the compact text list.
/// Colors resolve through `MenuHighlightStyle` so the runway stays legible on the highlighted row.
struct CodexResetCreditRunway: View {
    let markers: [CodexResetCreditRunwayMarker]
    let horizonLabel: String
    @Environment(\.menuItemHighlighted) private var isHighlighted
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hoveredMarkerID: String?

    private var activeLabel: (text: String, position: Double, urgent: Bool)? {
        if let hovered = self.markers.first(where: { $0.id == self.hoveredMarkerID }) {
            return (hovered.hoverText, hovered.position, hovered.isUrgent)
        }
        guard let nearest = self.markers.first(where: \.isNearest), let label = nearest.restingLabel else {
            return nil
        }
        return (label, nearest.position, nearest.isUrgent)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            GeometryReader { geo in
                ZStack(alignment: .topLeading) {
                    if let label = self.activeLabel {
                        Text(label.text)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(label.urgent
                                ? MenuHighlightStyle.error(self.isHighlighted)
                                : MenuHighlightStyle.primary(self.isHighlighted))
                            .fixedSize()
                            .frame(width: geo.size.width, alignment: .leading)
                            .offset(x: self.clampedLabelX(label.position, width: geo.size.width), y: 0)
                    }
                    Capsule()
                        .fill(MenuHighlightStyle.progressTrack(self.isHighlighted))
                        .frame(height: 4)
                        .offset(y: 20)
                    ForEach(self.markers) { marker in
                        self.dot(for: marker)
                            .position(x: geo.size.width * marker.position, y: 22)
                    }
                }
                .animation(self.reduceMotion ? nil : .easeInOut(duration: 0.12), value: self.hoveredMarkerID)
            }
            .frame(height: 28)
            HStack {
                Text(L("now"))
                Spacer(minLength: 8)
                Text(self.horizonLabel)
            }
            .font(.caption2)
            .foregroundStyle(MenuHighlightStyle.secondary(self.isHighlighted))
            .accessibilityHidden(true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func dot(for marker: CodexResetCreditRunwayMarker) -> some View {
        let hovered = self.hoveredMarkerID == marker.id
        let color = marker.isUrgent
            ? MenuHighlightStyle.error(self.isHighlighted)
            : MenuHighlightStyle.progressTint(self.isHighlighted, fallback: Color(nsColor: .controlAccentColor))
        let diameter: CGFloat = marker.isNearest ? 11 : 8
        return Circle()
            .fill(color)
            .opacity(marker.isNearest || hovered ? 1 : 0.55)
            .frame(width: diameter, height: diameter)
            .scaleEffect(hovered && !self.reduceMotion ? 1.25 : 1)
            .frame(width: 20, height: 20)
            .contentShape(Rectangle())
            .onHover { hovering in
                if hovering {
                    self.hoveredMarkerID = marker.id
                } else if self.hoveredMarkerID == marker.id {
                    self.hoveredMarkerID = nil
                }
            }
    }

    private func clampedLabelX(_ position: Double, width: CGFloat) -> CGFloat {
        // Center the label over its dot, but keep it inside the track bounds.
        let estimatedHalf: CGFloat = 34
        let target = width * position
        return min(max(target - estimatedHalf, 0), max(width - estimatedHalf * 2, 0))
    }
}
