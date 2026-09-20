import CodexBarCore
import Testing
@testable import CodexBar

@MainActor
struct MergedIconPresentationTests {
    @Test
    func `automatic follows display order while reserving explicit bottom`() {
        let automatic = Self.presentation(providers: [.claude, .codex, .cursor])
        #expect(automatic.stackedProviders?.providers == [.claude, .codex])
        let bottom = Self.presentation(providers: [.claude, .codex, .cursor], bottom: .claude)
        #expect(bottom.topSelection == nil)
        #expect(bottom.bottomSelection == .claude)
        #expect(bottom.stackedProviders?.providers == [.codex, .claude])
    }

    @Test
    func `duplicate and unavailable preferences project to the same fallback as the pickers`() {
        let duplicate = Self.presentation(top: .codex, bottom: .codex)
        #expect(duplicate.topSelection == .codex)
        #expect(duplicate.bottomSelection == nil)
        #expect(duplicate.stackedProviders?.providers == [.codex, .claude])
        let unavailable = Self.presentation(top: .cursor, bottom: .gemini)
        #expect(unavailable.topSelection == nil)
        #expect(unavailable.bottomSelection == nil)
        #expect(unavailable.stackedProviders?.providers == [.codex, .claude])
        let restored = Self.presentation(providers: [.codex, .claude, .cursor, .gemini], top: .cursor, bottom: .gemini)
        #expect(restored.stackedProviders?.providers == [.cursor, .gemini])
    }

    @Test
    func `stacked requires two distinct eligible providers and a compatible icon`() {
        for providers: [UsageProvider] in [[], [.codex], [.codex, .codex]] {
            let presentation = Self.presentation(providers: providers)
            #expect(!presentation.canStack)
            #expect(presentation.effectiveStyle == .switcher)
            #expect(presentation.stackedProviders == nil)
        }
        #expect(Self.presentation(mergeIcons: false).stackedProviders == nil)
        #expect(Self.presentation(iconStyle: .bars).stackedProviders == nil)
        #expect(Self.presentation(style: .switcher).stackedProviders == nil)
        #expect(Self.presentation(providers: [.huggingface, .replicate]).stackedProviders?.providers == [
            .huggingface, .replicate,
        ])
    }

    @Test
    func `stacked projection observes only the first configured line and restores original layout`() {
        let original = MenuBarLayoutResolution(
            layout: MenuBarLayout(lines: [[.icon, .resetCountdown], [.costToday, .pace(window: .weekly)]]),
            usesLegacyRendering: true)
        let active = Self.presentation()
        for provider in [UsageProvider.codex, .claude] {
            let projected = active.renderedResolution(original, for: provider)
            #expect(!projected.usesLegacyRendering)
            #expect(projected.layout.lines == [[.icon, .resetCountdown]])
            #expect(!projected.layout.flattenedTokens(conditionals: []).contains(.costToday))
        }
        #expect(active.renderedResolution(original, for: .cursor) == original)
        #expect(Self.presentation(style: .switcher).renderedResolution(original, for: .codex) == original)
    }

    @Test
    func `first line conditional retains hidden branches and predicate dependencies`() {
        let conditional = MenuBarLayoutConditional(
            clauses: [.init(
                combinator: nil,
                predicate: .init(metric: .weeklyResetsIn, comparison: .lessThan, threshold: 1))],
            thenToken: .resetCountdown,
            elseToken: .hidden)
        let original = MenuBarLayoutResolution.stored(MenuBarLayout(lines: [
            [.conditional(id: conditional.id)], [.costToday],
        ]))
        let projected = Self.presentation().renderedResolution(original, for: .claude)
        let tokens = projected.layout.flattenedTokens(conditionals: [conditional])
        #expect(tokens.contains(.resetCountdown))
        #expect(projected.layout.lines == [[.conditional(id: conditional.id)]])
        #expect(!tokens.contains(.costToday))
        #expect(projected.layout.referencedConditionalPredicates(conditionals: [conditional])
            .map(\.metric) == [.weeklyResetsIn])
    }

    private static func presentation(
        providers: [UsageProvider] = [.codex, .claude],
        top: UsageProvider? = nil,
        bottom: UsageProvider? = nil,
        mergeIcons: Bool = true,
        iconStyle: MenuBarIconStyle = .iconAndPercent,
        style: MergedIconDisplayStyle = .stacked) -> MergedIconPresentation
    {
        MergedIconPresentation(
            mergeIcons: mergeIcons,
            iconStyle: iconStyle,
            requestedStyle: style,
            eligibleProviders: providers,
            preferredTop: top,
            preferredBottom: bottom)
    }
}
