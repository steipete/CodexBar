import CodexBarCore
import Testing
@testable import CodexBar

@MainActor
struct ProviderBrowsingSearchTests {
    @Test
    func `provider search recognizes existing CLI aliases`() {
        #expect(ProvidersPane.filteredProviders(
            [.codex, .alibaba],
            query: "  BAILÍAN  ",
            displayName: { ProviderDescriptorRegistry.descriptor(for: $0).metadata.displayName }) == [.alibaba])
    }

    @Test
    func `provider search matches every word across names and CLI aliases`() {
        let displayName: (UsageProvider) -> String = {
            ProviderDescriptorRegistry.descriptor(for: $0).metadata.displayName
        }
        #expect(ProvidersPane.filteredProviders(
            [.codex, .alibaba], query: "Alibaba BAILÍAN", displayName: displayName) == [.alibaba])
        #expect(ProvidersPane.filteredProviders(
            [.codex, .alibaba], query: "Alibaba missing", displayName: displayName).isEmpty)
        #expect(ProvidersPane.filteredProviders(
            [.codex, .alibaba], query: "  ", displayName: displayName) == [.codex, .alibaba])
    }

    @Test
    func `Qwen search includes mainland Token Plan and international Qwen Cloud`() {
        let matches = ProvidersPane.filteredProviders(
            [.codex, .alibabatokenplan, .qwencloud],
            query: "Qwen",
            displayName: { ProviderDescriptorRegistry.descriptor(for: $0).metadata.displayName })
        #expect(matches == [.alibabatokenplan, .qwencloud])
    }

    @Test(arguments: ["qwen-cn", "qianwen", "qianwenai"])
    func `mainland Qwen aliases find Alibaba Token Plan`(alias: String) {
        #expect(ProvidersPane.filteredProviders(
            [.codex, .alibabatokenplan, .qwencloud],
            query: alias,
            displayName: { ProviderDescriptorRegistry.descriptor(for: $0).metadata.displayName }) ==
            [.alibabatokenplan])
        #expect(ProviderDescriptorRegistry.cliNameMap[alias] == .alibabatokenplan)
    }

    @Test(arguments: ["qwen", "qwencloud", "qwen-cloud", "qwen-token-plan"])
    func `existing Qwen CLI names still select international Qwen Cloud`(name: String) {
        #expect(ProviderDescriptorRegistry.cliNameMap[name] == .qwencloud)
    }
}
