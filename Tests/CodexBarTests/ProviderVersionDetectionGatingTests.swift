import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@Suite("Provider version detection gating")
@MainActor
struct ProviderVersionDetectionGatingTests {
    @Test
    func `disabled providers are excluded from version probes`() {
        let implementations = UsageStore.versionDetectionImplementations(enabled: [.codex, .claude])
        let ids = Set(implementations.map(\.id))
        #expect(ids == [.codex, .claude])
        #expect(!ids.contains(.antigravity))
    }

    @Test
    func `empty enabled set probes nothing`() {
        #expect(UsageStore.versionDetectionImplementations(enabled: []).isEmpty)
    }

    @Test
    func `enabling a provider includes it in version probes`() {
        let ids = Set(UsageStore.versionDetectionImplementations(
            enabled: [.codex, .antigravity]).map(\.id))
        #expect(ids.contains(.antigravity))
    }
}
