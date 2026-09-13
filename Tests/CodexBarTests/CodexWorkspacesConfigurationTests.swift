import AppKit
import CodexBarCore
import XCTest
@testable import CodexBar

@MainActor
final class CodexWorkspacesConfigurationTests: XCTestCase {
    private enum Change {
        case privacy, history, source
    }

    func test_visibleWindowUpdatesPrivacyWithoutAConfigRevision() async throws {
        try await self.checkVisibleUpdate(.privacy)
    }

    func test_visibleWindowUpdatesHistoryWithoutAConfigRevision() async throws {
        try await self.checkVisibleUpdate(.history)
    }

    func test_visibleWindowUpdatesTheSelectedSource() async throws {
        try await self.checkVisibleUpdate(.source)
    }

    func test_closeCancelsAnActiveRequestAndReopenLoadsAgain() async throws {
        let application = NSApplication.shared
        let previousApplication = NSWorkspace.shared.frontmostApplication
        let previousPolicy = application.activationPolicy()
        let fixture = try CodexWorkspacesNavigationFixture()
        let gate = AsyncStream<Void>.makeStream()
        let started = LockIsolated(false)
        let cancellations = LockIsolated<[Bool]>([])
        let model = CodexWorkspacesInspectorModel(
            configuration: fixture.inspectorConfiguration,
            cachedSnapshotLoader: { _ in nil },
            snapshotLoader: { configuration, _, _ in
                started.setValue(true)
                for await _ in gate.stream {}
                cancellations.setValue(cancellations.value + [Task.isCancelled])
                return CodexWorkspacesInspectorProofFixture.snapshot(for: configuration)
            })
        let controller = CodexWorkspacesWindowController(
            store: fixture.store, settings: fixture.settings, model: model)
        let window = try XCTUnwrap(controller.window)
        defer {
            gate.continuation.finish()
            model.cancelLoading()
            window.close()
            fixture.cleanup()
            _ = application.setActivationPolicy(previousPolicy)
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier {
                previousApplication?.activate()
            }
        }
        _ = application.setActivationPolicy(.regular)
        controller.present()
        try await self.waitUntil("Active window request") { started.value && window.isVisible }
        window.performClose(nil)
        XCTAssertFalse(window.isVisible)
        try await self.waitUntil("Closed window cancellation") { cancellations.value == [true] && !model.isLoading }
        XCTAssertNil(model.snapshot)

        gate.continuation.finish()
        controller.present()
        try await self.waitUntil("Reopened window load") { model.snapshot != nil && !model.isLoading }
        XCTAssertEqual(cancellations.value, [true, false])
        XCTAssertTrue(controller.window === window)
        XCTAssertTrue(window.isVisible)
    }

    private func checkVisibleUpdate(_ change: Change) async throws {
        let application = NSApplication.shared
        let previousApplication = NSWorkspace.shared.frontmostApplication
        let previousPolicy = application.activationPolicy()
        let fixture = try CodexWorkspacesNavigationFixture()
        let configurations = LockIsolated<[CodexWorkspacesInspectorModel.Configuration]>([])
        let initial = fixture.inspectorConfiguration
        let initialHome = try XCTUnwrap(initial.codexHomePath)
        let model = CodexWorkspacesInspectorModel(
            configuration: initial,
            cachedSnapshotLoader: { _ in nil },
            snapshotLoader: { configuration, _, _ in
                configurations.setValue(configurations.value + [configuration])
                return CodexLocalProjectUsageSnapshot(
                    updatedAt: Date(timeIntervalSince1970: 1),
                    historyDays: configuration.historyDays,
                    scopeSignature: configuration.scopeSignature,
                    rootsFingerprint: [:],
                    indexedFileCount: 0,
                    skippedFileCount: 0,
                    total: .empty,
                    projects: [],
                    sessions: [],
                    daily: [])
            })
        let controller = CodexWorkspacesWindowController(
            store: fixture.store, settings: fixture.settings, model: model)
        defer {
            controller.window?.close()
            model.cancelLoading()
            fixture.cleanup()
            _ = application.setActivationPolicy(previousPolicy)
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier {
                previousApplication?.activate()
            }
        }
        _ = application.setActivationPolicy(.regular)
        controller.present()
        let window: NSWindow = try XCTUnwrap(controller.window)
        try await self.waitUntil("Initial visible load") {
            configurations.value == [initial] && !model.isLoading && window.isVisible
        }
        XCTAssertTrue(window.isVisible)
        let revision = fixture.settings.configRevision

        switch change {
        case .privacy:
            fixture.settings.hidePersonalInfo.toggle()
            XCTAssertEqual(fixture.settings.configRevision, revision)
        case .history:
            fixture.settings.costUsageHistoryDays = initial.historyDays == 7 ? 30 : 7
            XCTAssertEqual(fixture.settings.configRevision, revision)
        case .source:
            let path = fixture.files.root.appendingPathComponent("second-profile").path
            fixture.settings.updateProviderConfig(provider: .codex) {
                $0.codexProfileHomePaths = [initialHome, path]
                $0.codexActiveSource = .profileHome(path: path)
            }
        }

        let expected = fixture.inspectorConfiguration
        XCTAssertNotEqual(initial, expected)
        try await self.waitUntil("Changed configuration") {
            configurations.value.last == expected && !model.isLoading
        }
        XCTAssertEqual(configurations.value, [initial, expected])
        XCTAssertEqual(model.snapshot?.historyDays, expected.historyDays)
        XCTAssertEqual(model.snapshot?.scopeSignature, expected.scopeSignature)
        XCTAssertEqual(model.hidesPersonalInfo, expected.hidePersonalInfo)
        XCTAssertTrue(controller.window === window)
        XCTAssertTrue(window.isVisible)
    }

    private func waitUntil(_ phase: String, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !condition(), Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        guard condition() else {
            throw NSError(domain: "CodexWorkspacesConfigurationTests", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "\(phase) did not complete in the visible inspector.",
            ])
        }
    }
}
