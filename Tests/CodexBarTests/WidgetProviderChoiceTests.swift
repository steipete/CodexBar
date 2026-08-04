import Testing
@testable import CodexBarCore

/// The widget's ProviderChoice AppEnum must keep a literal caseDisplayRepresentations
/// dictionary (AppIntents extracts it statically). This pins the literal titles to the
/// descriptor registry so new or renamed providers fail here instead of drifting.
struct WidgetProviderChoiceTests {
    private static let literalTitles: [String: String] = [
        "codex": "Codex",
        "claude": "Claude",
        "gemini": "Gemini",
        "alibaba": "Alibaba",
        "alibabatokenplan": "Alibaba Token Plan",
        "qwencloud": "Qwen Cloud",
        "antigravity": "Antigravity",
        "cursor": "Cursor",
        "zai": "z.ai / GLM",
        "copilot": "Copilot",
        "devin": "Devin",
        "minimax": "MiniMax",
        "kilo": "Kilo",
        "opencode": "OpenCode",
        "opencodego": "OpenCode Go",
        "mistral": "Mistral",
        "kimi": "Kimi Code",
    ]

    @Test
    func `widget literal titles match descriptor registry display names`() throws {
        for (raw, title) in Self.literalTitles {
            let provider = try #require(UsageProvider(rawValue: raw))
            let registryName = ProviderDescriptorRegistry.descriptor(for: provider).metadata.displayName
            #expect(
                registryName == title,
                "Widget literal for \(raw) is \"\(title)\" but registry says \"\(registryName)\"")
        }
    }

    @Test
    func `widget literal covers every widget-selectable provider`() {
        let selectable = UsageProvider.allCases
            .filter { ProviderDescriptorRegistry.descriptor(for: $0).metadata.widgetSelectable }
            .map(\.rawValue)
        for raw in selectable {
            #expect(
                Self.literalTitles[raw] != nil,
                "Provider \(raw) is widgetSelectable but missing from the widget literal")
        }
    }
}
