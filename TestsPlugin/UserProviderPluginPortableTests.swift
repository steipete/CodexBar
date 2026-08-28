import Foundation
import Testing
@testable import CodexBarCore

struct UserProviderPluginPortableTests {
    @Test
    func `bundled plugins are free of raw Intl references`() throws {
        let bundle = try #require(CodexBarCoreResources.bundle)
        for name in [
            "crof", "venice", "openrouter", "clawrouter", "deepgram", "sub2api", "synthetic", "openai", "zai",
            "poe", "xai", "manus", "perplexity", "t3chat", "qoder",
        ] {
            let url = try #require(bundle.url(forResource: name, withExtension: "js"))
            let source = try String(contentsOf: url, encoding: .utf8)
            try ProviderPluginSourceLint.validateBundled(source, name: name)
        }

        #expect(throws: ProviderPluginError.self) {
            try ProviderPluginSourceLint.validateBundled("Intl.DateTimeFormat()", name: "fixture")
        }
    }

    @Test
    func `QuickJS executes the bundled Sucrase transform`() throws {
        let bundle = try #require(CodexBarCoreResources.bundle)
        let resourceURL = try #require(bundle.url(
            forResource: "sucrase-3.35.1.min",
            withExtension: "js"))
        let sucraseSource = try String(contentsOf: resourceURL, encoding: .utf8)
        let output = try QuickJSProviderPluginEngine.transpileTypeScript(
            source: "const percentage: number = 37;",
            sucraseSource: sucraseSource)

        #expect(output.contains("const percentage = 37"))
        #expect(!output.contains(": number"))
    }

    @Test
    func `QuickJS rejects allocations beyond its heap cap`() async throws {
        let runtime = try ProviderPluginRuntime(
            source: """
            defineProvider({
              id: "synthetic",
              name: "Memory Limit",
              endpoints: ["https://api.synthetic.new"],
              settings: [],
              async fetchUsage() {
                const bytes = new Uint8Array(80 * 1024 * 1024);
                return { primary: { usedPercent: bytes[0] } };
              },
            });
            """,
            engine: .quickJS)

        await #expect(throws: ProviderPluginError.self) {
            _ = try await runtime.fetchUsage()
        }
    }

    @Test
    func `TypeScript user plugin loads and fetches portably`() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codexbar-plugin-portable-\(UUID().uuidString)")
        let providers = root.appendingPathComponent("providers")
        let cache = root.appendingPathComponent("cache")
        try FileManager.default.createDirectory(at: providers, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let pluginURL = providers.appendingPathComponent("portable.ts")
        let source = """
        const percentage: number = 37;
        defineProvider({
          id: "portable-meter",
          name: "Portable Meter",
          endpoints: ["https://portable.example"],
          settings: [],
          async fetchUsage(ctx: unknown) {
            return { primary: { usedPercent: percentage } };
          },
        });
        """
        try Data(source.utf8).write(to: pluginURL)
        let loader = UserProviderPluginLoader(providersDirectory: providers, cacheDirectory: cache)
        let plugin = try loader.load(fileURL: pluginURL)
        let approvals = ProviderPluginApprovalStore(fileURL: root.appendingPathComponent("approvals.json"))
        try approvals.record(plugin.approvalBinding(settings: [:]))

        let snapshot = try await plugin.fetchUsage(settings: [:], secrets: [:], approvalStore: approvals)

        #expect(snapshot.primary?.usedPercent == 37)
        #expect(plugin.transpiledCacheURL != nil)
    }
}
