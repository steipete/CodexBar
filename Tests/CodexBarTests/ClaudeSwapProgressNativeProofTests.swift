import AppKit
import CodexBarCore
import Foundation
import XCTest
@testable import CodexBar

/// Opt-in, synthetic-only proof of account progress in a genuinely tracking, attached menu.
@MainActor
final class ClaudeSwapProgressNativeProofTests: XCTestCase {
    func test_accountProgressRemainsVisibleDuringNativeMenuTracking() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["CODEXBAR_CLAUDE_SWAP_PROGRESS_PROOF_DIR"] else {
            throw XCTSkip("Set CODEXBAR_CLAUDE_SWAP_PROGRESS_PROOF_DIR for synthetic native account progress proof")
        }
        guard environment["CODEXBAR_SUPPRESS_TEST_KEYCHAIN_ACCESS"] == "1",
              environment[CodexCredentialFileAccess.isolationEnvironmentKey] == "1",
              environment["CODEXBAR_TEST_SESSION_FILE_ISOLATION"] == "1",
              environment["CODEXBAR_ALLOW_TEST_KEYCHAIN_ACCESS"] != "1"
        else { return XCTFail("Native proof requires credential and session isolation") }
        let configuration = ClaudeSwapProgressNativeProofConfiguration(path: path, environment: environment)
        try FileManager.default.createDirectory(at: configuration.output, withIntermediateDirectories: true)
        let app = NSApplication.shared
        guard app.delegate == nil else { return XCTFail("Use a standalone signed test host") }
        let oldPolicy = app.activationPolicy()
        let previousApp = NSWorkspace.shared.frontmostApplication
        _ = app.setActivationPolicy(.regular)
        app.finishLaunching()
        let previousRendering = StatusItemController.menuCardRenderingEnabled
        let previousRefresh = StatusItemController.menuRefreshEnabled
        StatusItemController.menuCardRenderingEnabled = true
        StatusItemController.setMenuRefreshEnabledForTesting(true)
        defer {
            StatusItemController.menuCardRenderingEnabled = previousRendering
            StatusItemController.setMenuRefreshEnabledForTesting(previousRefresh)
            _ = app.setActivationPolicy(oldPolicy)
            previousApp?.activate()
        }
        let fixture = try ClaudeSwapProgressNativeProofFixture()
        let controller = fixture.navigation.makeController()
        defer { controller.releaseStatusItemsForTesting() }
        XCTAssertNil(controller._test_openMenuRebuildObserver)
        XCTAssertNil(controller._test_openMenuRefreshYieldOverride)
        XCTAssertNil(controller._test_providerSwitcherMenuRebuildDebounceNanoseconds)
        let menu: NSMenu
        let button: NSStatusBarButton
        do {
            menu = try XCTUnwrap(controller.mergedMenu)
            button = try XCTUnwrap(controller.statusItem.button)
        } catch {
            await fixture.drainAndCleanup()
            throw error
        }
        let driver = ClaudeSwapProgressNativeProofDriver(
            fixture: fixture, controller: controller, menu: menu, configuration: configuration)
        let timer = Timer(timeInterval: 0.1, repeats: true) { _ in
            MainActor.assumeIsolated { driver.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        defer { timer.invalidate() }
        app.activate(ignoringOtherApps: true)
        await withCheckedContinuation { continuation in
            // Enter tracking from CFRunLoop only after this async test releases the main actor.
            ProviderSwitcherTrackingRunLoopScheduler.schedule {
                button.performClick(nil)
                continuation.resume()
            }
        }
        timer.invalidate()
        driver.trackingReturned = true
        await fixture.drainTransaction()
        do {
            try driver.writeReceipt()
        } catch {
            controller.releaseStatusItemsForTesting()
            await fixture.drainAndCleanup()
            throw error
        }
        controller.releaseStatusItemsForTesting()
        await fixture.drainAndCleanup()
        XCTAssertTrue(driver.selectedRenderedButton)
        XCTAssertTrue(driver.attemptedDisabledSelection)
        XCTAssertTrue(driver.capturedActivating)
        XCTAssertTrue(driver.capturedReconciling)
        XCTAssertTrue(driver.capturedCompleted)
        XCTAssertEqual(fixture.refreshGate.callCount, 1)
        XCTAssertFalse(fixture.refreshGate.requestedUnexpectedProvider)
        XCTAssertTrue(fixture.transactionDrained)
        XCTAssertTrue(fixture.widgetTaskDrained)
        XCTAssertTrue(driver.failures.isEmpty, driver.failures.joined(separator: "\n"))
    }
}

struct ClaudeSwapProgressNativeProofConfiguration {
    let output: URL
    let expectedActivating: String
    let expectedReconciling: String
    let expectedCompleted: String?
    let expectedHeading: String?

    init(path: String, environment: [String: String]) {
        self.output = URL(fileURLWithPath: path, isDirectory: true)
        let isBaseline = environment["CODEXBAR_CLAUDE_SWAP_PROGRESS_BASELINE"] == "1"
        self.expectedActivating = environment["CODEXBAR_CLAUDE_SWAP_PROGRESS_EXPECT_ACTIVATING"] ??
            (isBaseline ? "Loading…" : "Switching account…")
        self.expectedReconciling = environment["CODEXBAR_CLAUDE_SWAP_PROGRESS_EXPECT_RECONCILING"] ??
            (isBaseline ? "Loading…" : "Refreshing account status…")
        // Skipping candidate acceptance checks requires an explicit baseline run.
        self.expectedCompleted = isBaseline ? nil :
            (environment["CODEXBAR_CLAUDE_SWAP_PROGRESS_EXPECT_COMPLETED"] ?? "Active")
        self.expectedHeading = isBaseline ? nil :
            (environment["CODEXBAR_CLAUDE_SWAP_PROGRESS_EXPECT_HEADING"] ?? "Switch Claude Code account")
    }
}
