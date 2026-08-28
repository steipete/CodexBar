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
        #expect(ids == UsageProvider.allCases, "Descriptor manifest order must match UsageProvider.")

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
        #expect(ids == UsageProvider.allCases, "Implementation manifest order must match UsageProvider.")

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
        let actual = [
            LogCategories.provider(.abacus, scope: "cookie"),
            LogCategories.provider(.abacus, scope: "usage"),
            LogCategories.provider(.amp),
            LogCategories.provider(.antigravity),
            LogCategories.provider(.augment),
            LogCategories.provider(.augment, scope: "keepalive"),
            LogCategories.provider(.bedrock, scope: "usage"),
            LogCategories.provider(.claude, scope: "cli"),
            LogCategories.provider(.claude, scope: "probe"),
            LogCategories.provider(.claude, scope: "usage"),
            LogCategories.provider(.codex, scope: "rpc"),
            LogCategories.provider(.commandcode, scope: "cookie"),
            LogCategories.provider(.commandcode, scope: "usage"),
            LogCategories.provider(.copilot, scope: "token-store"),
            LogCategories.provider(.cursor, scope: "login"),
            LogCategories.provider(.deepseek, scope: "settings"),
            LogCategories.provider(.deepseek, scope: "usage"),
            LogCategories.provider(.deepgram, scope: "usage"),
            LogCategories.provider(.devin),
            LogCategories.provider(.doubao, scope: "usage"),
            LogCategories.provider(.elevenlabs, scope: "usage"),
            LogCategories.provider(.gemini, scope: "probe"),
            LogCategories.provider(.grok),
            LogCategories.provider(.kimi, scope: "api"),
            LogCategories.provider(.kimi, scope: "cookie"),
            LogCategories.provider(.kimi, scope: "token-store"),
            LogCategories.provider(.kimi, scope: "web"),
            LogCategories.provider(.kiro),
            LogCategories.provider(.longcat, scope: "api"),
            LogCategories.provider(.longcat, scope: "cookie"),
            LogCategories.provider(.longcat, scope: "web"),
            LogCategories.provider(.manus, scope: "api"),
            LogCategories.provider(.manus, scope: "cookie"),
            LogCategories.provider(.manus, scope: "web"),
            LogCategories.provider(.minimax, scope: "api-token-store"),
            LogCategories.provider(.minimax, scope: "cookie"),
            LogCategories.provider(.minimax, scope: "cookie-store"),
            LogCategories.provider(.minimax, scope: "usage"),
            LogCategories.provider(.minimax, scope: "web"),
            LogCategories.provider(.mimo, scope: "cookie"),
            LogCategories.provider(.moonshot, scope: "usage"),
            LogCategories.provider(.neuralwatt, scope: "usage"),
            LogCategories.provider(.notion),
            LogCategories.provider(.openai, scope: "web"),
            LogCategories.provider(.openai, scope: "webview"),
            LogCategories.provider(.ollama),
            LogCategories.provider(.opencode, scope: "usage"),
            LogCategories.provider(.opencodego, scope: "usage"),
            LogCategories.provider(.openrouter, scope: "usage"),
            LogCategories.provider(.perplexity, scope: "api"),
            LogCategories.provider(.perplexity, scope: "cookie"),
            LogCategories.provider(.perplexity, scope: "web"),
            LogCategories.provider(.poe, scope: "usage"),
            LogCategories.provider(.qoder, scope: "cookie"),
            LogCategories.provider(.qoder, scope: "usage"),
            LogCategories.provider(.synthetic, scope: "token-store"),
            LogCategories.provider(.synthetic, scope: "usage"),
            LogCategories.provider(.t3chat),
            LogCategories.provider(.venice, scope: "usage"),
            LogCategories.provider(.vertexai, scope: "fetcher"),
            LogCategories.provider(.warp, scope: "usage"),
            LogCategories.provider(.zed),
            LogCategories.provider(.zai, scope: "settings"),
            LogCategories.provider(.zai, scope: "token-store"),
            LogCategories.provider(.zai, scope: "usage"),
            LogCategories.provider(.stepfun, scope: "usage"),
            LogCategories.provider(.zoommate),
        ]
        #expect(actual == [
            "abacus-cookie", "abacus-usage", "amp", "antigravity", "augment", "augment-keepalive",
            "bedrock-usage", "claude-cli", "claude-probe", "claude-usage", "codex-rpc", "commandcode-cookie",
            "commandcode-usage", "copilot-token-store", "cursor-login", "deepseek-settings", "deepseek-usage",
            "deepgram-usage", "devin", "doubao-usage", "elevenlabs-usage", "gemini-probe", "grok", "kimi-api",
            "kimi-cookie", "kimi-token-store", "kimi-web", "kiro", "longcat-api", "longcat-cookie", "longcat-web",
            "manus-api", "manus-cookie", "manus-web", "minimax-api-token-store", "minimax-cookie",
            "minimax-cookie-store", "minimax-usage", "minimax-web", "mimo-cookie", "moonshot-usage",
            "neuralwatt-usage", "notion", "openai-web", "openai-webview", "ollama", "opencode-usage",
            "opencode-go-usage", "openrouter-usage", "perplexity-api", "perplexity-cookie", "perplexity-web",
            "poe-usage", "qoder-cookie", "qoder-usage", "synthetic-token-store", "synthetic-usage", "t3chat",
            "venice-usage", "vertexai-fetcher", "warp-usage", "zed", "zai-settings", "zai-token-store", "zai-usage",
            "stepfun-usage", "zoommate",
        ])
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
