#if canImport(JavaScriptCore)
import Foundation
import Testing
@testable import CodexBarCore

struct UserProviderPluginCacheTests {
    @Test
    func `TypeScript revisions retain only current output without invalidating loaded runtimes`() async throws {
        let fixture = try UserProviderPluginTests.Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let loader = fixture.loader(transport: UserProviderPluginTests.RecordingTransport(responseJSON: "{}"))
        let sibling = try loader.load(fileURL: fixture.write(
            name: "typed-extra.ts", source: """
            defineProvider({
              id: "typed-extra", name: "Sibling", endpoints: ["https://typed.example"], settings: [],
              fetchUsage() { return { primary: { usedPercent: 50 } }; },
            });
            """))
        var revisions: [UserProviderPlugin] = []
        for revision in 0..<5 {
            let source = """
            const percentage: number = \(revision);
            defineProvider({
              id: "typed-meter", name: "Typed Meter", endpoints: ["https://typed.example"], settings: [],
              async fetchUsage() { return { primary: { usedPercent: percentage } }; },
            });
            // \(String(repeating: "padding", count: 2900))
            """
            let plugin = try loader.load(fileURL: fixture.write(name: "typed.ts", source: source))
            revisions.append(plugin)
            let artifacts = try FileManager.default.contentsOfDirectory(
                at: fixture.cache, includingPropertiesForKeys: nil)
            let expected = try [#require(plugin.transpiledCacheURL), #require(sibling.transpiledCacheURL)]
            #expect(Set(artifacts.map(\.lastPathComponent)) == Set(expected.map(\.lastPathComponent)))
        }
        for (revision, plugin) in revisions.enumerated() {
            let snapshot = try await plugin.runtime.fetchUsage(settings: [:], secrets: [:])
            #expect(snapshot.primary?.usedPercent == Double(revision))
        }
        let current = try #require(revisions.last)
        #expect(try loader.load(fileURL: current.fileURL).transpileCacheHit)
        _ = try fixture.write(name: "typed.ts", source: "const percentage: number = ;")
        #expect(throws: (any Error).self) { try loader.load(fileURL: current.fileURL) }
        #expect(try FileManager.default.fileExists(atPath: #require(current.transpiledCacheURL).path))
        var config = CodexBarConfig(providers: [])
        try UserProviderPluginManager.delete(current, approvalStore: fixture.approvals, config: &config)
        #expect(try FileManager.default.fileExists(atPath: #require(sibling.transpiledCacheURL).path))
    }
}
#endif
