@testable import CodexBarCLI
import CodexBarCore
import Testing

@Suite
struct ProviderSelectionTests {
    @Test
    func threeEnabledProviders_returnsOnlyThoseThree() {
        let enabled: [UsageProvider] = [.codex, .claude, .copilot]
        let result = CodexBarCLI._providerSelectionForTesting(
            rawOverride: nil, enabled: enabled).asList

        #expect(Set(result) == Set(enabled),
                "Expected \(enabled.map(\.rawValue)) but got \(result.map(\.rawValue))")
    }
}
