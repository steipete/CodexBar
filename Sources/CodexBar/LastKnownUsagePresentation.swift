import Foundation

enum LastKnownUsagePresentation {
    static func message(
        capturedAt: Date,
        now: Date = .now,
        localize: (String) -> String = L) -> String
    {
        String(
            format: localize("claude_showing_last_known_usage"),
            capturedAt.relativeDescription(now: now))
    }
}
