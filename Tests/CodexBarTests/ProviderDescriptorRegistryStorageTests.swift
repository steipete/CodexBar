import Testing
@testable import CodexBarCore

struct ProviderDescriptorRegistryStorageTests {
    @Test
    func `replacing a descriptor updates lookup and ordered views without moving it`() {
        let store = ProviderDescriptorRegistry.Store()
        store.register(Self.descriptor(.codex, name: "original"))
        store.register(Self.descriptor(.claude, name: "second"))
        store.register(Self.descriptor(.codex, name: "replacement"))

        #expect(store.all.map(\.id) == [.codex, .claude])
        #expect(store.all.map(\.cli.name) == ["replacement", "second"])
        #expect(store.descriptor(for: .codex)?.cli.name == "replacement")
        #expect(store.descriptor(for: .claude)?.cli.name == "second")
        #expect(store.descriptor(for: .cursor) == nil)
    }

    private static func descriptor(_ id: UsageProvider, name: String) -> ProviderDescriptor {
        let base = ProviderDescriptorRegistry.descriptor(for: id)
        return ProviderDescriptor(
            id: id,
            metadata: base.metadata,
            branding: base.branding,
            tokenCost: base.tokenCost,
            fetchPlan: base.fetchPlan,
            cli: ProviderCLIConfig(name: name, versionDetector: nil))
    }
}
