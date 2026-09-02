import AppKit
import CodexBarCore
import Foundation
import XCTest
@testable import CodexBar

/// Opt-in native menu proof with disposable settings and no provider transports.
@MainActor
final class StatusMenuProviderNativeProofTests: XCTestCase {
    func test_warmedStatusProviderMenu() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let directoryPath = environment["CODEXBAR_STATUS_PROVIDER_PROOF_DIR"] else {
            throw XCTSkip("Set CODEXBAR_STATUS_PROVIDER_PROOF_DIR for isolated native UI proof.")
        }
        guard SettingsStore.isRunningTests,
              environment["CODEXBAR_SUPPRESS_TEST_KEYCHAIN_ACCESS"] == "1",
              environment[CodexCredentialFileAccess.isolationEnvironmentKey] == "1",
              environment["CODEXBAR_TEST_SESSION_FILE_ISOLATION"] == "1",
              environment["CODEXBAR_ALLOW_TEST_KEYCHAIN_ACCESS"] != "1",
              environment["CODEXBAR_TEST_CODEX_FILE_FIXTURES"] == nil
        else {
            return XCTFail("Native proof requires credential and session isolation.")
        }
        let directory = URL(fileURLWithPath: directoryPath, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fixture = try CodexWorkspacesNavigationFixture()
        defer { fixture.cleanup() }
        let providers: [UsageProvider] = [.claude, .codex, .grok]
        for provider in providers {
            fixture.settings.setProviderEnabled(
                provider: provider,
                metadata: ProviderDescriptorRegistry.descriptor(for: provider).metadata,
                enabled: true)
            _ = fixture.settings.setMergedOverviewProviderSelection(
                provider: provider,
                isSelected: false,
                activeProviders: providers)
        }
        fixture.settings.mergeIcons = true
        fixture.settings.selectedMenuProvider = .claude
        fixture.settings.mergedMenuLastSelectedWasOverview = false
        fixture.settings.statusChecksEnabled = true
        for provider in providers {
            fixture.store._setSnapshotForTesting(
                UsageSnapshot(
                    primary: RateWindow(
                        usedPercent: 25,
                        windowMinutes: 300,
                        resetsAt: Date().addingTimeInterval(3600),
                        resetDescription: nil),
                    secondary: nil,
                    updatedAt: Date()),
                provider: provider)
        }
        fixture.store.statusComponents[.claude] = [
            ProviderStatusComponent(id: "claude", name: "Claude.ai", indicator: .none, status: "operational"),
        ]
        fixture.store.statusComponents[.codex] = [
            ProviderStatusComponent(id: "codex", name: "Codex", indicator: .none, status: "operational"),
        ]

        let oldRendering = StatusItemController.menuCardRenderingEnabled
        let oldRefresh = StatusItemController.menuRefreshEnabled
        StatusItemController.menuCardRenderingEnabled = true
        StatusItemController.setMenuRefreshEnabledForTesting(true)
        defer {
            StatusItemController.menuCardRenderingEnabled = oldRendering
            StatusItemController.setMenuRefreshEnabledForTesting(oldRefresh)
        }
        let controller = fixture.makeController()
        defer { controller.releaseStatusItemsForTesting() }
        let menu = try XCTUnwrap(controller.mergedMenu)
        let application = NSApplication.shared
        guard application.delegate == nil, UserDefaults.standard.object(forKey: "NSOpen") == nil else {
            return XCTFail("Native proof requires a standalone test application.")
        }
        let oldPolicy = application.activationPolicy()
        let previousApplication = NSWorkspace.shared.frontmostApplication
        let host = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 160),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false)
        host.title = "CodexBar Synthetic Status Proof"
        host.isReleasedWhenClosed = false
        host.center()
        let button = StatusProviderProofButton(frame: NSRect(x: 140, y: 65, width: 200, height: 32))
        button.title = "Open provider menu"
        button.proofMenu = menu
        button.target = button
        button.action = #selector(StatusProviderProofButton.openMenu)
        host.contentView?.addSubview(button)
        defer {
            menu.cancelTracking()
            host.close()
            _ = application.setActivationPolicy(oldPolicy)
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier {
                previousApplication?.activate()
            }
        }
        XCTAssertTrue(application.setActivationPolicy(.regular))
        application.finishLaunching()
        application.activate(ignoringOtherApps: true)
        host.makeKeyAndOrderFront(nil)

        // Common-mode receipts keep updating while the external driver interacts with NSMenu.
        let timer = Timer(timeInterval: 0.1, repeats: true) { _ in
            MainActor.assumeIsolated {
                guard let menu = button.proofMenu else { return }
                let statusItem = menu.items.first { $0.title == L("Status Page") }
                let submenu = statusItem?.submenu
                let receipt: [String: String] = [
                    "pid": String(ProcessInfo.processInfo.processIdentifier),
                    "window": String(host.windowNumber),
                    "selected": fixture.settings.selectedMenuProvider?.rawValue ?? "none",
                    "statusProvider": submenu?.items.first?.toolTip
                        ?? submenu?.items.last?.identifier?.rawValue ?? "website-only",
                    "cachedSelections": String(controller.mergedSwitcherContentCaches[ObjectIdentifier(menu)]?
                        .count ?? 0),
                ]
                do {
                    try JSONEncoder().encode(receipt).write(
                        to: directory.appendingPathComponent("state.json"), options: .atomic)
                } catch {
                    XCTFail("Could not write native proof receipt: \(error)")
                }
                if FileManager.default.fileExists(atPath: directory.appendingPathComponent("done").path) {
                    menu.cancelTracking()
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        defer { timer.invalidate() }
        let deadline = Date().addingTimeInterval(600)
        let done = directory.appendingPathComponent("done").path
        while !FileManager.default.fileExists(atPath: done), Date() < deadline {
            if let event = application.nextEvent(
                matching: .any, until: Date().addingTimeInterval(0.02), inMode: .default, dequeue: true)
            {
                application.sendEvent(event)
            }
            _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: done), "Native proof timed out")
    }
}

@MainActor
private final class StatusProviderProofButton: NSButton {
    var proofMenu: NSMenu?

    @objc func openMenu() {
        self.proofMenu?.popUp(positioning: nil, at: NSPoint(x: 0, y: self.bounds.maxY), in: self)
    }
}
