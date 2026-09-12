import AppKit
import SwiftUI
import XCTest
@testable import CodexBar
@testable import CodexBarCore

/// Opt-in interactive proof using synthetic hosts and the production settings/menu views.
@MainActor
final class AgentSessionVisibilityNativeProofTests: XCTestCase {
    func test_visibilityToggleInSignedHost() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["CODEXBAR_HOST_VISIBILITY_PROOF_DIR"] else {
            throw XCTSkip("Set CODEXBAR_HOST_VISIBILITY_PROOF_DIR for signed native proof")
        }
        guard SettingsStore.isRunningTests,
              env["CODEXBAR_SUPPRESS_TEST_KEYCHAIN_ACCESS"] == "1",
              env[CodexCredentialFileAccess.isolationEnvironmentKey] == "1",
              env["CODEXBAR_TEST_SESSION_FILE_ISOLATION"] == "1",
              env["CODEXBAR_ALLOW_TEST_KEYCHAIN_ACCESS"] != "1"
        else { return XCTFail("Use a credential-isolated test host") }
        let output = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let defaults = InMemoryUserDefaults()
        let settings = testSettingsStore(
            suiteName: "HostVisibilityProof", userDefaults: defaults, config: testConfigWithAllProvidersDisabled())
        settings.agentSessionsEnabled = true
        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing,
            environmentBase: [:])
        let sessions = AgentSessionsStore(
            settings: settings,
            localScan: { _ in [] },
            remoteHostDiscovery: { ["ready.example.invalid", "offline.example.invalid"] },
            remoteFetch: { _ in
                [
                    .init(host: "ready.example.invalid", sessions: [], error: nil),
                    .init(host: "offline.example.invalid", sessions: [], error: "Synthetic SSH failure"),
                ]
            })
        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: AccountInfo(email: nil, plan: nil),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            agentSessions: sessions)
        defer {
            sessions.stop()
            controller.releaseStatusItemsForTesting()
            settings.configFileWatcher?.stop()
        }
        let app = NSApplication.shared
        guard app.delegate == nil else { return XCTFail("Use a standalone test host") }
        let previousApp = NSWorkspace.shared.frontmostApplication
        let previousPolicy = app.activationPolicy()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 660, height: 450),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false)
        window.title = "CodexBar — Synthetic Host Visibility"
        window.isReleasedWhenClosed = false
        let menu = NSMenu()
        let delegate = HostMenuDelegate(settings: settings, controller: controller)
        menu.delegate = delegate
        let button = NSPopUpButton(frame: .zero, pullsDown: true)
        button.menu = menu
        let form = NSHostingView(rootView: Form {
            AgentSessionsSettingsSection(settings: settings)
        }.formStyle(.grouped))
        let stack = NSStackView(views: [button, form])
        stack.orientation = .vertical
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 16, bottom: 20, right: 16)
        form.widthAnchor.constraint(equalToConstant: 620).isActive = true
        form.heightAnchor.constraint(equalToConstant: 350).isActive = true
        button.widthAnchor.constraint(equalToConstant: 260).isActive = true
        window.contentView = stack
        defer {
            menu.cancelTracking()
            window.close()
            _ = app.setActivationPolicy(previousPolicy)
            previousApp?.activate()
        }
        _ = app.setActivationPolicy(.regular)
        app.finishLaunching()
        window.center()
        window.makeKeyAndOrderFront(nil)
        app.activate(ignoringOtherApps: true)
        sessions.start()
        try await self.waitUntil { sessions.remoteHosts.count == 2 }
        delegate.menuNeedsUpdate(menu)
        try self.receipt("visible", window: window, output: output)
        try await self.waitUntil { settings.agentSessionsHideUnreachableHosts }
        delegate.menuNeedsUpdate(menu)
        XCTAssertFalse(menu.items.contains { $0.title.contains("offline.example.invalid") })
        XCTAssertTrue(menu.items.contains { $0.toolTip == "ready.example.invalid — 0" })
        XCTAssertTrue(defaults.bool(forKey: "agentSessionsHideUnreachableHosts"))
        try self.receipt("hidden", window: window, output: output)
        try await self.waitUntil { !settings.agentSessionsHideUnreachableHosts }
        delegate.menuNeedsUpdate(menu)
        XCTAssertTrue(menu.items.contains { $0.title.contains("offline.example.invalid") })
        XCTAssertFalse(defaults.bool(forKey: "agentSessionsHideUnreachableHosts"))
        try self.receipt("restored", window: window, output: output)
        try await self.waitUntil { FileManager.default.fileExists(atPath: output.appendingPathComponent("done").path) }
        withExtendedLifetime(delegate) {}
    }

    private func receipt(_ phase: String, window: NSWindow, output: URL) throws {
        let record: [String: Any] = [
            "phase": phase, "pid": ProcessInfo.processInfo.processIdentifier, "window": window.windowNumber,
        ]
        try JSONSerialization.data(withJSONObject: record).write(
            to: output.appendingPathComponent("\(phase).json"), options: .atomic)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(180)
        while !condition(), Date() < deadline {
            if let event = NSApplication.shared.nextEvent(
                matching: .any, until: Date().addingTimeInterval(0.02), inMode: .default, dequeue: true)
            {
                NSApplication.shared.sendEvent(event)
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        if !condition() { throw NSError(domain: "HostVisibilityProof", code: 1) }
    }
}

@MainActor
private final class HostMenuDelegate: NSObject, NSMenuDelegate {
    let settings: SettingsStore
    let controller: StatusItemController

    init(settings: SettingsStore, controller: StatusItemController) {
        self.settings = settings
        self.controller = controller
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.addItem(withTitle: "Agent sessions menu", action: nil, keyEquivalent: "")
        let descriptor = self.controller.makeMenuDescriptor(provider: .codex, includeContextualActions: false)
        let sections = descriptor.sections.filter { section in
            section.entries.contains { entry in
                guard case let .text(title, .headline) = entry else { return false }
                return title.hasPrefix("Agent Sessions (")
            }
        }
        self.controller.addActionableSections(sections, to: menu, width: 320, provider: .codex)
    }
}
