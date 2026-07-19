import Foundation
import Testing
@testable import CodexBarCore

struct Issue2037FixtureHarnessTests {
    @Test
    func `issue 2037 fixture harness installs a sanitized family into an isolated codex home`() throws {
        let fixture = try Issue2037FixtureHarness.load(named: "harness-smoke")
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        try Issue2037FixtureHarness.install(fixture, into: env)

        #expect(fixture.manifest.schemaVersion == 1)
        #expect(fixture.manifest.redactionVersion == 1)
        #expect(fixture.manifest.familyAlias == "harness-smoke")
        #expect(fixture.manifest.files.map(\.alias) == ["parent", "child"])
        #expect(fixture.manifest.copiedPrefixes == [
            .init(parentAlias: "parent", childAlias: "child", length: 1),
        ])

        for file in fixture.manifest.files {
            let installed = env.root.appendingPathComponent(file.relativePath, isDirectory: false)
            #expect(FileManager.default.fileExists(atPath: installed.path), "missing \(file.alias)")
            let contents = try String(contentsOf: installed, encoding: .utf8)
            #expect(contents.contains("\"session_meta\""))
            #expect(contents.contains("\"token_count\""))
        }
    }
}
