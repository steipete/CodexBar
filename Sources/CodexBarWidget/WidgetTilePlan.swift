import CodexBarCore
import Foundation

/// One quota lane after the tile has decided how to present it.
struct WidgetTileLane: Identifiable, Equatable {
    let id: String
    let title: String
    /// Always the remaining share, regardless of the user's "show used" preference. Severity and
    /// hero selection are defined on what is left, not on what is displayed.
    let remainingPercent: Double?
    var resetsAt: Date?
    var resetDescription: String?
}

/// How a tile splits its quota lanes: one headline lane plus the rest.
///
/// The headline is the *binding* lane — the one with the least left — because that is the number
/// that decides whether the user can keep working. The old tiles gave every lane identical weight,
/// so a lane at 3% and a lane at 97% looked equally routine.
struct WidgetTilePlan: Equatable {
    let hero: WidgetTileLane?
    let lanes: [WidgetTileLane]
    let overflowCount: Int

    static let empty = WidgetTilePlan(hero: nil, lanes: [], overflowCount: 0)

    /// - Parameters:
    ///   - lanes: every lane the provider reports. The headline is chosen from all of them, so a
    ///     provider's compact row cap can never hide the lane that is actually binding.
    ///   - displayCandidates: the lanes a compact tile is allowed to list, already curated by the
    ///     provider (row caps, Antigravity's one-row-per-model-family selection). Defaults to
    ///     `lanes` when the tile lists everything.
    ///   - reservesOverflowRow: when the tile is too tight to absorb the "+N more" line on top of a
    ///     full lane list, the line takes one of the lane slots instead of overflowing the tile.
    ///     Measured against `lanes`, since a lane dropped by curation overflows just the same.
    static func make(
        lanes: [WidgetTileLane],
        displayCandidates: [WidgetTileLane]? = nil,
        maxSecondaryLanes: Int,
        reservesOverflowRow: Bool = false) -> WidgetTilePlan
    {
        guard let hero = self.bindingLane(in: lanes) else { return .empty }
        let candidates = displayCandidates ?? lanes
        let remainder = candidates.filter { $0.id != hero.id }
        // Honour the provider's intended row count: the headline occupies one of those rows.
        var capacity = min(max(0, maxSecondaryLanes), max(0, candidates.count - 1))
        // Give up a lane slot only when the "+N more" line would actually push the tile past its
        // budget. Whether that line appears is decided against every lane the provider reports,
        // not the curated subset: curation drops lanes that never reach `remainder`, so a curated
        // remainder that fits its budget exactly can still overflow.
        let listed = min(remainder.count, capacity)
        let overflows = (lanes.count - 1) - listed > 0
        if reservesOverflowRow, listed + (overflows ? 1 : 0) > maxSecondaryLanes {
            capacity = max(1, capacity - 1)
        }
        let shown = Array(remainder.prefix(capacity))
        // Counted against every lane the provider reports, not just the curated subset, so a lane
        // dropped by the cap is still surfaced.
        return WidgetTilePlan(
            hero: hero,
            lanes: shown,
            overflowCount: max(0, lanes.count - 1 - shown.count))
    }

    /// Lowest remaining share wins; ties keep the provider's own ordering. Lanes without a
    /// percentage can only become the headline when nothing else can.
    private static func bindingLane(in lanes: [WidgetTileLane]) -> WidgetTileLane? {
        let measured = lanes.filter { $0.remainingPercent != nil }
        guard !measured.isEmpty else { return lanes.first }
        return measured.min { lhs, rhs in
            (lhs.remainingPercent ?? 0) < (rhs.remainingPercent ?? 0)
        }
    }
}

extension WidgetTileLane {
    init(row: WidgetUsageRow) {
        self.init(
            id: row.id,
            title: row.title,
            remainingPercent: row.percentLeft,
            resetsAt: row.resetsAt,
            resetDescription: row.resetDescription)
    }

    /// Every quota lane a tile can draw for this entry: the provider's usage rows plus the
    /// separately-tracked code review lane.
    static func lanes(for entry: WidgetSnapshot.ProviderEntry, limit: Int? = nil) -> [WidgetTileLane] {
        var lanes = WidgetUsageRow.rows(for: entry, limit: limit).map(WidgetTileLane.init(row:))
        if let codeReview = entry.codeReviewRemainingPercent {
            lanes.append(WidgetTileLane(
                id: "code-review",
                title: "Code review",
                remainingPercent: codeReview))
        }
        return lanes
    }
}

// MARK: - Lane copy

enum WidgetLaneCopy {
    /// "Weekly left" / "Weekly used" — the bare percentages the tiles used to show never said
    /// which of the two the user was looking at, and the preference silently flips it.
    static func caption(title: String, showUsed: Bool) -> String {
        "\(title) \(showUsed ? "used" : "left")"
    }

    /// Compact, human reset text. Counts down from the reset date when there is one — that form is
    /// short and predictable — and falls back to the provider's own wording. Returns nil once the
    /// reset is in the past or unknown.
    static func resetText(
        resetsAt: Date?,
        resetDescription: String?,
        now: Date = Date()) -> String?
    {
        if let resetsAt {
            // A known reset that has already passed means the snapshot is stale. Say nothing rather
            // than falling through to cached wording that would still read "Resets in 4h".
            let interval = resetsAt.timeIntervalSince(now)
            guard interval > 0 else { return nil }
            return "Resets in \(self.duration(interval))"
        }
        // Provider wording is the fallback. Some providers emit a bare timestamp
        // ("tomorrow, 12:28 PM") that says nothing about what the time refers to, so label it.
        guard let text = resetDescription?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty
        else { return nil }
        return text.lowercased().hasPrefix("reset") ? text : "Resets \(text)"
    }

    /// Rounds to the nearest whole unit rather than truncating: 47h59m is "2d" to a reader, not
    /// the "1d" that flooring produces.
    static func duration(_ interval: TimeInterval) -> String {
        if interval < 3600 {
            return "\(max(1, Int((interval / 60).rounded())))m"
        }
        if interval < 86400 {
            let hours = Int((interval / 3600).rounded())
            return hours >= 24 ? "1d" : "\(max(1, hours))h"
        }
        return "\(max(1, Int((interval / 86400).rounded())))d"
    }
}
