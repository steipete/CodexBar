import Foundation
import Testing
@testable import CodexBarCore

struct CostUsageTimestampOrderTests {
    private static func events(_ timestamps: [String]) -> [CostUsageCodexTokenSnapshot] {
        timestamps.map {
            CostUsageCodexTokenSnapshot(timestamp: $0, last: nil, total: nil, endOffset: nil)
        }
    }

    @Test
    func `large known prefix validates only append boundary and delta`() throws {
        let prefix = Self.events(Array(repeating: "2026-08-30T12:00:00.123Z", count: 100_000))
        let recorder = CostUsageScanner.CodexScanWorkRecorder()
        #expect(try CostUsageScanner.appendingCodexTokenTimestampsAreMonotonic(
            Self.events(["2026-08-30T12:00:01Z"]),
            to: prefix,
            prefixIsMonotonic: true,
            workRecorder: recorder))
        #expect(recorder.snapshot().tokenTimestampComparisons == 1)
        #expect(try CostUsageScanner.appendingCodexTokenTimestampsAreMonotonic(
            [], to: prefix, prefixIsMonotonic: true, workRecorder: recorder))
        #expect(recorder.snapshot().tokenTimestampComparisons == 1)
    }

    @Test
    func `legacy unknown prefix is validated once and false stays false`() throws {
        let prefix = Self.events(Array(repeating: "2026-08-30T12:00:00Z", count: 4096))
        let delta = Self.events(["2026-08-30T12:00:01Z", "2026-08-30T12:00:02Z"])
        let recorder = CostUsageScanner.CodexScanWorkRecorder()
        #expect(try CostUsageScanner.appendingCodexTokenTimestampsAreMonotonic(
            delta, to: prefix, prefixIsMonotonic: nil, workRecorder: recorder))
        #expect(recorder.snapshot().tokenTimestampComparisons == 4097)
        let falseRecorder = CostUsageScanner.CodexScanWorkRecorder()
        #expect(try !CostUsageScanner.appendingCodexTokenTimestampsAreMonotonic(
            delta, to: prefix, prefixIsMonotonic: false, workRecorder: falseRecorder))
        #expect(falseRecorder.snapshot().tokenTimestampComparisons == 0)
        #expect(try !CostUsageScanner.appendingCodexTokenTimestampsAreMonotonic(
            [], to: Self.events(["z-invalid", "a-invalid"]), prefixIsMonotonic: nil))
    }

    @Test(arguments: [
        (["2026-08-30T12:00:01Z"], ["2026-08-30T12:00:00Z"], false),
        (["2026-08-30T12:00:00Z"], ["2026-08-30T12:00:02Z", "2026-08-30T12:00:01Z"], false),
        (["2026-08-30T12:00:00.1239Z"], ["2026-08-30T12:00:00.1231Z"], true),
        (["2026-08-30T12:00:00Z"], ["2026-08-30T13:00:00+01:00"], true),
        (["2026-08-30T12:00:00Z"], ["2026-08-30T13:00:00+02:00"], false),
        (["a-invalid"], ["b-invalid", "c-invalid"], true),
        (["b-invalid"], ["a-invalid"], false),
        (["2026-08-30T12:00:00Z"], ["invalid"], true),
        (["invalid"], ["2026-08-30T12:00:00Z"], false),
        ([], ["2026-08-30T12:00:00Z"], true),
        ([], [], true),
    ])
    func `boundary and delta retain date and malformed lexical ordering`(
        _ fixture: ([String], [String], Bool)) throws
    {
        let (prefix, delta, expected) = fixture
        #expect(try CostUsageScanner.appendingCodexTokenTimestampsAreMonotonic(
            Self.events(delta), to: Self.events(prefix), prefixIsMonotonic: true) == expected)
        #expect(try CostUsageScanner.codexTokenTimestampsAreMonotonic(Self.events(prefix + delta)) == expected)
    }

    @Test
    func `necessary legacy validation cooperatively cancels`() {
        let prefix = Self.events(Array(repeating: "2026-08-30T12:00:00Z", count: 100_000))
        let recorder = CostUsageScanner.CodexScanWorkRecorder()
        #expect(throws: CancellationError.self) {
            try CostUsageScanner.appendingCodexTokenTimestampsAreMonotonic(
                [],
                to: prefix,
                prefixIsMonotonic: nil,
                checkCancellation: {
                    if recorder.snapshot().tokenTimestampComparisons >= 256 {
                        throw CancellationError()
                    }
                },
                workRecorder: recorder)
        }
        #expect(recorder.snapshot().tokenTimestampComparisons < 1000)
    }
}
