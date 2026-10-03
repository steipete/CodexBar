import Foundation
import Testing
@testable import CodexBarCore

struct AntigravityProfileScanTests {
    private typealias Fixture = AntigravityLocalFixture

    private func report(_ fixture: Fixture, homes: [String], environment: [String: String]? = nil)
        throws -> AntigravityLocalReader.DailyReportResult
    {
        try AntigravityLocalReader.makeDailyReportWithStatus(
            context: .init(environment: environment ?? fixture.environment, additionalProfileHomes: homes),
            calendar: Fixture.calendar,
            clock: { 0 })
    }

    @Test
    func `empty opt in keeps all primary roots and fallback unchanged`() throws {
        let fixture = try Fixture()
        let context = AntigravityLocalReader.Context(environment: fixture.environment, additionalProfileHomes: [])
        #expect(context.databaseRoots.map(\.path) == [
            fixture.root.path + "/.gemini/antigravity-cli/conversations",
            fixture.root.path + "/.gemini/antigravity",
            fixture.root.path + "/.gemini/antigravity/conversations",
        ])
        #expect(context.databaseRoots == fixture.context.databaseRoots)
        #expect(context.cacheRoot == fixture.context.cacheRoot)
        try fixture.jsonl([Fixture.cacheUsage])
        let normal = try fixture.report(clock: { 0 })
        let explicit = try self.report(fixture, homes: [])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        #expect(try encoder.encode(normal.report) == encoder.encode(explicit.report))
        #expect(normal.coverage == explicit.coverage)
    }

    @Test
    func `selected primary and additional profiles union September and October history`() throws {
        let fixture = try Fixture()
        let primary = try Fixture()
        let additional = try Fixture()
        try fixture.database("excluded-default", blobs: [Fixture.blob()])
        try primary.database("september-29", rootIndex: 2, blobs: [Fixture.blob(seconds: 1_790_683_200)])
        try additional.database("september-30", rootIndex: 0, blobs: [Fixture.blob(seconds: 1_790_769_600)])
        try additional.database("october-1", rootIndex: 1, blobs: [Fixture.blob(seconds: 1_790_856_000)])
        var environment = fixture.environment
        environment["GEMINI_CLI_HOME"] = primary.root.appendingPathComponent(".gemini").path
        let report = try self.report(
            fixture, homes: [additional.root.appendingPathComponent(".gemini").path], environment: environment)
        #expect(report.coverage == .complete)
        #expect(report.report.data.map(\.date) == ["2026-09-29", "2026-09-30", "2026-10-01"])
        #expect(report.report.summary?.totalTokens == 561)
    }

    @Test
    func `copied profile conversations preserve new rows and cross conversation response identities`() throws {
        let primary = try Fixture()
        let profile = try Fixture()
        let blobs = [Fixture.blob(), Fixture.blob(response: "same-response")]
        try primary.database("conversation-a", blobs: blobs)
        try profile.database("conversation-a", blobs: blobs + [Fixture.blob(response: "new-response")])
        try profile.database("conversation-b", rootIndex: 2, blobs: [Fixture.blob(response: "same-response")])
        let report = try self.report(primary, homes: [profile.root.appendingPathComponent(".gemini").path])
        #expect(report.coverage == .complete)
        #expect(report.report.summary?.totalTokens == 748)
        #expect(report.report.data.first?.requestCount == 4)
    }

    @Test
    func `conflicting profile copies cannot publish a misleading total`() throws {
        let primary = try Fixture()
        let profile = try Fixture()
        try primary.database("conversation-a", blobs: [Fixture.blob(input: 100)])
        try profile.database("conversation-a", blobs: [Fixture.blob(input: 200)])
        let report = try self.report(primary, homes: [profile.root.appendingPathComponent(".gemini").path])
        #expect(report.coverage == .partial)
        #expect(report.evidenceIsContradicted)
    }

    @Test
    func `missing and invalid homes do not hide healthy primary history`() throws {
        let fixture = try Fixture()
        try fixture.database(blobs: [Fixture.blob()])
        let missing = fixture.root.appendingPathComponent("missing").path
        let healthy = try self.report(fixture, homes: [missing, "", "relative/path"])
        #expect(healthy.coverage == .complete)
        #expect(healthy.report.summary?.totalTokens == 187)
        let broken = fixture.root.appendingPathComponent("broken/antigravity")
        try FileManager.default.createDirectory(
            at: broken.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try Data("not a directory".utf8).write(to: broken)
        let partial = try self.report(fixture, homes: [broken.deletingLastPathComponent().path])
        #expect(partial.coverage == .partial)
        #expect(partial.report.summary?.totalTokens == 187)
    }

    @Test
    func `tilde and symlink aliases scan once and home set order does not change scope`() throws {
        let fixture = try Fixture()
        try fixture.database(blobs: [Fixture.blob()])
        let home = fixture.root.appendingPathComponent(".gemini")
        let link = fixture.root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: home)
        let homes = ["~/.gemini", home.path, link.path]
        let report = try self.report(fixture, homes: homes)
        #expect(report.statistics.sqliteHandlesOpened == 1)
        #expect(report.report.summary?.totalTokens == 187)
        let forward = CostUsageFetcher.antigravityHistoryScope(
            environment: fixture.environment, additionalProfileHomes: homes)
        let backward = CostUsageFetcher.antigravityHistoryScope(
            environment: fixture.environment, additionalProfileHomes: Array(homes.reversed()))
        #expect(forward == backward)
        #expect(forward == CostUsageFetcher.antigravityHistoryScope(
            environment: fixture.environment, additionalProfileHomes: []))
    }
}
