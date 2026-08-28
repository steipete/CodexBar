import AdaptiveReplayKit
import Foundation
import Testing

struct AdaptiveReplayTraceParserTests {
    private static let referenceNow = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private func encode(_ record: AdaptiveRefreshTraceRecord) throws -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(record)
        return try #require(String(data: data, encoding: .utf8))
    }

    @Test
    func `parses a well-formed trace and preserves record order`() throws {
        let records: [AdaptiveRefreshTraceRecord] = [
            .menuOpen(timestamp: Self.referenceNow),
            .decision(
                timestamp: Self.referenceNow.addingTimeInterval(1),
                menuAgeSeconds: 1,
                lowPowerModeEnabled: false,
                thermalState: .nominal,
                reason: "recentInteraction",
                delaySeconds: 120),
            .refreshCompleted(timestamp: Self.referenceNow.addingTimeInterval(121)),
        ]
        let text = try records.map(self.encode).joined(separator: "\n")

        let parsed = try AdaptiveRefreshTraceParser.parse(text)

        #expect(parsed.count == 3)
        #expect(parsed[0].kind == .menuOpen)
        #expect(parsed[1].kind == .decision)
        #expect(parsed[1].reason == "recentInteraction")
        #expect(parsed[1].delaySeconds == 120.0)
        #expect(parsed[2].kind == .refreshCompleted)
    }

    @Test
    func `ignores blank lines between records`() throws {
        let record = AdaptiveRefreshTraceRecord.menuOpen(timestamp: Self.referenceNow)
        let text = try "\n\(self.encode(record))\n\n"

        let parsed = try AdaptiveRefreshTraceParser.parse(text)

        #expect(parsed.count == 1)
    }

    @Test
    func `strict parsing accepts multiple CRLF records`() throws {
        let records: [AdaptiveRefreshTraceRecord] = [
            .menuOpen(timestamp: Self.referenceNow),
            .refreshCompleted(timestamp: Self.referenceNow.addingTimeInterval(1)),
        ]
        let text = try records.map(self.encode).joined(separator: "\r\n")

        let parsed = try AdaptiveRefreshTraceParser.parse(text)

        #expect(parsed.map(\.kind) == [.menuOpen, .refreshCompleted])
    }

    @Test
    func `empty trace parses to zero records`() throws {
        let parsed = try AdaptiveRefreshTraceParser.parse("")
        #expect(parsed.isEmpty)
    }

    @Test
    func `a malformed line fails the whole parse with a line number`() throws {
        let good = try self.encode(.menuOpen(timestamp: Self.referenceNow))
        let text = "\(good)\nnot json\n\(good)"

        #expect(throws: AdaptiveRefreshTraceParseError.self) {
            try AdaptiveRefreshTraceParser.parse(text)
        }

        do {
            _ = try AdaptiveRefreshTraceParser.parse(text)
            Issue.record("expected parse to throw")
        } catch let error as AdaptiveRefreshTraceParseError {
            #expect(error.lineNumber == 2)
            #expect(error.content == "not json")
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
    }

    @Test
    func `tolerant parsing skips malformed lines instead of failing`() throws {
        let good = try self.encode(.menuOpen(timestamp: Self.referenceNow))
        let text = "\(good)\nnot json\n\(good)"

        let parsed = AdaptiveRefreshTraceParser.parseTolerantly(text)

        #expect(parsed.count == 2)
    }

    @Test
    func `tolerant parsing accepts CRLF and skips only malformed records`() throws {
        let menuOpen = try self.encode(.menuOpen(timestamp: Self.referenceNow))
        let refresh = try self.encode(.refreshCompleted(timestamp: Self.referenceNow.addingTimeInterval(1)))
        let text = [menuOpen, "not json", refresh].joined(separator: "\r\n")

        let parsed = AdaptiveRefreshTraceParser.parseTolerantly(text)

        #expect(parsed.map(\.kind) == [.menuOpen, .refreshCompleted])
    }

    /// `timerAdvanced` round-trips its two extra fields (`previousScheduledAt`,
    /// `candidateScheduledAt`) and leaves the signal fields (`menuAgeSeconds`,
    /// `lowPowerModeEnabled`, `thermalState`) nil, matching the type's field-presence contract.
    @Test
    func `parses a timerAdvanced record and preserves its schedule fields`() throws {
        let record = AdaptiveRefreshTraceRecord.timerAdvanced(
            timestamp: Self.referenceNow,
            previousScheduledAt: Self.referenceNow.addingTimeInterval(1800),
            candidateScheduledAt: Self.referenceNow.addingTimeInterval(120),
            reason: "recentInteraction",
            delaySeconds: 120)
        let text = try self.encode(record)

        let parsed = try AdaptiveRefreshTraceParser.parse(text)

        #expect(parsed.count == 1)
        #expect(parsed[0].kind == .timerAdvanced)
        #expect(parsed[0].reason == "recentInteraction")
        #expect(parsed[0].delaySeconds == 120.0)
        #expect(parsed[0].previousScheduledAt == Self.referenceNow.addingTimeInterval(1800))
        #expect(parsed[0].candidateScheduledAt == Self.referenceNow.addingTimeInterval(120))
        #expect(parsed[0].menuAgeSeconds == nil)
        #expect(parsed[0].lowPowerModeEnabled == nil)
        #expect(parsed[0].thermalState == nil)
    }

    /// A `timerAdvanced` record whose advance had no prior schedule (`previousScheduledAt == nil`)
    /// — the "always advance" case `UsageStore.shouldAdvanceAdaptiveTimer` returns for a nil
    /// `scheduledAt` — round-trips the nil correctly rather than defaulting to some sentinel date.
    @Test
    func `a timerAdvanced record with no previous schedule round-trips a nil previousScheduledAt`() throws {
        let record = AdaptiveRefreshTraceRecord.timerAdvanced(
            timestamp: Self.referenceNow,
            previousScheduledAt: nil,
            candidateScheduledAt: Self.referenceNow.addingTimeInterval(120),
            reason: "recentInteraction",
            delaySeconds: 120)
        let text = try self.encode(record)

        let parsed = try AdaptiveRefreshTraceParser.parse(text)

        #expect(parsed[0].previousScheduledAt == nil)
    }

    /// Backward compatibility: the ~500 pre-existing lines in this machine's live trace were
    /// written before `codexActivitySeconds`/`claudeActivitySeconds` existed. A hand-written
    /// old-format `decision` line (no activity keys at all) must still decode, with both new
    /// fields nil rather than failing to parse.
    @Test
    func `an old-format decision line without activity fields decodes with nil activity signals`() throws {
        let oldFormatLine = """
        {"kind":"decision","timestamp":"2026-01-01T00:00:00Z","menuAgeSeconds":30,\
        "lowPowerModeEnabled":false,"thermalState":"nominal","reason":"longIdle","delaySeconds":1800}
        """

        let parsed = try AdaptiveRefreshTraceParser.parse(oldFormatLine)

        #expect(parsed.count == 1)
        #expect(parsed[0].reason == "longIdle")
        #expect(parsed[0].codexActivitySeconds == nil)
        #expect(parsed[0].claudeActivitySeconds == nil)
    }

    /// A `decision` record carrying both activity signals round-trips them exactly.
    @Test
    func `a decision record with activity signals round-trips both values`() throws {
        let record = AdaptiveRefreshTraceRecord.decision(
            timestamp: Self.referenceNow,
            menuAgeSeconds: 5,
            lowPowerModeEnabled: false,
            thermalState: .nominal,
            reason: "recentInteraction",
            delaySeconds: 120,
            codexActivitySeconds: 42,
            claudeActivitySeconds: 99)
        let text = try self.encode(record)

        let parsed = try AdaptiveRefreshTraceParser.parse(text)

        #expect(parsed[0].codexActivitySeconds == 42)
        #expect(parsed[0].claudeActivitySeconds == 99)
    }

    /// Encoding must omit nil activity fields rather than emitting explicit `null`s, so old
    /// tooling and hand-inspection of a trace stay unsurprised by fields it doesn't expect.
    @Test
    func `encoding a decision with nil activity signals omits both keys entirely`() throws {
        let record = AdaptiveRefreshTraceRecord.decision(
            timestamp: Self.referenceNow,
            menuAgeSeconds: 5,
            lowPowerModeEnabled: false,
            thermalState: .nominal,
            reason: "recentInteraction",
            delaySeconds: 120)
        let text = try self.encode(record)

        #expect(!text.contains("codexActivitySeconds"))
        #expect(!text.contains("claudeActivitySeconds"))
    }

    /// Backward compatibility for the "B layer" (session duration / transcript bytes /
    /// active-transcript count): an old-format line written before those three fields per CLI
    /// existed — including one already carrying the earlier "A layer" activity-seconds fields —
    /// must still decode, with all six new fields nil.
    @Test
    func `an old-format decision line without B-layer fields decodes with nil B-layer signals`() throws {
        let oldFormatLine = """
        {"kind":"decision","timestamp":"2026-01-01T00:00:00Z","menuAgeSeconds":30,\
        "lowPowerModeEnabled":false,"thermalState":"nominal","reason":"longIdle","delaySeconds":1800,\
        "codexActivitySeconds":42,"claudeActivitySeconds":99}
        """

        let parsed = try AdaptiveRefreshTraceParser.parse(oldFormatLine)

        #expect(parsed.count == 1)
        #expect(parsed[0].codexActivitySeconds == 42)
        #expect(parsed[0].claudeActivitySeconds == 99)
        #expect(parsed[0].codexSessionDurationSeconds == nil)
        #expect(parsed[0].claudeSessionDurationSeconds == nil)
        #expect(parsed[0].codexTranscriptBytes == nil)
        #expect(parsed[0].claudeTranscriptBytes == nil)
        #expect(parsed[0].codexActiveTranscriptCount == nil)
        #expect(parsed[0].claudeActiveTranscriptCount == nil)
    }

    /// A trace mixing a pre-B-layer line, a pre-A-layer (original phase 1) line, and a full
    /// current-format line all parse together — the parser never requires every line in a trace
    /// to share the same schema vintage.
    @Test
    func `a trace mixing old and new format decision lines parses every line`() throws {
        let phase1Line = """
        {"kind":"decision","timestamp":"2026-01-01T00:00:00Z","reason":"longIdle","delaySeconds":1800}
        """
        let aLayerOnlyLine = """
        {"kind":"decision","timestamp":"2026-01-02T00:00:00Z","reason":"warm","delaySeconds":300,\
        "codexActivitySeconds":10}
        """
        let currentLine = try self.encode(.decision(
            timestamp: Self.referenceNow,
            menuAgeSeconds: nil,
            lowPowerModeEnabled: false,
            thermalState: .nominal,
            reason: "recentInteraction",
            delaySeconds: 120,
            codexActivitySeconds: 1,
            claudeActivitySeconds: 2,
            codexSessionDurationSeconds: 3,
            claudeSessionDurationSeconds: 4,
            codexTranscriptBytes: 5,
            claudeTranscriptBytes: 6,
            codexActiveTranscriptCount: 7,
            claudeActiveTranscriptCount: 8))
        let text = [phase1Line, aLayerOnlyLine, currentLine].joined(separator: "\n")

        let parsed = try AdaptiveRefreshTraceParser.parse(text)

        #expect(parsed.count == 3)
        #expect(parsed[0].codexActivitySeconds == nil)
        #expect(parsed[1].codexActivitySeconds == 10)
        #expect(parsed[1].codexSessionDurationSeconds == nil)
        #expect(parsed[2].codexSessionDurationSeconds == 3)
        #expect(parsed[2].claudeActiveTranscriptCount == 8)
    }

    /// A `decision` record carrying all six B-layer fields round-trips them exactly.
    @Test
    func `a decision record with B-layer fields round-trips all six values`() throws {
        let record = AdaptiveRefreshTraceRecord.decision(
            timestamp: Self.referenceNow,
            menuAgeSeconds: 5,
            lowPowerModeEnabled: false,
            thermalState: .nominal,
            reason: "recentInteraction",
            delaySeconds: 120,
            codexSessionDurationSeconds: 600,
            claudeSessionDurationSeconds: 900,
            codexTranscriptBytes: 12345,
            claudeTranscriptBytes: 67890,
            codexActiveTranscriptCount: 2,
            claudeActiveTranscriptCount: 4)
        let text = try self.encode(record)

        let parsed = try AdaptiveRefreshTraceParser.parse(text)

        #expect(parsed[0].codexSessionDurationSeconds == 600)
        #expect(parsed[0].claudeSessionDurationSeconds == 900)
        #expect(parsed[0].codexTranscriptBytes == 12345)
        #expect(parsed[0].claudeTranscriptBytes == 67890)
        #expect(parsed[0].codexActiveTranscriptCount == 2)
        #expect(parsed[0].claudeActiveTranscriptCount == 4)
    }

    /// Encoding must omit nil B-layer fields rather than emitting explicit `null`s, matching the
    /// A-layer's contract.
    @Test
    func `encoding a decision with nil B-layer fields omits all six keys entirely`() throws {
        let record = AdaptiveRefreshTraceRecord.decision(
            timestamp: Self.referenceNow,
            menuAgeSeconds: 5,
            lowPowerModeEnabled: false,
            thermalState: .nominal,
            reason: "recentInteraction",
            delaySeconds: 120)
        let text = try self.encode(record)

        #expect(!text.contains("codexSessionDurationSeconds"))
        #expect(!text.contains("claudeSessionDurationSeconds"))
        #expect(!text.contains("codexTranscriptBytes"))
        #expect(!text.contains("claudeTranscriptBytes"))
        #expect(!text.contains("codexActiveTranscriptCount"))
        #expect(!text.contains("claudeActiveTranscriptCount"))
    }
}
