import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

// MARK: - PopoverActionSectionsView shortcutLabel 映射测试

struct PopoverActionSectionsViewTests {
    @Test
    func `shortcutLabel returns command-R for refresh`() {
        #expect(PopoverActionSectionsView.shortcutLabel(for: .refresh) == "⌘R")
    }

    @Test
    func `shortcutLabel returns command-comma for settings`() {
        #expect(PopoverActionSectionsView.shortcutLabel(for: .settings) == "⌘,")
    }

    @Test
    func `shortcutLabel returns command-Q for quit`() {
        #expect(PopoverActionSectionsView.shortcutLabel(for: .quit) == "⌘Q")
    }

    @Test
    func `shortcutLabel returns nil for dashboard`() {
        #expect(PopoverActionSectionsView.shortcutLabel(for: .dashboard) == nil)
    }

    @Test
    func `shortcutLabel returns nil for about`() {
        #expect(PopoverActionSectionsView.shortcutLabel(for: .about) == nil)
    }

    @Test
    func `shortcutLabel returns nil for installUpdate`() {
        #expect(PopoverActionSectionsView.shortcutLabel(for: .installUpdate) == nil)
    }

    @MainActor
    @Test
    func refreshKeepsPopoverOpen() {
        #expect(StatusItemController.shouldClosePopover(after: .refresh) == false)
    }

    @MainActor
    @Test
    func navigationActionClosesPopover() {
        #expect(StatusItemController.shouldClosePopover(after: .settings) == true)
    }
}

// MARK: - MenuDescriptor.build 底部 metaSection 契约测试

@MainActor
struct PopoverActionSectionsDescriptorTests {
    /// metaSection 必须包含 refresh/settings/quit 动作，popover 才能正确渲染底部动作区。
    @Test
    func `metaSection contains refresh settings and quit actions`() throws {
        let suite = "PopoverActionDispatchTests-meta"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)

        let settings = SettingsStore(
            userDefaults: defaults,
            configStore: testConfigStore(suiteName: suite),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
        settings.statusChecksEnabled = false

        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings)

        let descriptor = MenuDescriptor.build(
            provider: .codex,
            store: store,
            settings: settings,
            account: AccountInfo(email: nil, plan: nil),
            updateReady: false,
            includeContextualActions: false)

        let allActions = descriptor.sections.flatMap(\.entries).compactMap { entry -> MenuDescriptor.MenuAction? in
            guard case let .action(_, action) = entry else { return nil }
            return action
        }

        #expect(allActions.contains(.refresh), "metaSection should include .refresh action")
        #expect(allActions.contains(.settings), "metaSection should include .settings action")
        #expect(allActions.contains(.quit), "metaSection should include .quit action")
    }

    /// updateReady=true 时 metaSection 包含 installUpdate 动作。
    @Test
    func `metaSection contains installUpdate when update is ready`() throws {
        let suite = "PopoverActionDispatchTests-update"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)

        let settings = SettingsStore(
            userDefaults: defaults,
            configStore: testConfigStore(suiteName: suite),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
        settings.statusChecksEnabled = false

        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings)

        let descriptor = MenuDescriptor.build(
            provider: .codex,
            store: store,
            settings: settings,
            account: AccountInfo(email: nil, plan: nil),
            updateReady: true,
            includeContextualActions: false)

        let allActions = descriptor.sections.flatMap(\.entries).compactMap { entry -> MenuDescriptor.MenuAction? in
            guard case let .action(_, action) = entry else { return nil }
            return action
        }

        #expect(allActions.contains(.installUpdate), "metaSection should include .installUpdate when updateReady=true")
    }
}
