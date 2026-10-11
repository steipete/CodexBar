import Foundation
import Testing
@testable import CodexBarCore

struct UsageLedgerMergeTests {
    static let now = Date(timeIntervalSince1970: 1_788_177_600)

    @Test
    func `copied requests count once while continuation and equal sized distinct requests count separately`() throws {
        let copied = Self.record("copied")
        let result = try Self.combine([
            Self.ledger([copied, Self.record("same-size-distinct")]),
            Self.ledger([copied, Self.record("continued")]),
        ])
        #expect(result.combined.totalTokens == 330)
        #expect(result.combined.costUSD == 0.75)
        #expect(result.combined.duplicateCount == 1)
        #expect(result.combined.conflictCount == 0)
        #expect(result.combined.coverageIsEstablished)
    }

    @Test
    func `request identity survives observation timestamp and session metadata changes`() throws {
        let first = Self.record("stable-response")
        var second = first
        second.timestampUnixMs -= 1000
        second.sessionID = UsageLedgerRecord.digest(["fixture-different-session"])
        let forward = try Self.combine([Self.ledger([first]), Self.ledger([second])])
        let reversed = try Self.combine([Self.ledger([second]), Self.ledger([first])])
        #expect(forward.combined.totalTokens == 110)
        #expect(forward.combined.duplicateCount == 1)
        #expect(forward.combined.conflictCount == 0)
        #expect(forward.combined.coverageIsEstablished)
        #expect(reversed.combined.totalTokens == forward.combined.totalTokens)
        #expect(reversed.combined.costUSD == forward.combined.costUSD)
    }

    @Test(arguments: ["tokens", "model", "reasoning", "cache"])
    func `contradictory usage is entirely withheld even with later agreeing observations`(field: String) throws {
        let original = Self.record("conflicting")
        var conflicting = original
        switch field {
        case "tokens":
            conflicting.inputTokens = 200
            conflicting.totalTokens = 210
        case "model": conflicting.model = "fixture-other-model"
        case "reasoning": conflicting.reasoningTokens = 3
        default: conflicting.cacheReadTokens = 21
        }
        let result = try Self.combine([
            Self.ledger([original, Self.record("unaffected")]),
            Self.ledger([conflicting]), Self.ledger([original]),
        ])
        #expect(result.combined.totalTokens == 110)
        #expect(result.combined.conflictCount == 1)
        #expect(!result.combined.coverageIsEstablished)
    }

    @Test(arguments: ["price", "provenance", "pricingModel", "pricingMode", "missingPrice"])
    func `conflicting pricing preserves tokens but withholds the combined dollar figure`(field: String) throws {
        let original = Self.record("priced-copy")
        var changed = original
        switch field {
        case "price": changed.costUSD = 0.5
        case "provenance": changed.costProvenance = .vendorMetered
        case "pricingModel": changed.pricingModel = "fixture-price-model"
        case "pricingMode": changed.pricingMode = "priority"
        default: changed.costUSD = nil
        }
        let result = try Self.combine([Self.ledger([original]), Self.ledger([changed])])
        #expect(result.combined.totalTokens == 110)
        #expect(result.combined.costUSD == nil)
        #expect(result.combined.unpricedCount == 1)
        #expect(result.combined.conflictCount == 0)
        #expect(result.combined.duplicateCount == 1)
    }

    @Test
    func `anonymous records are excluded and missing sources keep a partial known subtotal`() throws {
        let known = Self.record("known")
        var anonymous = Self.record("anonymous")
        anonymous.identity = .unidentified
        let first = try Self.combine([Self.ledger([known, anonymous])])
        #expect(first.combined.totalTokens == 110)
        #expect(first.combined.unidentifiedCount == 1)
        #expect(!first.combined.coverageIsEstablished)
        let missing = try UsageLedgerMerger.merge(reports: [
            .init(host: "local", ledger: Self.ledger([known])),
            .init(host: "remote", ledger: nil, error: "Fixture source unavailable."),
        ], provider: "codex", historyDays: 1)
        #expect(missing.combined.totalTokens == 110)
        #expect(missing.combined.costUSD == 0.25)
        #expect(!missing.combined.coverageIsEstablished)
    }

    @Test(arguments: ["codex", "claude"])
    func `mixed request and historical representations from separate sources are quarantined`(provider: String) throws {
        let request = Self.record("strong-request")
        var legacy = Self.record("same-request-missing-provider-id")
        legacy.identity = .legacyEvent
        if provider == "claude" {
            legacy.totalTokens += legacy.cacheReadTokens
        }
        var strong = request
        if provider == "claude" {
            strong.totalTokens += strong.cacheReadTokens
        }
        let result = try Self.combine([
            Self.ledger([strong], provider: provider), Self.ledger([legacy], provider: provider),
        ], provider: provider)
        #expect(result.combined.totalTokens == strong.totalTokens)
        #expect(result.combined.unidentifiedCount == 1)
        #expect(result.combined.legacyIdentityCount == 0)
        #expect(!result.combined.coverageIsEstablished)
    }

    @Test
    func `legacy-only copied events count once with explicitly partial identity coverage`() throws {
        var row = Self.record("historical-event")
        row.identity = .legacyEvent
        let result = try Self.combine([Self.ledger([row]), Self.ledger([row])])
        #expect(result.combined.totalTokens == 110)
        #expect(result.combined.duplicateCount == 1)
        #expect(result.combined.legacyIdentityCount == 1)
        #expect(!result.combined.coverageIsEstablished)
    }

    @Test
    func `same-source Claude request and fallback observations cannot inflate one copied response`() throws {
        var request = Self.record("claude-request-id")
        request.totalTokens += request.cacheReadTokens
        var fallback = Self.record("claude-session-message-fallback")
        fallback.identity = .legacyEvent
        fallback.totalTokens += fallback.cacheReadTokens
        let result = try Self.combine([Self.ledger([request, fallback], provider: "claude")], provider: "claude")
        #expect(result.combined.totalTokens == 130)
        #expect(result.combined.unidentifiedCount == 1)
        #expect(result.combined.legacyIdentityCount == 0)
        #expect(!result.combined.coverageIsEstablished)
    }

    @Test(arguments: [true, false])
    func `request without session provenance conservatively quarantines legacy observations`(sameSource: Bool) throws {
        var request = Self.record("request-without-session")
        request.sessionID = nil
        var legacy = Self.record("potentially-copied-legacy-event")
        legacy.identity = .legacyEvent
        let ledgers = sameSource
            ? [Self.ledger([request, legacy])]
            : [Self.ledger([request]), Self.ledger([legacy])]
        let result = try Self.combine(ledgers)
        #expect(result.combined.totalTokens == 110)
        #expect(result.combined.unidentifiedCount == 1)
        #expect(result.combined.legacyIdentityCount == 0)
        #expect(!result.combined.coverageIsEstablished)
    }

    @Test
    func `unavailable or entirely withheld usage has unknown cost while complete empty history is measured zero`() throws {
        let unavailable = try UsageLedgerMerger.merge(
            reports: [.init(host: "fixture-host", ledger: nil, error: "Fixture unavailable.")],
            provider: "codex", historyDays: 1)
        #expect(unavailable.combined.totalTokens == 0)
        #expect(unavailable.combined.costUSD == nil)
        #expect(!unavailable.combined.coverageIsEstablished)
        var anonymous = Self.record("withheld")
        anonymous.identity = .unidentified
        let withheld = try Self.combine([Self.ledger([anonymous])])
        #expect(withheld.combined.totalTokens == 0)
        #expect(withheld.combined.costUSD == nil)
        #expect(!withheld.combined.coverageIsEstablished)
        let empty = try Self.combine([Self.ledger([]), Self.ledger([])])
        #expect(empty.combined.totalTokens == 0)
        #expect(empty.combined.costUSD == 0)
        #expect(empty.combined.coverageIsEstablished)
    }

    @Test(arguments: [
        "schema",
        "provider",
        "days",
        "timezone",
        "window",
        "hash",
        "sessionHash",
        "total",
        "negative",
        "overflow",
        "future",
        "modelPath",
        "modelText",
        "modelLength",
        "pricingModelPath",
        "pricingModeText",
    ])
    func `malformed schema identity windows and token counts fail validation`(mutation: String) {
        var ledger = Self.ledger([Self.record("valid")])
        switch mutation {
        case "schema": ledger.schemaVersion = 2
        case "provider": ledger.provider = "claude"
        case "days": ledger.historyDays = 2
        case "timezone": ledger.bucketTimeZone = "fixture/invalid-zone"
        case "window": ledger.windowStartUnixMs = ledger.windowEndUnixMs + 1
        case "hash": ledger.records[0].id = "raw-request-id"
        case "sessionHash": ledger.records[0].sessionID = "raw-session-id"
        case "total": ledger.records[0].totalTokens += 1
        case "negative": ledger.records[0].inputTokens = -1
        case "modelPath": ledger.records[0].model = "/private/fixture-path"
        case "modelText": ledger.records[0].model = "fixture conversation text"
        case "modelLength": ledger.records[0].model = String(repeating: "x", count: 129)
        case "pricingModelPath": ledger.records[0].pricingModel = "/private/fixture-path"
        case "pricingModeText": ledger.records[0].pricingMode = "fixture arbitrary text"
        case "overflow":
            ledger.records[0].inputTokens = Int.max
            ledger.records[0].outputTokens = 1
            ledger.records[0].totalTokens = Int.max
        default: ledger.records[0].timestampUnixMs = ledger.windowEndUnixMs + 1
        }
        #expect(throws: UsageLedgerError.self) {
            try ledger.validate(provider: "codex", historyDays: 1)
        }
    }

    @Test
    func `incompatible reporting windows and merged token overflow are rejected`() throws {
        let first = Self.ledger([Self.record("first")])
        var shifted = Self.ledger([Self.record("second")])
        shifted.windowStartUnixMs -= 1
        #expect(throws: UsageLedgerError.self) { try Self.combine([first, shifted]) }
        var huge = Self.record("huge")
        huge.inputTokens = Int.max - 10
        huge.totalTokens = Int.max
        #expect(throws: UsageLedgerError.self) {
            try Self.combine([Self.ledger([huge]), Self.ledger([Self.record("extra")])])
        }
    }

    static func record(_ id: String) -> UsageLedgerRecord {
        .init(
            id: UsageLedgerRecord.digest([id]), sessionID: UsageLedgerRecord.digest(["fixture-session"]),
            identity: .request, timestampUnixMs: Int64(self.now.timeIntervalSince1970 * 1000) - 60000,
            model: "fixture-model", inputTokens: 100, cacheReadTokens: 20, outputTokens: 10,
            totalTokens: 110, costUSD: 0.25, reasoningTokens: 4, costProvenance: .listPriceEstimate,
            pricingModel: "fixture-model", pricingMode: "standard")
    }

    static func ledger(_ rows: [UsageLedgerRecord], provider: String = "codex") -> UsageLedger {
        .init(
            provider: provider, updatedAt: self.now, historyDays: 1, bucketTimeZone: "UTC",
            coverageIsEstablished: true, records: rows)
    }

    static func combine(_ ledgers: [UsageLedger], provider: String = "codex") throws -> CombinedUsageLedgerReport {
        try UsageLedgerMerger.merge(
            reports: ledgers.enumerated().map { .init(host: "fixture-host-\($0.offset)", ledger: $0.element) },
            provider: provider, historyDays: 1)
    }
}
