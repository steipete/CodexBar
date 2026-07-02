import Foundation

extension MiniMaxUsageParser {
    static func windowMinutes(start: Date?, end: Date?) -> Int? {
        guard let start, let end else { return nil }
        let minutes = Int(end.timeIntervalSince(start) / 60)
        return minutes > 0 ? minutes : nil
    }

    static func resetsAt(
        end: Date?,
        remains: Int?,
        now: Date,
        windowType: String) -> Date?
    {
        let endReset: Date? = {
            guard let end, end > now else { return nil }
            return end
        }()

        let remainsReset: Date? = {
            guard let remains, remains > 0 else { return nil }
            let seconds: TimeInterval = remains > 1_000_000 ? TimeInterval(remains) / 1000 : TimeInterval(remains)
            let resetDate = now.addingTimeInterval(seconds)
            guard resetDate > now else { return nil }
            return resetDate
        }()

        guard let remainsReset else { return endReset }
        guard let endReset else { return remainsReset }

        if let maxRemain = self.maxReasonableRemainInterval(windowType: windowType),
           remainsReset.timeIntervalSince(now) > maxRemain
        {
            return endReset
        }

        // Prefer API countdown when it is close to the declared interval boundary.
        if remainsReset <= endReset.addingTimeInterval(15 * 60) {
            return remainsReset
        }
        return endReset
    }

    static func maxReasonableRemainInterval(windowType: String) -> TimeInterval? {
        let normalized = windowType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized == "weekly" {
            return 8 * 24 * 3600
        }
        if normalized == "today" || normalized == "daily" {
            return 26 * 3600
        }
        if normalized == "5 hours" || normalized == "5h" || normalized.contains("hour") {
            return 6 * 3600
        }
        if let hours = Int(normalized.split(separator: " ").first ?? ""), normalized.contains("hour") {
            return TimeInterval(hours + 1) * 3600
        }
        return nil
    }
}
