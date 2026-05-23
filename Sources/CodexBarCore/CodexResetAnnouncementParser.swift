import Foundation

/// Parses external text for Codex usage-limit reset announcements.
///
/// Phase-1 foundation for #1103. This type is:
/// - pure: no network access, no side effects, no quota mutation
/// - sendable: thread-safe, no mutable state
/// - stateless: ``parse(_:)`` is a pure, deterministic function — the same input
///   always produces the same output with no hidden state or time dependencies.
///
/// ``announcements(from:sourceName:sourceURL:observedAt:)`` is deterministic when
/// ``observedAt`` is supplied; otherwise each call gets its own timestamp via the
/// default ``Date()``, making results differ across runs.
///
/// The parser recognises three confidence bands:
///
/// | Status | Confidence | Example |
/// |---|---|---|
/// | `.completed` | 1.0 | "usage limits have been reset" |
/// | `.upcoming` | 0.85 | "I will reset usage limits" |
/// | `.ambiguous` | 0.5 | "waived usage consumption" |
///
/// All matching uses exact-substring containment on lowercased text, with
/// word-boundary guards to prevent false positives from concatenated words
/// (e.g. "theResetUsageLimits" would not match).  Punctuation at phrase
/// boundaries is accepted (e.g. "limits." matches "limits").
///
/// If a phrase appears multiple times in the text, every occurrence is checked
/// and the function returns ``true`` if **any** occurrence passes boundary checks.
public struct CodexResetAnnouncementParser: Sendable {
    public init() {}

    public enum ParseResult: Equatable {
        case upcoming(confidence: Double)
        case completed(confidence: Double)
        case ambiguous(confidence: Double)
        case none
    }

    public func parse(_ text: String) -> ParseResult {
        let lowercased = text.lowercased()

        if Self.matchesCompletedReset(lowercased) {
            return .completed(confidence: 1.0)
        }

        if Self.matchesUpcomingReset(lowercased) {
            return .upcoming(confidence: 0.85)
        }

        if Self.matchesAmbiguousReset(lowercased) {
            return .ambiguous(confidence: 0.5)
        }

        return .none
    }

    /// Converts parsed results into domain objects.
    ///
    /// All ``CodexResetAnnouncement`` instances created in a single call share the
    /// same ``CodexResetAnnouncement/observedAt`` value, making results reproducible
    /// when a fixed ``observedAt`` is supplied.
    ///
    /// ``rawText`` is intentionally omitted from the resulting ``CodexResetAnnouncement``
    /// to avoid persisting arbitrary external content that may contain personal information.
    public func announcements(
        from texts: [String],
        sourceName: String,
        sourceURL: String? = nil,
        observedAt: Date = Date()
    ) -> [CodexResetAnnouncement] {
        texts.compactMap { text in
            switch parse(text) {
            case .upcoming(let confidence):
                return CodexResetAnnouncement(
                    sourceName: sourceName,
                    sourceURL: sourceURL,
                    observedAt: observedAt,
                    status: .upcoming,
                    confidence: confidence)
            case .completed(let confidence):
                return CodexResetAnnouncement(
                    sourceName: sourceName,
                    sourceURL: sourceURL,
                    observedAt: observedAt,
                    status: .completed,
                    confidence: confidence)
            case .ambiguous(let confidence):
                return CodexResetAnnouncement(
                    sourceName: sourceName,
                    sourceURL: sourceURL,
                    observedAt: observedAt,
                    status: .ambiguous,
                    confidence: confidence)
            case .none:
                return nil
            }
        }
    }

    // MARK: - Private patterns

    /// Past-tense statements indicating the reset has already occurred.
    private static func matchesCompletedReset(_ text: String) -> Bool {
        let patterns = [
            "i reset usage limits",
            "i've reset usage limits",
            "i have reset usage limits",
            "usage limits have been reset",
            "limits have been reset",
            "limits are back to normal"
        ]
        return patterns.contains { Self.containsWithWordBoundaries(text: text, phrase: $0) }
    }

    /// Future or present-progressive statements indicating a reset is imminent or in progress.
    private static func matchesUpcomingReset(_ text: String) -> Bool {
        let patterns = [
            "i will reset usage limits",
            "i'll reset usage limits",
            "will reset usage limits",
            "i plan to reset usage limits",
            "i'm resetting usage limits",
            "resetting usage limits"
        ]
        return patterns.contains { Self.containsWithWordBoundaries(text: text, phrase: $0) }
    }

    /// Phrases that indicate a waiver but are ambiguous about whether a full reset occurred.
    private static func matchesAmbiguousReset(_ text: String) -> Bool {
        let patterns = [
            "waived usage consumption",
            "usage consumption waived",
            "limits are waived",
            "usage limits are waived",
            "consumption has been waived"
        ]
        return patterns.contains { Self.containsWithWordBoundaries(text: text, phrase: $0) }
    }

    /// Scans every occurrence of ``phrase`` in ``text`` and returns ``true`` if **any**
    /// occurrence passes word-boundary checks.  Returns ``false`` only after all occurrences
    /// have been rejected.
    ///
    /// Boundary rules: the character immediately before the phrase and immediately after
    /// must be whitespace, punctuation, or absent (start/end of string).  This prevents
    /// "theResetUsageLimits" from matching "reset usage limits" while still accepting
    /// "reset usage limits." with a trailing period.
    private static func containsWithWordBoundaries(text: String, phrase: String) -> Bool {
        var searchStart = text.startIndex
        while let range = text.range(of: phrase, options: .caseInsensitive, range: searchStart..<text.endIndex) {
            let start = range.lowerBound
            let end = range.upperBound

            let isWordChar: (Character) -> Bool = { !$0.isWhitespace && !$0.isPunctuation }
            let charBeforeOK = start == text.startIndex || !isWordChar(text[text.index(before: start)])
            let charAfterOK = end == text.endIndex || !isWordChar(text[end])

            if charBeforeOK && charAfterOK {
                return true
            }
            searchStart = range.upperBound
        }
        return false
    }
}