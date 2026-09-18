import Foundation

/// Parses Bifrost's budget/rate-limit `reset_duration` grammar.
///
/// Bifrost extends Go's `time.ParseDuration` with calendar-approximate units (`tables/utils.go`):
/// `d` = 24h, `w` = 168h, `M` = 30d, `Q` = 90d, `Y` = 365d. `M`/`Q`/`Y` are server-side approximations;
/// calendar alignment (e.g. "the 1st of the month") is not recoverable from the JSON payload.
enum BifrostResetDuration {
    struct Parsed: Equatable, Sendable {
        let seconds: Double
        let canonical: String
        let label: String?
        let windowMinutes: Int?
    }

    private static let unitSeconds: [(suffix: String, seconds: Double)] = [
        ("Y", 365 * 24 * 3600),
        ("Q", 90 * 24 * 3600),
        ("M", 30 * 24 * 3600),
        ("w", 7 * 24 * 3600),
        ("d", 24 * 3600),
        ("h", 3600),
        ("m", 60),
        ("s", 1),
        ("ms", 0.001),
        ("us", 0.000_001),
        ("ns", 0.000_000_001),
    ]

    private static let labels: [String: String] = [
        "1h": "Hourly",
        "1d": "Daily",
        "1w": "Weekly",
        "1M": "Monthly",
        "1Q": "Quarterly",
        "1Y": "Yearly",
    ]

    static func parse(_ raw: String?) -> Parsed? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // Bifrost's single-unit shorthand, e.g. "1M", "7d", "2w".
        if let seconds = self.singleUnitSeconds(trimmed) {
            return Parsed(
                seconds: seconds,
                canonical: trimmed,
                label: self.labels[trimmed],
                windowMinutes: self.windowMinutes(fromSeconds: seconds))
        }

        // Fall back to Go's `time.ParseDuration` grammar (sums of numbered unit runs, e.g. "1h30m").
        if let seconds = self.goDurationSeconds(trimmed), seconds > 0 {
            return Parsed(
                seconds: seconds,
                canonical: trimmed,
                label: nil,
                windowMinutes: self.windowMinutes(fromSeconds: seconds))
        }
        return nil
    }

    static func nextReset(lastReset: Date?, duration raw: String?, now: Date) -> Date? {
        guard let lastReset, let parsed = self.parse(raw), parsed.seconds.isFinite, parsed.seconds > 0 else {
            return nil
        }
        let elapsed = now.timeIntervalSince(lastReset)
        guard elapsed.isFinite else { return nil }
        let cyclesElapsed = max(0, (elapsed / parsed.seconds).rounded(.down))
        return lastReset.addingTimeInterval((cyclesElapsed + 1) * parsed.seconds)
    }

    private static func singleUnitSeconds(_ value: String) -> Double? {
        for unit in self.unitSeconds where value.hasSuffix(unit.suffix) {
            let numberPart = String(value.dropLast(unit.suffix.count))
            guard !numberPart.isEmpty, let magnitude = Double(numberPart), magnitude.isFinite else { continue }
            return magnitude * unit.seconds
        }
        return nil
    }

    /// Sums numbered unit runs (`1h30m`, `90s`) per Go's `time.ParseDuration`, using only the
    /// fixed-length units it defines (`ns`, `us`, `ms`, `s`, `m`, `h`) — no `d`/`w`/`M`/`Q`/`Y`.
    private static func goDurationSeconds(_ value: String) -> Double? {
        var remaining = Substring(value)
        var total = 0.0
        var matchedAny = false
        let goUnits = self.unitSeconds.filter { ["h", "m", "s", "ms", "us", "ns"].contains($0.suffix) }
            .sorted { $0.suffix.count > $1.suffix.count }

        while !remaining.isEmpty {
            let numberEnd = remaining.firstIndex { !"0123456789.".contains($0) } ?? remaining.endIndex
            guard numberEnd != remaining.startIndex, let magnitude = Double(remaining[..<numberEnd]) else {
                return nil
            }
            let afterNumber = remaining[numberEnd...]
            guard let unit = goUnits.first(where: { afterNumber.hasPrefix($0.suffix) }) else {
                return nil
            }
            total += magnitude * unit.seconds
            matchedAny = true
            remaining = afterNumber.dropFirst(unit.suffix.count)
        }
        return matchedAny ? total : nil
    }

    private static func windowMinutes(fromSeconds seconds: Double) -> Int? {
        guard seconds.isFinite, seconds > 0 else { return nil }
        let minutes = seconds / 60
        return Int(exactly: minutes.rounded(.towardZero))
    }
}
