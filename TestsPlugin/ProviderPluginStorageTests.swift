import Foundation
import Testing
@testable import CodexBarCore

struct ProviderPluginStorageTests {
    @Test
    func `local plugin approval and removal own persistent state`() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let providers = root.appendingPathComponent("providers")
        let directory = root.appendingPathComponent("state")
        try FileManager.default.createDirectory(at: providers, withIntermediateDirectories: true)
        let file = providers.appendingPathComponent("fixture.ts")
        let source = """
        defineProvider({
          id: 'storage-fixture', name: 'Storage fixture', endpoints: ['https://example.test'], settings: [],
          capabilities: [],
          fetchUsage(ctx) { ctx.storage.set('baseline', '42'); return {primary: {usedPercent: 1}}; }
        });
        """
        try Data(source.utf8).write(to: file)
        let loader = UserProviderPluginLoader(
            providersDirectory: providers,
            cacheDirectory: root.appendingPathComponent("cache"),
            storageDirectory: directory)
        let approval = ProviderPluginApprovalStore(fileURL: root.appendingPathComponent("approvals.json"))
        let original = try loader.load(fileURL: file)
        try approval.record(original.approvalBinding(settings: [:]))
        try Data(source.replacing("capabilities: []", with: "capabilities: ['persistent-storage']").utf8)
            .write(to: file)
        let plugin = try loader.load(fileURL: file)
        await #expect(throws: UserProviderPluginError.self) {
            _ = try await plugin.fetchUsage(settings: [:], secrets: [:], environment: [:], approvalStore: approval)
        }
        #expect(!FileManager.default.fileExists(atPath: directory.path))
        try approval.record(plugin.approvalBinding(settings: [:]))
        _ = try await plugin.fetchUsage(settings: [:], secrets: [:], environment: [:], approvalStore: approval)
        let stateFile = directory.appendingPathComponent("storage-fixture.json")
        #expect(FileManager.default.fileExists(atPath: stateFile.path))
        var config = CodexBarConfig.makeDefault()
        config.setProviderConfig(ProviderConfig(id: plugin.manifest.id))
        try UserProviderPluginManager.delete(plugin, approvalStore: approval, config: &config)
        #expect(!FileManager.default.fileExists(atPath: stateFile.path))
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(config.providerConfig(for: plugin.manifest.id) == nil)
        #expect(try !approval.isApproved(plugin.approvalBinding(settings: [:])))
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `bounded optional GET is available on both engines`(engine: ProviderPluginEngineKind) async throws {
        let runtime = try ProviderPluginRuntime(
            source: """
            defineProvider({
              id: "storage-fixture", name: "Storage fixture", endpoints: ["https://example.test"], settings: [],
              fetchUsage(ctx) { return {identity: {loginMethod: typeof ctx.http.getWithOptional}}; }
            });
            """,
            allowsDynamicID: true,
            engine: engine)
        #expect(try await runtime.fetchUsage().identity?.loginMethod == "function")
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `persistent storage API is available on both engines`(engine: ProviderPluginEngineKind) async throws {
        let runtime = try ProviderPluginRuntime(
            source: """
            defineProvider({
              id: "storage-fixture", name: "Storage fixture", endpoints: ["https://example.test"], settings: [],
              fetchUsage(ctx) { return {identity: {loginMethod: typeof ctx.storage}}; }
            });
            """,
            allowsDynamicID: true,
            engine: engine)
        #expect(try await runtime.fetchUsage().identity?.loginMethod == "object")
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `strings survive replacement runtimes without crossing instance namespaces`(
        engine: ProviderPluginEngineKind) async throws
    {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let write = try Self.runtime("ctx.storage.set('baseline', '42');", directory: directory, engine: engine)
        _ = try await write.fetchUsage()
        for otherEngine in BundledPluginTestSupport.engines {
            let read = try Self.runtime(
                "if (ctx.storage.get('baseline') !== '42') throw Error('lost baseline');",
                directory: directory,
                engine: otherEngine)
            _ = try await read.fetchUsage()
        }
        let other = try Self.runtime(
            "if (ctx.storage.get('baseline') !== null) throw Error('cross-instance read');",
            directory: directory,
            engine: engine,
            id: "other-fixture")
        _ = try await other.fetchUsage()
        let overwrite = try Self.runtime(
            """
            ctx.storage.set('baseline', '');
            if (ctx.storage.get('baseline') !== '') throw Error('empty string lost');
            ctx.storage.remove('baseline'); ctx.storage.remove('baseline');
            if (ctx.storage.get('baseline') !== null) throw Error('remove failed');
            ctx.storage.set('../other-fixture', 'ordinary key');
            ctx.storage.set('__proto__', 'ordinary value');
            if (ctx.storage.get('__proto__') !== 'ordinary value') throw Error('prototype collision');
            """,
            directory: directory,
            engine: engine)
        _ = try await overwrite.fetchUsage()
        let attributes = try FileManager.default.attributesOfItem(
            atPath: directory.appendingPathComponent("storage-fixture.json").path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `storage rejects undeclared authority and binds it into approval`(
        engine: ProviderPluginEngineKind) async throws
    {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let denied = try Self.runtime(
            "ctx.storage.set('key', 'value');",
            directory: directory,
            engine: engine,
            capability: false)
        await #expect(throws: ProviderPluginError.self) { _ = try await denied.fetchUsage() }
        #expect(!FileManager.default.fileExists(atPath: directory.path))
        let allowed = try Self.runtime("", directory: directory, engine: engine)
        let old = try ProviderPluginApprovalBinding(manifest: denied.manifest, settings: [:])
        let new = try ProviderPluginApprovalBinding(manifest: allowed.manifest, settings: [:])
        #expect(old != new)
        #expect(new.capabilities == ["persistent-storage"])
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `unknown types and UTF8 capacity failures preserve saved state`(
        engine: ProviderPluginEngineKind) async throws
    {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let runtime = try Self.runtime(
            """
            const rejects = (operation) => {
              try { operation(); } catch { return; }
              throw Error('invalid storage operation succeeded');
            };
            const invalid = [null, undefined, true, 42, {}, [], () => {}, Symbol('x'), 1n, new String('x')];
            for (const value of invalid) {
              rejects(() => ctx.storage.set('key', value));
              rejects(() => ctx.storage.get(value));
              rejects(() => ctx.storage.remove(value));
            }
            rejects(() => ctx.storage.set('', 'value'));
            rejects(() => ctx.storage.set('é'.repeat(65), 'value'));
            ctx.storage.set('keep', 'saved');
            rejects(() => ctx.storage.set('keep', 'é'.repeat(8193)));
            if (ctx.storage.get('keep') !== 'saved') throw Error('rejected write changed state');
            ctx.storage.remove('keep');
            for (let i = 0; i < 64; i++) ctx.storage.set(String(i), 'x');
            rejects(() => ctx.storage.set('65', 'x'));
            for (let i = 0; i < 64; i++) ctx.storage.remove(String(i));
            for (let i = 0; i < 3; i++) ctx.storage.set(String(i), 'x'.repeat(16384));
            rejects(() => ctx.storage.set('3', 'x'.repeat(16384)));
            if (ctx.storage.get('3') !== null) throw Error('byte cap partially wrote');
            """,
            directory: directory,
            engine: engine)
        _ = try await runtime.fetchUsage()
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `corrupt incompatible oversized and linked files fail closed`(engine: ProviderPluginEngineKind) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("storage-fixture.json")
        for contents in [
            "not JSON",
            #"{"version":2,"values":{}}"#,
            #"{"version":1,"values":{"key":42}}"#,
            String(repeating: "x", count: 400_001),
        ] {
            try Data(contents.utf8).write(to: path)
            let runtime = try Self.runtime("ctx.storage.get('key');", directory: directory, engine: engine)
            await #expect(throws: ProviderPluginError.self) { _ = try await runtime.fetchUsage() }
            #expect(try Data(contentsOf: path) == Data(contents.utf8))
        }
        try FileManager.default.removeItem(at: path)
        let outside = directory.appendingPathComponent("outside.json")
        let data = Data(#"{"version":1,"values":{"key":"outside"}}"#.utf8)
        try data.write(to: outside)
        try FileManager.default.createSymbolicLink(at: path, withDestinationURL: outside)
        let runtime = try Self.runtime("ctx.storage.set('key', 'changed');", directory: directory, engine: engine)
        await #expect(throws: ProviderPluginError.self) { _ = try await runtime.fetchUsage() }
        #expect(try Data(contentsOf: outside) == data)
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `removal deletes values and retires captured storage access`(engine: ProviderPluginEngineKind) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let runtime = try Self.runtime("ctx.storage.set('key', 'value');", directory: directory, engine: engine)
        _ = try await runtime.fetchUsage()
        try runtime.removePersistentStorage()
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("storage-fixture.json").path))
        await #expect(throws: ProviderPluginError.self) { _ = try await runtime.fetchUsage() }
        let replacement = try Self.runtime(
            """
            if (ctx.storage.get('key') !== null) throw Error('state survived deletion');
            """,
            directory: directory,
            engine: engine)
        _ = try await replacement.fetchUsage()
    }

    private static func runtime(
        _ body: String,
        directory: URL,
        engine: ProviderPluginEngineKind,
        id: String = "storage-fixture",
        capability: Bool = true) throws -> ProviderPluginRuntime
    {
        try ProviderPluginRuntime(
            source: """
            defineProvider({
              id: "\(id)", name: "Storage fixture", endpoints: ["https://example.test"], settings: [],
              capabilities: \(capability ? "['persistent-storage']" : "[]"),
              fetchUsage(ctx) { \(body) return {primary: {usedPercent: 1}}; }
            });
            """,
            allowsDynamicID: true,
            engine: engine,
            storageDirectory: directory)
    }
}
