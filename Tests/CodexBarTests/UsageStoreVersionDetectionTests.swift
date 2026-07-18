import CodexBarCore
import Testing
@testable import CodexBar

struct UsageStoreVersionDetectionTests {
    @Test
    func `version detection only probes enabled providers`() {
        let implementations = UsageStore.implementationsForVersionDetection(
            enabledProviders: [.claude, .codex],
            implementations: ProviderCatalog.all)

        let ids = implementations.map(\.id)
        #expect(ids == [.claude, .codex])
        #expect(!ids.contains(.antigravity))
    }
}
