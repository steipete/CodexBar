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
    func `selecting stacked style activates a stored layout when none exists`() {
        let store = testSettingsStore(suiteName: "SettingsStoreMergeIconStackedTests-activates-layout")

        #expect(!store.hasStoredMenuBarLayout)
        store.mergedIconDisplayStyle = .stacked
        #expect(store.hasStoredMenuBarLayout)
    }

    @Test
    func `selecting stacked style does not overwrite an existing stored layout`() {
        let store = testSettingsStore(suiteName: "SettingsStoreMergeIconStackedTests-preserves-layout")
        let customLayout = MenuBarLayout(lines: [[.icon, .providerName]])
        store.menuBarLayout = customLayout

        store.mergedIconDisplayStyle = .stacked

        #expect(store.menuBarLayout == customLayout)
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
