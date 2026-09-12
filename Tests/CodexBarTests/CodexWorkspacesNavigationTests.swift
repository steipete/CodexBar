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
    func `workspaces action is Codex only and requires an explicit descriptor opt in`() throws {
        let fixture = try CodexWorkspacesNavigationFixture()
        defer { fixture.cleanup() }
        let settings = fixture.settings
        let store = fixture.store

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
        let fixture = try CodexWorkspacesNavigationFixture()
        let controller = fixture.makeController()
        defer {
            controller.releaseStatusItemsForTesting()
            fixture.cleanup()
        }

        let descriptor = controller.makeMenuDescriptor(
            provider: .codex,
            includeContextualActions: true,
            codexWorkspacesMenuEnabled: true)
        let menu = NSMenu()
        controller.addActionableSections(descriptor.sections, to: menu, width: 320, provider: .codex)

        let item = try #require(menu.items.first { $0.title == L("Workspaces") })
        #expect(item.view == nil)
        #expect(item.submenu == nil)
        #expect(item.image != nil)
        #expect(item.action == #selector(controller.openCodexWorkspaces(_:)))
        #expect(item.target === controller)
        #expect(item.representedObject as? String == CodexWorkspacesWindowIdentity.menuItem)

        menu.removeAllItems()
        controller.addActionableSections(descriptor.sections, to: menu, width: 320, provider: .codex)
        #expect(menu.items.count(where: { $0.title == L("Workspaces") }) == 1)
    }

    @Test
    func `Workspaces presenter reuses a stable native window shell`() throws {
        _ = NSApplication.shared
        let fixture = try CodexWorkspacesNavigationFixture()
        let presenter = CodexWorkspacesPresenter()
        let first = presenter.windowControllerForPresentation(store: fixture.store, settings: fixture.settings)
        let second = presenter.windowControllerForPresentation(store: fixture.store, settings: fixture.settings)
        let window = try #require(first.window)
        defer {
            window.close()
            fixture.cleanup()
        }

        #expect(first === second)
        #expect(window.identifier?.rawValue == CodexWorkspacesWindowIdentity.window)
        #expect(window.title == L("Workspaces"))
        #expect(window.styleMask.contains(.titled))
        #expect(window.styleMask.contains(.closable))
        #expect(window.styleMask.contains(.miniaturizable))
        #expect(window.styleMask.contains(.resizable))
        #expect(window.contentMinSize == NSSize(width: 980, height: 640))
        #expect(window.contentView?.frame.size == NSSize(width: 1380, height: 780))
        #expect(window.tabbingMode == .disallowed)
        #expect(!window.isReleasedWhenClosed)
        #expect(!window.isRestorable)
        #expect(window.frameAutosaveName.isEmpty)
        #expect(window.contentViewController != nil)
    }

    @Test
    func `window construction defers loading and presentation starts one cache first request`() async throws {
        _ = NSApplication.shared
        let fixture = try CodexWorkspacesNavigationFixture()
        let configuration = self.inspectorConfiguration(fixture)
        let recorder = InspectorLoadRecorder()
        let refreshedSnapshot = Self.emptyInspectorSnapshot()
        let model = CodexWorkspacesInspectorModel(
            configuration: configuration,
            cachedSnapshotLoader: { requestedConfiguration in
                await recorder.recordCached(requestedConfiguration)
                return nil
            },
            snapshotLoader: { requestedConfiguration, forceRefresh, progress in
                await recorder.recordNormal(requestedConfiguration, forceRefresh: forceRefresh)
                progress(CodexLocalProjectUsageIndexProgress(phase: .indexingProjects))
                return refreshedSnapshot
            })
        let windowController = CodexWorkspacesWindowController(
            store: fixture.store,
            settings: fixture.settings,
            model: model)
        defer {
            windowController.window?.close()
            fixture.cleanup()
        }

        #expect(await recorder.cachedConfigurations() == [])
        #expect(await recorder.normalRequests() == [])

        windowController.present()
        await model.waitForCurrentLoad()

        #expect(await recorder.cachedConfigurations() == [configuration])
        #expect(await recorder.normalRequests() == [InspectorLoadRecorder.NormalRequest(
            configuration: configuration,
            forceRefresh: false)])
        #expect(model.snapshot == refreshedSnapshot)
        #expect(!model.isLoading)

        let window = try #require(windowController.window)
        window.performClose(nil)
        #expect(!window.isVisible)
        windowController.present()
        #expect(windowController.window === window)
        #expect(window.isVisible)
        #expect(await recorder.cachedConfigurations() == [configuration])
        #expect(await recorder.normalRequests() == [InspectorLoadRecorder.NormalRequest(
            configuration: configuration,
            forceRefresh: false)])
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

    private func inspectorConfiguration(
        _ fixture: CodexWorkspacesNavigationFixture) -> CodexWorkspacesInspectorModel.Configuration
    {
        let scope = fixture.store.tokenCostScope(for: .codex)
        return CodexWorkspacesInspectorModel.Configuration(
            codexHomePath: scope.codexHomePath,
            scopeSignature: scope.signature,
            historyDays: fixture.settings.costUsageHistoryDays,
            hidePersonalInfo: fixture.settings.hidePersonalInfo)
    }

    private static func emptyInspectorSnapshot() -> CodexLocalProjectUsageSnapshot {
        CodexLocalProjectUsageSnapshot(
            updatedAt: Date(timeIntervalSince1970: 1),
            historyDays: 30,
            scopeSignature: "test-scope",
            rootsFingerprint: [:],
            indexedFileCount: 0,
            skippedFileCount: 0,
            total: .empty,
            projects: [],
            sessions: [],
            daily: [])
    }
}

private actor InspectorLoadRecorder {
    struct NormalRequest: Sendable, Equatable {
        let configuration: CodexWorkspacesInspectorModel.Configuration
        let forceRefresh: Bool
    }

    private var cachedRequests: [CodexWorkspacesInspectorModel.Configuration] = []
    private var normalLoadRequests: [NormalRequest] = []

    func recordCached(_ configuration: CodexWorkspacesInspectorModel.Configuration) {
        self.cachedRequests.append(configuration)
    }

    func recordNormal(_ configuration: CodexWorkspacesInspectorModel.Configuration, forceRefresh: Bool) {
        self.normalLoadRequests.append(NormalRequest(configuration: configuration, forceRefresh: forceRefresh))
    }

    func cachedConfigurations() -> [CodexWorkspacesInspectorModel.Configuration] {
        self.cachedRequests
    }

    func normalRequests() -> [NormalRequest] {
        self.normalLoadRequests
    }
}
