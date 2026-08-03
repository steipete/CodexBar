import CodexBarCore
import Testing
@testable import CodexBar

struct ProviderRegistryTests {
    @Test
    func `descriptor registry is complete and deterministic`() {
        let descriptors = ProviderDescriptorRegistry.all
        let ids = descriptors.map(\.id)

        #expect(!descriptors.isEmpty, "ProviderDescriptorRegistry must not be empty.")
        #expect(Set(ids).count == ids.count, "ProviderDescriptorRegistry contains duplicate IDs.")

        let missing = Set(UsageProvider.allCases).subtracting(ids)
        #expect(missing.isEmpty, "Missing descriptors for providers: \(missing).")

        let secondPass = ProviderDescriptorRegistry.all.map(\.id)
        #expect(ids == secondPass, "ProviderDescriptorRegistry order changed between reads.")
    }

    @Test
    func `implementation registry is complete and deterministic`() {
        let implementations = ProviderImplementationRegistry.all
        let ids = implementations.map(\.id)

        #expect(!implementations.isEmpty, "ProviderImplementationRegistry must not be empty.")
        #expect(Set(ids).count == ids.count, "ProviderImplementationRegistry contains duplicate IDs.")

        let missing = Set(UsageProvider.allCases).subtracting(ids)
        #expect(missing.isEmpty, "Missing implementations for providers: \(missing).")

        let secondPass = ProviderImplementationRegistry.all.map(\.id)
        #expect(ids == secondPass, "ProviderImplementationRegistry order changed between reads.")
    }

    @Test
    func `icon styles derive from provider identifiers while preserving shared styles`() {
        #expect(IconStyle.allCases == UsageProvider.allCases.map(IconStyle.init(provider:)) + [.combined])

        let sharedStyles: [UsageProvider: UsageProvider] = [
            .azureopenai: .openai,
            .alibabatokenplan: .alibaba,
            .moonshot: .kimi,
        ]
        for descriptor in ProviderDescriptorRegistry.all {
            let expectedProvider = sharedStyles[descriptor.id] ?? descriptor.id
            #expect(
                descriptor.branding.iconStyle == IconStyle(provider: expectedProvider),
                "Unexpected icon style for \(descriptor.id.rawValue).")
        }
    }

    @Test
    func `provider log categories derive byte identical names`() {
        #expect(LogCategories.provider(.codex) == "codex")
        #expect(LogCategories.provider(.deepseek, scope: "usage") == "deepseek-usage")
        #expect(LogCategories.provider(.opencodego, scope: "usage") == "opencode-go-usage")
        #expect(LogCategories.codexRPC == "codex-rpc")
        #expect(LogCategories.openAIWebview == "openai-webview")
        #expect(LogCategories.minimaxAPITokenStore == "minimax-api-token-store")
        #expect(LogCategories.neuralWattUsage == "neuralwatt-usage")
    }

    @Test
    func `minimax sorts after zai in registry`() {
        let ids = ProviderDescriptorRegistry.all.map(\.id)
        guard let zaiIndex = ids.firstIndex(of: .zai),
              let minimaxIndex = ids.firstIndex(of: .minimax)
        else {
            Issue.record("Missing z.ai or MiniMax provider in registry order.")
            return
        }

        #expect(zaiIndex < minimaxIndex)
    }

    @Test
    func `provider confetti palettes are complete and branded`() {
        for descriptor in ProviderDescriptorRegistry.all {
            let palette = descriptor.branding.confettiPalette
            #expect(
                (2...3).contains(palette.count),
                "Invalid confetti palette for \(descriptor.id.rawValue).")
            let hasDistinctColors = palette.first.map { first in
                palette.dropFirst().contains { $0 != first }
            } ?? false
            #expect(
                hasDistinctColors,
                "Confetti palette for \(descriptor.id.rawValue) must contain distinct colors.")
        }

        #expect(ClaudeProviderDescriptor.descriptor.branding.confettiPalette == [
            ProviderColor(hex: 0xD97757),
            ProviderColor(hex: 0xF0EEE6),
            ProviderColor(hex: 0x141413),
        ])
        #expect(CodexProviderDescriptor.descriptor.branding.confettiPalette == [
            ProviderColor(hex: 0x736BD4),
            ProviderColor(hex: 0x97A9F7),
            ProviderColor(hex: 0xCFD4F7),
        ])
        #expect(OpenAIAPIProviderDescriptor.descriptor.branding.confettiPalette == [
            ProviderColor(hex: 0x000000),
            ProviderColor(hex: 0x808080),
            ProviderColor(hex: 0xFFFFFF),
        ])
    }
}
