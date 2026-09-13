import AppKit
import CodexBarCore
import Foundation
import XCTest
@testable import CodexBar

/// Opt-in interactive proof in a signed XCTest host, never normal CodexBar startup.
@MainActor
final class CodexWorkspacesNativeProofTests: XCTestCase {
    func test_nativeMenuAndWindowLifecycle() throws {
        let directory = try self.proofDirectory(environmentKey: "CODEXBAR_WORKSPACES_PROOF_DIR")
        let application = NSApplication.shared
        let previousPolicy = application.activationPolicy()
        let previousApplication = NSWorkspace.shared.frontmostApplication
        let fixture = try CodexWorkspacesNavigationFixture()
        let controller = fixture.makeController()
        let host = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 180),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false)
        host.title = "CodexBar Workspaces Proof"
        host.isReleasedWhenClosed = false
        host.center()
        let gateEnabled = CodexWorkspacesMenuAvailability.isEnabledForCurrentProcess
        let menu = NSMenu()
        let descriptor = controller.makeMenuDescriptor(provider: .codex, includeContextualActions: true)
        controller.addActionableSections(descriptor.sections, to: menu, width: 320, provider: .codex)
        let workspacesIndex = menu.items.firstIndex { $0.title == L("Workspaces") }
        XCTAssertEqual(workspacesIndex != nil, gateEnabled)

        let button = NSPopUpButton(frame: NSRect(x: 120, y: 72, width: 180, height: 32), pullsDown: true)
        menu.insertItem(withTitle: "Codex menu", action: nil, keyEquivalent: "", at: 0)
        button.menu = menu
        host.contentView?.addSubview(button)
        defer {
            menu.cancelTracking()
            for window in self.workspaceWindows() {
                window.close()
            }
            host.close()
            controller.releaseStatusItemsForTesting()
            fixture.cleanup()
            _ = application.setActivationPolicy(previousPolicy)
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier {
                previousApplication?.activate()
            }
        }

        XCTAssertTrue(application.setActivationPolicy(.regular))
        application.finishLaunching()
        application.activate()
        host.makeKeyAndOrderFront(nil)
        try self.waitUntil { host.isVisible && host.isKeyWindow }
        try self.receipt("menu", window: host, gateEnabled: gateEnabled, directory: directory)
        if !gateEnabled {
            try self.waitUntil { self.hasAcknowledgement("menu", directory: directory) }
            XCTAssertTrue(self.workspaceWindows().isEmpty)
            return
        }

        // The external UI driver selects the production NSMenuItem, not a substitute test action.
        try self.waitUntil { self.workspaceWindows().contains(where: { $0.isVisible && $0.isKeyWindow }) }
        let window = try XCTUnwrap(self.workspaceWindows().first)
        XCTAssertEqual(window.title, L("Workspaces"))
        XCTAssertEqual(window.contentMinSize, NSSize(width: 980, height: 640))
        XCTAssertEqual(window.contentView?.frame.size, NSSize(width: 1380, height: 780))
        XCTAssertEqual(self.workspaceWindows().count, 1)
        try self.receipt("presented", window: window, gateEnabled: gateEnabled, directory: directory)
        try self.waitUntil { self.hasAcknowledgement("presented", directory: directory) }

        let index = try XCTUnwrap(menu.items.firstIndex { $0.title == L("Workspaces") })
        menu.performActionForItem(at: index)
        try self.waitUntil { window.isVisible && window.isKeyWindow }
        XCTAssertEqual(self.workspaceWindows().count, 1)
        XCTAssertTrue(self.workspaceWindows().first === window)
        window.performClose(nil)
        try self.waitUntil { !window.isVisible }
        menu.performActionForItem(at: index)
        try self.waitUntil { window.isVisible && window.isKeyWindow }
        XCTAssertTrue(self.workspaceWindows().first === window)

        window.miniaturize(nil)
        try self.waitUntil { window.isMiniaturized }
        menu.performActionForItem(at: index)
        try self.waitUntil { !window.isMiniaturized && window.isVisible && window.isKeyWindow }
        XCTAssertEqual(self.workspaceWindows().count, 1)
        XCTAssertTrue(self.workspaceWindows().first === window)
        XCTAssertEqual(window.contentMinSize, NSSize(width: 980, height: 640))
        try self.receipt("reopened", window: window, gateEnabled: gateEnabled, directory: directory)
        try self.waitUntil { self.hasAcknowledgement("reopened", directory: directory) }
    }

    func test_visibleInspectorConfigurationTransitions() async throws {
        let directory = try self.proofDirectory(environmentKey: "CODEXBAR_WORKSPACES_INSPECTOR_PROOF_DIR")
        let gateEnabled = CodexWorkspacesMenuAvailability.isEnabledForCurrentProcess
        guard gateEnabled else {
            XCTFail("Enable the existing debug Workspaces gate for the inspector proof.")
            return
        }
        let application = NSApplication.shared
        let previousPolicy = application.activationPolicy()
        let previousApplication = NSWorkspace.shared.frontmostApplication
        let fixture = try CodexWorkspacesNavigationFixture()
        fixture.settings.costUsageHistoryDays = 30
        fixture.settings.hidePersonalInfo = false
        let model = CodexWorkspacesInspectorModel(
            configuration: fixture.inspectorConfiguration,
            cachedSnapshotLoader: { _ in nil },
            snapshotLoader: { configuration, _, _ in
                CodexWorkspacesInspectorProofFixture.snapshot(for: configuration)
            })
        let controller = CodexWorkspacesWindowController(
            store: fixture.store, settings: fixture.settings, model: model)
        let window = try XCTUnwrap(controller.window)
        defer {
            window.close()
            model.cancelLoading()
            fixture.cleanup()
            _ = application.setActivationPolicy(previousPolicy)
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier {
                previousApplication?.activate()
            }
        }
        _ = application.setActivationPolicy(.regular)
        application.finishLaunching()
        controller.present()
        try await self.awaitCondition { window.isVisible && model.snapshot != nil && !model.isLoading }
        XCTAssertEqual(model.snapshot?.projects.count, 2)
        try self.receipt("populated", window: window, gateEnabled: gateEnabled, directory: directory)

        // The external driver selects a real sidebar row before changing settings.
        try await self.awaitCondition { model.selectedProjectID == "borealis" }
        try self.receipt("selected", window: window, gateEnabled: gateEnabled, directory: directory)
        try await self.awaitCondition { self.hasAcknowledgement("selected", directory: directory) }

        fixture.settings.hidePersonalInfo = true
        try await self.awaitCondition { model.hidesPersonalInfo && model.snapshot != nil && !model.isLoading }
        XCTAssertTrue(try XCTUnwrap(model.snapshot).projects
            .allSatisfy { $0.path == nil && $0.displayName == "Workspace" })
        try self.receipt("privacy", window: window, gateEnabled: gateEnabled, directory: directory)
        try await self.awaitCondition { self.hasAcknowledgement("privacy", directory: directory) }

        fixture.settings.costUsageHistoryDays = 7
        try await self.awaitCondition { model.snapshot?.historyDays == 7 && !model.isLoading }
        XCTAssertEqual(model.snapshot?.projects.count, 1)
        XCTAssertEqual(model.snapshot?.total.totalTokens, 1000)
        try self.receipt("history", window: window, gateEnabled: gateEnabled, directory: directory)
        try await self.awaitCondition { self.hasAcknowledgement("history", directory: directory) }

        let path = fixture.files.root.appendingPathComponent("second-profile").path
        fixture.settings.updateProviderConfig(provider: .codex) {
            $0.codexProfileHomePaths = [path]
            $0.codexActiveSource = .profileHome(path: path)
        }
        fixture.settings.hidePersonalInfo = false
        let expected = fixture.inspectorConfiguration
        try await self.awaitCondition {
            model.snapshot?.scopeSignature == expected.scopeSignature && !model.hidesPersonalInfo && !model.isLoading
        }
        XCTAssertEqual(model.snapshot?.projects.first?.id, "harbor")
        XCTAssertEqual(model.snapshot?.total.totalTokens, 2900)
        XCTAssertTrue(window.isVisible)
        try self.receipt("profile", window: window, gateEnabled: gateEnabled, directory: directory)
        try await self.awaitCondition { self.hasAcknowledgement("profile", directory: directory) }
    }

    private func proofDirectory(environmentKey: String) throws -> URL {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment[environmentKey] else {
            throw XCTSkip("Set \(environmentKey) for isolated native UI proof.")
        }
        guard SettingsStore.isRunningTests,
              environment["CODEXBAR_SUPPRESS_TEST_KEYCHAIN_ACCESS"] == "1",
              environment[CodexCredentialFileAccess.isolationEnvironmentKey] == "1",
              environment["CODEXBAR_ALLOW_TEST_KEYCHAIN_ACCESS"] != "1",
              environment["CODEXBAR_TEST_CODEX_FILE_FIXTURES"] == nil,
              NSApplication.shared.delegate == nil,
              UserDefaults.standard.object(forKey: "NSOpen") == nil
        else {
            throw NSError(domain: "CodexWorkspacesNativeProof", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "Native proof requires a standalone, credential-isolated test application.",
            ])
        }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func awaitCondition(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(180)
        while !condition(), Date() < deadline {
            while let event = NSApplication.shared.nextEvent(
                matching: .any, until: .distantPast, inMode: .default, dequeue: true)
            {
                NSApplication.shared.sendEvent(event)
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        guard condition() else {
            throw NSError(domain: "CodexWorkspacesNativeProof", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Timed out waiting for the isolated native UI proof phase.",
            ])
        }
    }

    private func workspaceWindows() -> [NSWindow] {
        NSApplication.shared.windows.filter { $0.identifier?.rawValue == CodexWorkspacesWindowIdentity.window }
    }

    private func hasAcknowledgement(_ phase: String, directory: URL) -> Bool {
        FileManager.default.fileExists(atPath: directory.appendingPathComponent("\(phase).continue").path)
    }

    private func receipt(_ phase: String, window: NSWindow, gateEnabled: Bool, directory: URL) throws {
        struct Receipt: Encodable {
            let phase: String
            let pid: Int32
            let windowNumber: Int
            let gateEnabled: Bool
        }
        let receipt = Receipt(
            phase: phase,
            pid: ProcessInfo.processInfo.processIdentifier,
            windowNumber: window.windowNumber,
            gateEnabled: gateEnabled)
        try JSONEncoder().encode(receipt).write(
            to: directory.appendingPathComponent("\(phase).json"), options: .atomic)
    }

    private func waitUntil(_ condition: () -> Bool) throws {
        let deadline = Date().addingTimeInterval(180)
        while !condition(), Date() < deadline {
            if let event = NSApplication.shared.nextEvent(
                matching: .any, until: Date().addingTimeInterval(0.02), inMode: .default, dequeue: true)
            {
                NSApplication.shared.sendEvent(event)
            }
            _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
        guard condition() else {
            throw NSError(domain: "CodexWorkspacesNativeProof", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Timed out waiting for the isolated native UI proof phase.",
            ])
        }
    }
}
