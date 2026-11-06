import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

@Suite(.serialized, CostUsageClaudeCacheFixtures())
struct CostUsageScannerClaudeSymlinkTests {
    @Test
    func `symlinked project roots retain history and deduplicate without traversing nested directory links`() throws {
        var fixture = try CostUsageClaudeReportContextTests.Fixture()
        defer { fixture.env.cleanup() }
        let fm = FileManager.default
        let physicalConfig = fixture.env.root.appendingPathComponent("physical-config")
        let physicalProjects = physicalConfig.appendingPathComponent("projects")
        try fm.createDirectory(at: physicalConfig, withIntermediateDirectories: true)
        _ = try fixture.write(path: "project/session.jsonl", day: fixture.now, id: "kept", input: 123)
        try fm.moveItem(at: fixture.env.claudeProjectsRoot, to: physicalProjects)
        fixture.options.claudeProjectsRoots = [physicalProjects]

        let outside = fixture.env.root.appendingPathComponent("outside")
        try fm.createDirectory(at: outside, withIntermediateDirectories: true)
        try fixture.event(day: fixture.now, id: "outside", input: 999)
            .write(to: outside.appendingPathComponent("outside.jsonl"), atomically: true, encoding: .utf8)
        try fm.createSymbolicLink(
            at: physicalProjects.appendingPathComponent("nested-link"),
            withDestinationURL: outside)
        let oracle = try fixture.load(context: .regular, days: 30).0
        #expect(oracle.summary?.totalInputTokens == 123)

        let configLink = fixture.env.root.appendingPathComponent(".claude")
        try fm.createSymbolicLink(at: configLink, withDestinationURL: physicalConfig)
        let projectsLink = fixture.env.root.appendingPathComponent(".config/claude/projects")
        try fm.createDirectory(at: projectsLink.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: projectsLink, withDestinationURL: physicalProjects)
        let roots = ClaudeConfigPaths.costProjectsRoots(environment: ["HOME": fixture.env.root.path])
        #expect(roots.filter { $0.resolvingSymlinksInPath() == physicalProjects.resolvingSymlinksInPath() }.count == 1)
        #expect(SettingsStore.hasAnyTokenCostUsageSources(env: [:], homeDirectory: fixture.env.root))

        for selected in [roots, [projectsLink, physicalProjects]] {
            fixture.options.claudeProjectsRoots = selected
            let (report, work) = try fixture.load(
                context: .regular,
                days: 30,
                cacheRoot: fixture.env.root.appendingPathComponent("cache-\(UUID().uuidString)"))
            #expect(report.data == oracle.data)
            #expect(report.summary == oracle.summary)
            #expect(report.hourly == oracle.hourly)
            #expect(report.quotaSlices == oracle.quotaSlices)
            #expect(work.transcriptParses == 1)
        }
    }

    @Test
    func `symlinked config directory works for explicit and account cost roots`() throws {
        var fixture = try CostUsageClaudeReportContextTests.Fixture()
        defer { fixture.env.cleanup() }
        _ = try fixture.write(path: "project/session.jsonl", day: fixture.now, id: "kept", input: 321)
        let oracle = try fixture.load(context: .regular, days: 30).0
        let config = fixture.env.root.appendingPathComponent("config")
        try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
        try FileManager.default.moveItem(
            at: fixture.env.claudeProjectsRoot,
            to: config.appendingPathComponent("projects"))
        let link = fixture.env.root.appendingPathComponent("linked-config")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: config)
        let environment = ["HOME": fixture.env.root.path, "CLAUDE_CONFIG_DIR": link.path]
        for accountRoot in [nil, link.path] {
            fixture.options.claudeProjectsRoots = ClaudeConfigPaths.costProjectsRoots(
                accountConfigDirectory: accountRoot,
                environment: environment)
            let report = try fixture.load(
                context: .regular,
                days: 30,
                cacheRoot: fixture.env.root.appendingPathComponent("cache-\(UUID().uuidString)")).0
            #expect(report.data == oracle.data)
            #expect(report.summary == oracle.summary)
        }
    }
}
