import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@Suite(.serialized)
@MainActor
struct SettingsStoreMergeIconStackedTests {
    @Test
    func `merged icon display style toggles between switcher and stacked`() {
        let store = testSettingsStore(suiteName: "SettingsStoreMergeIconStackedTests-style-toggle")

        #expect(store.mergedIconDisplayStyle == .switcher)
        store.mergedIconDisplayStyle = .stacked
        #expect(store.mergeIconsStacked)
        #expect(store.mergedIconDisplayStyle == .stacked)
        store.mergedIconDisplayStyle = .switcher
        #expect(!store.mergeIconsStacked)
    }

    @Test
    func `activating stored layout for stacked rendering migrates only that provider`() {
        let store = testSettingsStore(suiteName: "SettingsStoreMergeIconStackedTests-activate-per-provider")

        #expect(!store.hasStoredMenuBarLayout)
        #expect(store.menuBarLayoutOverrides[.claude] == nil)

        store.activateStoredLayoutForStackedRenderingIfNeeded(provider: .claude)

        #expect(!store.hasStoredMenuBarLayout)
        #expect(store.menuBarLayoutOverrides[.claude] != nil)
        #expect(!store.menuBarLayoutResolution(for: .claude).usesLegacyRendering)
        // A different, unrelated provider is left untouched.
        #expect(store.menuBarLayoutOverrides[.codex] == nil)
    }

    @Test
    func `activating stored layout preserves the provider's pre-activation effective layout`() {
        let store = testSettingsStore(suiteName: "SettingsStoreMergeIconStackedTests-preserve-effective")
        let beforeLayout = store.menuBarLayoutResolution(for: .claude).layout

        store.activateStoredLayoutForStackedRenderingIfNeeded(provider: .claude)

        let afterResolution = store.menuBarLayoutResolution(for: .claude)
        #expect(afterResolution.layout == beforeLayout)
        #expect(!afterResolution.usesLegacyRendering)
    }

    @Test
    func `activating stored layout is a no-op once a layout is already stored`() {
        let store = testSettingsStore(suiteName: "SettingsStoreMergeIconStackedTests-activate-noop")
        let customLayout = MenuBarLayout(lines: [[.icon, .providerName]])
        store.menuBarLayout = customLayout

        store.activateStoredLayoutForStackedRenderingIfNeeded(provider: .claude)

        #expect(store.menuBarLayoutOverrides[.claude] == nil)
        #expect(store.menuBarLayout == customLayout)
    }

    @Test
    func `resolved merge icon stacked providers reserves an explicit bottom pick before automatic top`() {
        let store = testSettingsStore(suiteName: "SettingsStoreMergeIconStackedTests-reserve-bottom")

        // Top is left on Automatic; only the bottom row has an explicit pick.
        store.mergeIconStackedBottomProvider = .codex
        let resolved = store.resolvedMergeIconStackedProviders(activeProviders: [.codex, .claude])

        #expect(resolved?.top == .claude)
        #expect(resolved?.bottom == .codex)
    }

    @Test
    func `resolved merge icon stacked providers defaults to first two active providers`() {
        let store = testSettingsStore(suiteName: "SettingsStoreMergeIconStackedTests-default")

        let resolved = store.resolvedMergeIconStackedProviders(activeProviders: [.codex, .claude, .cursor])

        #expect(resolved?.top == .codex)
        #expect(resolved?.bottom == .claude)
    }

    @Test
    func `resolved merge icon stacked providers is nil with fewer than two active providers`() {
        let store = testSettingsStore(suiteName: "SettingsStoreMergeIconStackedTests-insufficient")

        #expect(store.resolvedMergeIconStackedProviders(activeProviders: [.codex]) == nil)
        #expect(store.resolvedMergeIconStackedProviders(activeProviders: []) == nil)
    }

    @Test
    func `resolved merge icon stacked providers honors explicit top and bottom pick`() {
        let store = testSettingsStore(suiteName: "SettingsStoreMergeIconStackedTests-explicit")

        store.mergeIconStackedTopProvider = .cursor
        store.mergeIconStackedBottomProvider = .codex
        let resolved = store.resolvedMergeIconStackedProviders(activeProviders: [.codex, .claude, .cursor])

        #expect(resolved?.top == .cursor)
        #expect(resolved?.bottom == .codex)
    }

    @Test
    func `resolved merge icon stacked providers falls back when explicit pick is no longer active`() {
        let store = testSettingsStore(suiteName: "SettingsStoreMergeIconStackedTests-fallback")

        store.mergeIconStackedTopProvider = .cursor
        store.mergeIconStackedBottomProvider = .gemini
        let resolved = store.resolvedMergeIconStackedProviders(activeProviders: [.codex, .claude])

        #expect(resolved?.top == .codex)
        #expect(resolved?.bottom == .claude)
    }

    @Test
    func `resolved merge icon stacked providers never picks the same provider twice`() {
        let store = testSettingsStore(suiteName: "SettingsStoreMergeIconStackedTests-no-duplicate")

        store.mergeIconStackedTopProvider = .codex
        store.mergeIconStackedBottomProvider = .codex
        let resolved = store.resolvedMergeIconStackedProviders(activeProviders: [.codex, .claude])

        #expect(resolved?.top == .codex)
        #expect(resolved?.bottom == .claude)
    }
}
