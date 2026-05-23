import CodexBarCore
import Foundation
import Testing

struct CodexResetAnnouncementParserTests {
    let parser = CodexResetAnnouncementParser()

    // MARK: - Completed reset (past tense)

    @Test
    func completedReset_pastTenseIEvening() {
        let result = parser.parse("I reset usage limits this evening")
        #expect(result == .completed(confidence: 1.0))
    }

    @Test
    func completedReset_usageLimitsHaveBeenReset() {
        let result = parser.parse("usage limits have been reset")
        #expect(result == .completed(confidence: 1.0))
    }

    @Test
    func completedReset_limitsAreBackToNormal() {
        let result = parser.parse("limits are back to normal")
        #expect(result == .completed(confidence: 1.0))
    }

    @Test
    func completedReset_withContraction() {
        let result = parser.parse("i've reset usage limits")
        #expect(result == .completed(confidence: 1.0))
    }

    @Test
    func completedReset_withFullStop() {
        let result = parser.parse("I reset usage limits.")
        #expect(result == .completed(confidence: 1.0))
    }

    // MARK: - Upcoming reset (future / present-progressive)

    @Test
    func upcomingReset_willResetThisEvening() {
        let result = parser.parse("I will reset usage limits this evening")
        #expect(result == .upcoming(confidence: 0.85))
    }

    @Test
    func upcomingReset_iWillReset() {
        let result = parser.parse("I will reset usage limits")
        #expect(result == .upcoming(confidence: 0.85))
    }

    @Test
    func upcomingReset_contraction() {
        let result = parser.parse("I'll reset usage limits")
        #expect(result == .upcoming(confidence: 0.85))
    }

    @Test
    func upcomingReset_iPlanToReset() {
        let result = parser.parse("I plan to reset usage limits tomorrow")
        #expect(result == .upcoming(confidence: 0.85))
    }

    @Test
    func upcomingReset_presentProgressive() {
        let result = parser.parse("I'm resetting usage limits now")
        #expect(result == .upcoming(confidence: 0.85))
    }

    @Test
    func upcomingReset_presentParticiple() {
        let result = parser.parse("Resetting usage limits as we speak")
        #expect(result == .upcoming(confidence: 0.85))
    }

    // MARK: - Ambiguous reset (waiver language)

    @Test
    func ambiguousReset_waivedUsageConsumption() {
        let result = parser.parse("waived usage consumption")
        #expect(result == .ambiguous(confidence: 0.5))
    }

    @Test
    func ambiguousReset_limitsAreWaived() {
        let result = parser.parse("limits are waived")
        #expect(result == .ambiguous(confidence: 0.5))
    }

    @Test
    func ambiguousReset_usageLimitsAreWaived() {
        let result = parser.parse("usage limits are waived")
        #expect(result == .ambiguous(confidence: 0.5))
    }

    // MARK: - False positives: password / auth resets

    @Test
    func falsePositive_passwordReset() {
        #expect(parser.parse("I will reset my password") == .none)
        #expect(parser.parse("Please reset your password") == .none)
        #expect(parser.parse("I forgot my password reset") == .none)
        #expect(parser.parse("DM me to reset your password") == .none)
    }

    @Test
    func falsePositive_tokenRefresh() {
        #expect(parser.parse("I will reset my API token") == .none)
        #expect(parser.parse("Please reset your session token") == .none)
    }

    @Test
    func falsePositive_settingsReset() {
        #expect(parser.parse("Reset your settings") == .none)
        #expect(parser.parse("I will reset settings to default") == .none)
        #expect(parser.parse("Reset the app settings") == .none)
    }

    // MARK: - False positives: rate limit changes

    @Test
    func falsePositive_rateLimitIncrease() {
        #expect(parser.parse("We increased the rate limits") == .none)
        #expect(parser.parse("Rate limits are higher now") == .none)
        #expect(parser.parse("Limits have been increased") == .none)
    }

    @Test
    func falsePositive_rateLimitDecrease() {
        #expect(parser.parse("We decreased the rate limits") == .none)
        #expect(parser.parse("Limits have been lowered") == .none)
    }

    @Test
    func falsePositive_limitChangesWithoutReset() {
        #expect(parser.parse("usage limits changed") == .none)
        #expect(parser.parse("usage limits are different now") == .none)
    }

    // MARK: - False positives: system / cache resets

    @Test
    func falsePositive_cacheReset() {
        #expect(parser.parse("I will reset my cache") == .none)
        #expect(parser.parse("Reset cache to free up space") == .none)
    }

    @Test
    func falsePositive_systemReset() {
        #expect(parser.parse("System reset needed") == .none)
        #expect(parser.parse("The server will reset tonight") == .none)
    }

    // MARK: - False positives: usage without reset

    @Test
    func falsePositive_usageHighNoReset() {
        #expect(parser.parse("My usage is very high today") == .none)
        #expect(parser.parse("Codex usage is at 90%") == .none)
        #expect(parser.parse("I'm hitting usage limits") == .none)
    }

    @Test
    func falsePositive_ordinaryTweet() {
        #expect(parser.parse("Codex is great for coding tasks today") == .none)
        #expect(parser.parse("Just shipped a new feature to production!") == .none)
        #expect(parser.parse("Twitter is broken again") == .none)
    }

    // MARK: - False positives: other reset-like phrases

    @Test
    func falsePositive_serverRestart() {
        #expect(parser.parse("Server will reset at midnight") == .none)
        #expect(parser.parse("Systems are resetting overnight") == .none)
    }

    @Test
    func falsePositive_genericReset() {
        #expect(parser.parse("I'll reset everything") == .none)
        #expect(parser.parse("Let's reset and start fresh") == .none)
    }

    // MARK: - Announcements collection

    @Test
    func announcements_parsesMultipleTexts() {
        let texts = [
            "I will reset usage limits",
            "usage limits have been reset",
            "Codex is great"
        ]
        let results = parser.announcements(from: texts, sourceName: "thsottiaux", sourceURL: "https://twitter.com/thsottiaux")
        #expect(results.count == 2)
        #expect(results[0].status == .upcoming)
        #expect(results[1].status == .completed)
    }

    @Test
    func announcements_retainsSourceInfo() {
        let texts = ["I will reset usage limits"]
        let results = parser.announcements(from: texts, sourceName: "thsottiaux", sourceURL: "https://twitter.com/thsottiaux/status/123")
        #expect(results.count == 1)
        #expect(results[0].sourceName == "thsottiaux")
        #expect(results[0].sourceURL == "https://twitter.com/thsottiaux/status/123")
    }

    @Test
    func announcements_doesNotRetainRawText() {
        let texts = ["I will reset usage limits"]
        let results = parser.announcements(from: texts, sourceName: "thsottiaux", sourceURL: nil)
        #expect(results.count == 1)
        // rawText is intentionally absent from CodexResetAnnouncement to avoid persisting
        // arbitrary external content. The model has no rawText property.
    }

    // MARK: - Timestamp determinism

    @Test
    func announcements_batchSharesSameObservedAt() {
        // All announcements in a single batch share the same observedAt.
        let fixedDate = Date(timeIntervalSince1970: 1_800_000_000)
        let texts = [
            "I will reset usage limits",
            "usage limits have been reset",
            "Codex is great"
        ]
        let results = parser.announcements(from: texts, sourceName: "thsottiaux", sourceURL: nil, observedAt: fixedDate)
        #expect(results.count == 2)
        #expect(results[0].observedAt == fixedDate)
        #expect(results[1].observedAt == fixedDate)
    }

    @Test
    func announcements_fixedObservedAtIsStable() {
        // With a fixed observedAt, repeated calls produce equatable results.
        let fixedDate = Date(timeIntervalSince1970: 1_800_000_000)
        let texts = ["I will reset usage limits", "usage limits have been reset"]
        let results1 = parser.announcements(from: texts, sourceName: "thsottiaux", sourceURL: nil, observedAt: fixedDate)
        let results2 = parser.announcements(from: texts, sourceName: "thsottiaux", sourceURL: nil, observedAt: fixedDate)
        #expect(results1 == results2)
    }

    // MARK: - Multi-occurrence scanning

    @Test
    func multiOccurrence_invalidBoundaryFollowedByValid() {
        // "xreset usage limits" fails boundary check but "I reset usage limits" is valid.
        let result = parser.parse("xreset usage limits but I reset usage limits")
        #expect(result == .completed(confidence: 1.0))
    }

    @Test
    func multiOccurrence_concatenatedPrefixThenValidUpcoming() {
        // "theResetUsageLimits" is concatenated (no spaces) but "I will reset usage limits" is valid.
        let result = parser.parse("theResetUsageLimits event fired, then I will reset usage limits")
        #expect(result == .upcoming(confidence: 0.85))
    }

    @Test
    func multiOccurrence_concatenatedStillRejected() {
        // Pure concatenated text with no valid occurrence should not match.
        #expect(parser.parse("theResetUsageLimits event fired") == .none)
        #expect(parser.parse("predefined usage limit template") == .none)
    }

    // MARK: - No quota mutation (pure parser guarantee)

    @Test
    func parser_doesNotMutateQuota() {
        let result1 = parser.parse("I will reset usage limits")
        let result2 = parser.parse("usage limits have been reset")
        let result3 = parser.parse("limits are back to normal")

        #expect(result1 == .upcoming(confidence: 0.85))
        #expect(result2 == .completed(confidence: 1.0))
        #expect(result3 == .completed(confidence: 1.0))

        // Calling again proves determinism / no hidden state mutation
        #expect(parser.parse("I will reset usage limits") == .upcoming(confidence: 0.85))
        #expect(parser.parse("usage limits have been reset") == .completed(confidence: 1.0))
    }

    // MARK: - No network dependency

    @Test
    func parser_doesNotRequireNetwork() {
        let samples: [(String, CodexResetAnnouncementParser.ParseResult)] = [
            ("I will reset usage limits", .upcoming(confidence: 0.85)),
            ("usage limits have been reset", .completed(confidence: 1.0)),
            ("limits are back to normal", .completed(confidence: 1.0)),
            ("waived usage consumption", .ambiguous(confidence: 0.5)),
            ("Codex is great today", .none),
            ("Reset your password", .none)
        ]
        for (text, expected) in samples {
            #expect(parser.parse(text) == expected)
        }
    }

    // MARK: - Edge cases

    @Test
    func edgeCase_emptyString() {
        #expect(parser.parse("") == .none)
    }

    @Test
    func edgeCase_caseInsensitive() {
        #expect(parser.parse("I WILL RESET USAGE LIMITS") == .upcoming(confidence: 0.85))
        #expect(parser.parse("USAGE LIMITS HAVE BEEN RESET") == .completed(confidence: 1.0))
        #expect(parser.parse("Waived Usage Consumption") == .ambiguous(confidence: 0.5))
    }

    @Test
    func edgeCase_withExtraWhitespace() {
        #expect(parser.parse("  I will reset usage limits  ") == .upcoming(confidence: 0.85))
        #expect(parser.parse("\tI will reset usage limits\t") == .upcoming(confidence: 0.85))
    }

    @Test
    func edgeCase_multipleResetPhrasesInOneTweet() {
        // Completed takes priority (first in evaluation order)
        let result = parser.parse("I will reset usage limits and limits are back to normal")
        #expect(result == .completed(confidence: 1.0))
    }

    @Test
    func edgeCase_substringIsolation() {
        #expect(parser.parse("theResetUsageLimits event fired") == .none)
        #expect(parser.parse("predefined usage limit template") == .none)
    }
}