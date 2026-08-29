import AppKit
import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
@Suite(.serialized)
struct CodexWorkspacesNavigationTests {
    @Test
    func `menu availability is opt in for debug and unavailable in release`() {
        #expect(!CodexWorkspacesMenuAvailability.isEnabled(environment: [:]))

        #if DEBUG
        #expect(CodexWorkspacesMenuAvailability.isEnabled(environment: [
            CodexWorkspacesMenuAvailability.environmentKey: "1",
        ]))
        #expect(!CodexWorkspacesMenuAvailability.isEnabled(environment: [
            CodexWorkspacesMenuAvailability.environmentKey: "true",
        ]))
        #else
        #expect(!CodexWorkspacesMenuAvailability.isEnabled(environment: [
            CodexWorkspacesMenuAvailability.environmentKey: "1",
        ]))
        #endif
    }

    @Test
    func `workspaces action is Codex only and requires an explicit descriptor opt in`() {
        let settings = self.makeSettings()
        settings.costUsageEnabled = false
        let store = self.makeStore(settings: settings)

        let defaultCodex = self.makeDescriptor(provider: .codex, store: store, settings: settings)
        #expect(self.workspacesActions(in: defaultCodex).isEmpty)

        let enabledCodex = self.makeDescriptor(
            provider: .codex,
            store: store,
            settings: settings,
            codexWorkspacesMenuEnabled: true)
        #expect(self.workspacesActions(in: enabledCodex) == [L("Workspaces")])

        let enabledClaude = self.makeDescriptor(
            provider: .claude,
            store: store,
            settings: settings,
            codexWorkspacesMenuEnabled: true)
        #expect(self.workspacesActions(in: enabledClaude).isEmpty)

        let overview = MenuDescriptor.build(
            provider: nil,
            store: store,
            settings: settings,
            account: AccountInfo(email: nil, plan: nil),
            updateReady: false,
            includeContextualActions: false,
            codexWorkspacesMenuEnabled: true)
        #expect(self.workspacesActions(in: overview).isEmpty)
    }

    @Test
    func `native Workspaces action remains view free and has a stable identity`() throws {
        let settings = self.makeSettings()
        let store = self.makeStore(settings: settings)
        let controller = self.makeController(settings: settings, store: store)
        defer { controller.releaseStatusItemsForTesting() }

        let descriptor = controller.makeMenuDescriptor(
            provider: .codex,
            includeContextualActions: true,
            codexWorkspacesMenuEnabled: true)
        let menu = NSMenu()
        controller.addActionableSections(descriptor.sections, to: menu, width: 320)

        let item = try #require(menu.items.first { $0.title == L("Workspaces") })
        #expect(item.view == nil)
        #expect(item.submenu == nil)
        #expect(item.image != nil)
        #expect(item.action == #selector(controller.openCodexWorkspaces(_:)))
        #expect(item.target === controller)
        #expect(item.representedObject as? String == CodexWorkspacesWindowIdentity.menuItem)

        menu.removeAllItems()
        controller.addActionableSections(descriptor.sections, to: menu, width: 320)
        #expect(menu.items.count(where: { $0.title == L("Workspaces") }) == 1)
    }

    @Test
    func `Workspaces presenter reuses a stable native window shell`() throws {
        _ = NSApplication.shared
        let presenter = CodexWorkspacesPresenter()
        let first = presenter.windowControllerForPresentation()
        let second = presenter.windowControllerForPresentation()
        let window = try #require(first.window)

        #expect(first === second)
        #expect(window.identifier?.rawValue == CodexWorkspacesWindowIdentity.window)
        #expect(window.title == L("Workspaces"))
        #expect(window.styleMask.contains(.titled))
        #expect(window.styleMask.contains(.closable))
        #expect(window.styleMask.contains(.miniaturizable))
        #expect(window.styleMask.contains(.resizable))
        #expect(window.minSize == NSSize(width: 980, height: 640))
        #expect(window.tabbingMode == .disallowed)
        #expect(!window.isReleasedWhenClosed)
        #expect(!window.isRestorable)
        #expect(window.contentViewController != nil)
    }

    private func makeSettings() -> SettingsStore {
        let settings = testSettingsStore(suiteName: "CodexWorkspacesNavigationTests")
        settings.statusChecksEnabled = false
        return settings
    }

    private func makeStore(settings: SettingsStore) -> UsageStore {
        let environment = Self.isolatedEnvironment()
        return UsageStore(
            fetcher: UsageFetcher(environment: environment),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing,
            environmentBase: environment)
    }

    private func makeController(settings: SettingsStore, store: UsageStore) -> StatusItemController {
        StatusItemController(
            store: store,
            settings: settings,
            account: AccountInfo(email: nil, plan: nil),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: .system)
    }

    private func makeDescriptor(
        provider: UsageProvider,
        store: UsageStore,
        settings: SettingsStore,
        codexWorkspacesMenuEnabled: Bool = false) -> MenuDescriptor
    {
        MenuDescriptor.build(
            provider: provider,
            store: store,
            settings: settings,
            account: AccountInfo(email: nil, plan: nil),
            updateReady: false,
            codexWorkspacesMenuEnabled: codexWorkspacesMenuEnabled)
    }

    private func workspacesActions(in descriptor: MenuDescriptor) -> [String] {
        descriptor.sections.flatMap(\.entries).compactMap { entry in
            guard case let .action(title, .openCodexWorkspaces) = entry else { return nil }
            return title
        }
    }

    private static func isolatedEnvironment() -> [String: String] {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codexbar-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        return [
            "HOME": root.path,
            "CODEX_HOME": root.appendingPathComponent(".codex", isDirectory: true).path,
            "XDG_CONFIG_HOME": root.appendingPathComponent(".config", isDirectory: true).path,
        ]
    }
}
