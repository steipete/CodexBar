import Foundation
import Testing
@testable import CodexBarCore

struct CodexLineageTwoPassDiscoveryTests {
    @Test
    func `pass one retains descriptors without observations and follows exceptional archived parents`() throws {
        let environment = try CostUsageTestEnvironment()
        defer { environment.cleanup() }
        let parentID = "11111111-1111-4111-8111-111111111111"
        let childID = "22222222-2222-4222-8222-222222222222"
        _ = try Self.writeRollout(
            root: environment.codexArchivedSessionsRoot,
            ownerID: parentID,
            observations: 3)
        let child = try Self.writeRollout(
            root: environment.codexSessionsRoot.appendingPathComponent("2026/07/09"),
            ownerID: childID,
            parentID: parentID,
            observations: 2)

        let report = try CodexLineageTwoPassDiscovery.discover(
            includedFiles: [child],
            roots: [environment.codexSessionsRoot, environment.codexArchivedSessionsRoot])

        #expect(report.descriptors.count == 2)
        #expect(report.descriptors.reduce(0) { $0 + $1.observationCount } == 5)
        #expect(report.referencedParentDocumentCount == 1)
        #expect(report.unresolvedParents.isEmpty)
        #expect(report.peakRetainedObservationCount == 0)
    }

    @Test
    func `retained ancestor metadata does not suppress the physical parent`() throws {
        let environment = try CostUsageTestEnvironment()
        defer { environment.cleanup() }
        let parentID = Self.uuid(10)
        let parent = try Self.writeRollout(
            root: environment.codexArchivedSessionsRoot,
            ownerID: parentID,
            observations: 1)
        let child = try Self.writeRollout(
            root: environment.codexSessionsRoot,
            ownerID: Self.uuid(11),
            metadataID: parentID,
            parentID: parentID,
            observations: 1)

        let report = try CodexLineageTwoPassDiscovery.discover(
            includedFiles: [child],
            roots: [environment.codexSessionsRoot, environment.codexArchivedSessionsRoot])

        #expect(report.descriptors.map(\.fileURL).map(\.standardizedFileURL.path)
            .contains(parent.standardizedFileURL.path))
        #expect(report.referencedParentDocumentCount == 1)
        #expect(report.unresolvedParents.isEmpty)
    }

    @Test
    func `exceptional parent lookup uses parsed session identity when filename owner differs`() throws {
        let environment = try CostUsageTestEnvironment()
        defer { environment.cleanup() }
        let parentSessionID = Self.uuid(12)
        let parent = try Self.writeRollout(
            root: environment.codexArchivedSessionsRoot,
            ownerID: Self.uuid(13),
            metadataID: parentSessionID,
            observations: 1)
        let child = try Self.writeRollout(
            root: environment.codexSessionsRoot,
            ownerID: Self.uuid(14),
            parentID: parentSessionID,
            observations: 1)

        let report = try CodexLineageTwoPassDiscovery.discover(
            includedFiles: [child],
            roots: [environment.codexSessionsRoot, environment.codexArchivedSessionsRoot])

        #expect(report.descriptors.map(\.fileURL).map(\.standardizedFileURL.path)
            .contains(parent.standardizedFileURL.path))
        #expect(report.referencedParentDocumentCount == 1)
        #expect(report.unresolvedParents.isEmpty)
    }

    @Test
    func `streaming reconciliation loads one family at a time and warm reuse loads none`() throws {
        let environment = try CostUsageTestEnvironment()
        defer { environment.cleanup() }
        let first = try Self.writeRollout(root: environment.codexSessionsRoot, ownerID: Self.uuid(1), observations: 50)
        let second = try Self.writeRollout(root: environment.codexSessionsRoot, ownerID: Self.uuid(2), observations: 20)
        let discovery = try CodexLineageTwoPassDiscovery.discover(includedFiles: [first, second], roots: [])
        let families = try CodexLineageEngine.prepareDescriptorFamilies(descriptors: discovery.descriptors)
        var coldLoads = 0
        let cold = try CodexLineageEngine.reconcileStreaming(
            families: families,
            localTimeZone: .gmt,
            loadDocument: { descriptor in
                coldLoads += 1
                return try CodexLineageTwoPassDiscovery.loadDocument(descriptor)
            })
        var warmLoads = 0
        let warm = try CodexLineageEngine.reconcileStreaming(
            families: families,
            previousCache: cold.candidateCache,
            localTimeZone: .gmt,
            loadDocument: { descriptor in
                warmLoads += 1
                return try CodexLineageTwoPassDiscovery.loadDocument(descriptor)
            })

        #expect(coldLoads == 2)
        #expect(cold.diagnostics.observationCount == 70)
        #expect(cold.diagnostics.peakFamilyObservationCount == 50)
        #expect(warmLoads == 0)
        #expect(warm.diagnostics.reusedFamilyCount == 2)
        #expect(warm.report == cold.report)
    }

    @Test
    func `descriptor and family fingerprints are deterministic under file permutation`() throws {
        let environment = try CostUsageTestEnvironment()
        defer { environment.cleanup() }
        let first = try Self.writeRollout(root: environment.codexSessionsRoot, ownerID: Self.uuid(3), observations: 2)
        let second = try Self.writeRollout(root: environment.codexSessionsRoot, ownerID: Self.uuid(4), observations: 2)
        let forward = try CodexLineageTwoPassDiscovery.discover(includedFiles: [first, second], roots: [])
        let reverse = try CodexLineageTwoPassDiscovery.discover(includedFiles: [second, first], roots: [])
        let forwardFamilies = try CodexLineageEngine.prepareDescriptorFamilies(descriptors: forward.descriptors)
        let reverseFamilies = try CodexLineageEngine.prepareDescriptorFamilies(descriptors: reverse.descriptors)

        #expect(forwardFamilies.map(\.inputFingerprint) == reverseFamilies.map(\.inputFingerprint))
        #expect(forwardFamilies.map(\.stableID) == reverseFamilies.map(\.stableID))
    }

    @Test
    func `cancellation before streaming completion produces no candidate`() throws {
        let environment = try CostUsageTestEnvironment()
        defer { environment.cleanup() }
        let file = try Self.writeRollout(root: environment.codexSessionsRoot, ownerID: Self.uuid(5), observations: 100)
        let discovery = try CodexLineageTwoPassDiscovery.discover(includedFiles: [file], roots: [])
        let families = try CodexLineageEngine.prepareDescriptorFamilies(descriptors: discovery.descriptors)
        var checks = 0
        #expect(throws: CancellationError.self) {
            _ = try CodexLineageEngine.reconcileStreaming(
                families: families,
                localTimeZone: .gmt,
                checkCancellation: {
                    checks += 1
                    if checks == 4 {
                        throw CancellationError()
                    }
                })
        }
    }

    @Test
    func `pass two rejects a rollout changed after discovery`() throws {
        let environment = try CostUsageTestEnvironment()
        defer { environment.cleanup() }
        let file = try Self.writeRollout(
            root: environment.codexSessionsRoot,
            ownerID: Self.uuid(6),
            observations: 2)
        let discovery = try CodexLineageTwoPassDiscovery.discover(includedFiles: [file], roots: [])
        let descriptor = try #require(discovery.descriptors.first)
        try "\n".append(to: file)

        #expect(throws: CodexLineageTwoPassDiscovery.DiscoveryError.fileChangedDuringScan) {
            _ = try CodexLineageTwoPassDiscovery.loadDocument(descriptor)
        }
    }

    private static func writeRollout(
        root: URL,
        ownerID: String,
        metadataID: String? = nil,
        parentID: String? = nil,
        observations: Int) throws -> URL
    {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("rollout-2026-07-09T00-00-00-\(ownerID).jsonl")
        var lines = [#"{"type":"session_meta","payload":{"id":"\#(metadataID ?? ownerID)""#
            + (parentID.map { #", "forked_from_id":"\#($0)""# } ?? "") + "}}"]
        lines += (0..<observations).map { index in
            #"{"type":"event_msg","timestamp":"2026-07-09T12:00:00Z","#
                + #""payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":1,"#
                + #""cached_input_tokens":0,"output_tokens":0},"total_token_usage":{"input_tokens":\#(index + 1),"#
                + #""cached_input_tokens":0,"output_tokens":0}}}}"#
        }
        try lines.joined(separator: "\n").write(to: file, atomically: true, encoding: .utf8)
        return file
    }

    private static func uuid(_ value: Int) -> String {
        String(format: "00000000-0000-4000-8000-%012d", value)
    }
}

extension String {
    fileprivate func append(to fileURL: URL) throws {
        let handle = try FileHandle(forWritingTo: fileURL)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(self.utf8))
    }
}
