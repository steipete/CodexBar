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
