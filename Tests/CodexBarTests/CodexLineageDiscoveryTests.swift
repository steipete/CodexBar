import Foundation
import Testing
@testable import CodexBarCore

struct CodexLineageDiscoveryTests {
    @Test
    func `referenced parents cross the normal window and active archive roots transitively`() throws {
        let environment = try CostUsageTestEnvironment()
        defer { environment.cleanup() }
        let grandparentID = "11111111-1111-4111-8111-111111111111"
        let parentID = "22222222-2222-4222-8222-222222222222"
        let childID = "33333333-3333-4333-8333-333333333333"
        let unrelatedID = "44444444-4444-4444-8444-444444444444"
        let grandparent = try Self.writeRollout(
            root: environment.codexArchivedSessionsRoot,
            relativeDirectory: "",
            ownerID: grandparentID,
            metadataID: grandparentID)
        let parent = try Self.writeRollout(
            root: environment.codexSessionsRoot,
            relativeDirectory: "2025/01/01",
            ownerID: parentID,
            metadataID: parentID,
            parentID: grandparentID)
        let child = try Self.writeRollout(
            root: environment.codexSessionsRoot,
            relativeDirectory: "2026/07/09",
            ownerID: childID,
            metadataID: childID,
            parentID: parentID)
        _ = try Self.writeRollout(
            root: environment.codexArchivedSessionsRoot,
            relativeDirectory: "",
            ownerID: unrelatedID,
            metadataID: unrelatedID)

        let report = try CodexLineageDiscovery.discover(
            includedFiles: [child],
            roots: [environment.codexSessionsRoot, environment.codexArchivedSessionsRoot])

        #expect(Set(report.documents.map(\.ownerID)) == [childID, parentID, grandparentID])
        #expect(report.documents.map(\.ownerID).contains(unrelatedID) == false)
        #expect(report.referencedParentDocumentCount == 2)
        #expect(report.unresolvedParents.isEmpty)
        #expect(FileManager.default.fileExists(atPath: parent.path))
        #expect(FileManager.default.fileExists(atPath: grandparent.path))
    }

    @Test
    func `missing referenced parents are diagnosed without widening included documents`() throws {
        let environment = try CostUsageTestEnvironment()
        defer { environment.cleanup() }
        let child = try Self.writeRollout(
            root: environment.codexSessionsRoot,
            relativeDirectory: "2026/07/09",
            ownerID: "55555555-5555-4555-8555-555555555555",
            metadataID: "55555555-5555-4555-8555-555555555555",
            parentID: "66666666-6666-4666-8666-666666666666")

        let report = try CodexLineageDiscovery.discover(
            includedFiles: [child],
            roots: [environment.codexSessionsRoot, environment.codexArchivedSessionsRoot])

        #expect(report.documents.count == 1)
        #expect(report.referencedParentDocumentCount == 0)
        #expect(report.unresolvedParents == [.init(
            scopeID: environment.codexSessionsRoot.deletingLastPathComponent().path,
            sessionID: "66666666-6666-4666-8666-666666666666")])
    }

    @Test
    func `uuid parent references are matched case insensitively against filename owners`() throws {
        let environment = try CostUsageTestEnvironment()
        defer { environment.cleanup() }
        let parentID = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
        _ = try Self.writeRollout(
            root: environment.codexArchivedSessionsRoot,
            relativeDirectory: "",
            ownerID: parentID,
            metadataID: "parent-metadata-alias")
        let child = try Self.writeRollout(
            root: environment.codexSessionsRoot,
            relativeDirectory: "2026/07/09",
            ownerID: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",
            metadataID: "child-metadata",
            parentID: parentID.uppercased())

        let report = try CodexLineageDiscovery.discover(
            includedFiles: [child],
            roots: [environment.codexSessionsRoot, environment.codexArchivedSessionsRoot])

        #expect(report.documents.map(\.ownerID).contains(parentID))
        #expect(report.referencedParentDocumentCount == 1)
        #expect(report.unresolvedParents.isEmpty)
    }

    @Test
    func `parent lookup never crosses normalized Codex homes`() throws {
        let environment = try CostUsageTestEnvironment()
        defer { environment.cleanup() }
        let parentID = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
        let otherHomeSessions = environment.root
            .appendingPathComponent("other-home", isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true)
        _ = try Self.writeRollout(
            root: otherHomeSessions,
            relativeDirectory: "2026/07/09",
            ownerID: parentID,
            metadataID: parentID)
        let child = try Self.writeRollout(
            root: environment.codexSessionsRoot,
            relativeDirectory: "2026/07/09",
            ownerID: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",
            metadataID: "child",
            parentID: parentID)

        let report = try CodexLineageDiscovery.discover(
            includedFiles: [child],
            roots: [environment.codexSessionsRoot, otherHomeSessions])

        #expect(report.documents.map(\.ownerID) == ["bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"])
        #expect(report.unresolvedParents == [.init(
            scopeID: environment.codexSessionsRoot.deletingLastPathComponent().path,
            sessionID: parentID)])
    }

    @Test
    func `ambiguous parent identity is unresolved instead of path-order dependent`() throws {
        let environment = try CostUsageTestEnvironment()
        defer { environment.cleanup() }
        let parentAlias = "shared-parent-alias"
        _ = try Self.writeRollout(
            root: environment.codexArchivedSessionsRoot,
            relativeDirectory: "",
            ownerID: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
            metadataID: parentAlias)
        _ = try Self.writeRollout(
            root: environment.codexSessionsRoot,
            relativeDirectory: "2025/01/01",
            ownerID: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",
            metadataID: parentAlias)
        let child = try Self.writeRollout(
            root: environment.codexSessionsRoot,
            relativeDirectory: "2026/07/09",
            ownerID: "cccccccc-cccc-4ccc-8ccc-cccccccccccc",
            metadataID: "child",
            parentID: parentAlias)

        let report = try CodexLineageDiscovery.discover(
            includedFiles: [child],
            roots: [environment.codexSessionsRoot, environment.codexArchivedSessionsRoot])

        #expect(report.documents.count == 1)
        #expect(report.unresolvedParents == [.init(
            scopeID: environment.codexSessionsRoot.deletingLastPathComponent().path,
            sessionID: parentAlias)])
    }

    @Test
    func `compatible active and archived copies of one parent are both retained`() throws {
        let environment = try CostUsageTestEnvironment()
        defer { environment.cleanup() }
        let parentID = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
        _ = try Self.writeRollout(
            root: environment.codexArchivedSessionsRoot,
            relativeDirectory: "",
            ownerID: parentID,
            metadataID: parentID)
        _ = try Self.writeRollout(
            root: environment.codexSessionsRoot,
            relativeDirectory: "2025/01/01",
            ownerID: parentID,
            metadataID: parentID)
        let child = try Self.writeRollout(
            root: environment.codexSessionsRoot,
            relativeDirectory: "2026/07/09",
            ownerID: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",
            metadataID: "child",
            parentID: parentID)

        let report = try CodexLineageDiscovery.discover(
            includedFiles: [child],
            roots: [environment.codexSessionsRoot, environment.codexArchivedSessionsRoot])

        #expect(report.documents.count == 3)
        #expect(report.referencedParentDocumentCount == 2)
        #expect(report.unresolvedParents.isEmpty)
    }

    private static func writeRollout(
        root: URL,
        relativeDirectory: String,
        ownerID: String,
        metadataID: String,
        parentID: String? = nil) throws -> URL
    {
        let directory = relativeDirectory.isEmpty
            ? root
            : root.appendingPathComponent(relativeDirectory, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent(
            "rollout-2025-01-01T00-00-00-\(ownerID).jsonl")
        var metadata = #"{"type":"session_meta","payload":{"id":"\#(metadataID)""#
        if let parentID {
            metadata += #", "forked_from_id":"\#(parentID)""#
        }
        metadata += "}}\n"
        metadata += #"{"type":"event_msg","timestamp":"2026-07-09T12:00:00Z","payload":{"#
        metadata += #""type":"token_count","info":{"last_token_usage":{"input_tokens":10,"#
        metadata += #""cached_input_tokens":0,"output_tokens":1},"total_token_usage":{"input_tokens":10,"#
        metadata += #""cached_input_tokens":0,"output_tokens":1}}}}"#
        try metadata.write(to: fileURL, atomically: true, encoding: .utf8)
        return fileURL
    }
}
