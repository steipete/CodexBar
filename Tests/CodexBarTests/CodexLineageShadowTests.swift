import Foundation
import Testing
@testable import CodexBarCore

struct CodexLineageShadowTests {
    @Test
    func `shadow comparison records deltas and diagnostics without changing legacy totals`() throws {
        let environment = try CostUsageTestEnvironment()
        defer { environment.cleanup() }
        let parentID = "11111111-1111-4111-8111-111111111111"
        let childID = "22222222-2222-4222-8222-222222222222"
        let parent = try Self.writeRollout(
            root: environment.codexSessionsRoot,
            ownerID: parentID,
            metadataID: parentID,
            events: [Self.event(timestamp: "2026-07-09T12:00:00Z", input: 100, totalInput: 100)])
        let child = try Self.writeRollout(
            root: environment.codexSessionsRoot,
            ownerID: childID,
            metadataID: childID,
            parentID: parentID,
            events: [
                Self.event(timestamp: "2026-07-09T12:00:00Z", input: 100, totalInput: 100),
                Self.event(timestamp: "not-a-time", input: 50, totalInput: 150),
            ])
        let legacyDays = ["2026-07-09": ["gpt-5.4": [150, 20, 10]]]

        let report = try CodexLineageShadow.run(
            includedFiles: [parent, child],
            roots: [environment.codexSessionsRoot],
            legacyDays: legacyDays,
            dayRange: "2026-07-09"..."2026-07-09",
            localTimeZone: .gmt)

        #expect(legacyDays["2026-07-09"]?["gpt-5.4"] == [150, 20, 10])
        #expect(report.days == [.init(
            day: "2026-07-09",
            legacy: .init(input: 150, cached: 20, output: 10),
            ledger: .zero)])
        #expect(report.days[0].delta == .init(input: -150, cached: -20, output: -10))
        #expect(report.acceptedObservationCount == 0)
        #expect(report.duplicateObservationCount == 0)
        #expect(report.componentCount == 0)
        #expect(report.rejectedObservationCount == 1)
        #expect(report.unresolvedParentCount == 0)
        #expect(report.primaryFamilyCount == 0)
        #expect(report.containedFamilyCount == 1)
        #expect(report.containmentReasonCounts == [.malformedTimestamp: 1])
    }

    private static func writeRollout(
        root: URL,
        ownerID: String,
        metadataID: String,
        parentID: String? = nil,
        events: [String]) throws -> URL
    {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("rollout-2026-07-09T12-00-00-\(ownerID).jsonl")
        let parent = parentID.map { #", "forked_from_id":"\#($0)""# } ?? ""
        let metadata = #"{"type":"session_meta","payload":{"id":"\#(metadataID)"\#(parent)}}"#
        try ([metadata] + events).joined(separator: "\n").write(to: file, atomically: true, encoding: .utf8)
        return file
    }

    private static func event(timestamp: String, input: Int, totalInput: Int) -> String {
        #"{"type":"event_msg","timestamp":"\#(timestamp)","payload":{"type":"token_count","info":{"#
            + #""last_token_usage":{"input_tokens":\#(input),"cached_input_tokens":0,"output_tokens":0},"#
            + #""total_token_usage":{"input_tokens":\#(totalInput),"cached_input_tokens":0,"output_tokens":0}}}}"#
    }
}
