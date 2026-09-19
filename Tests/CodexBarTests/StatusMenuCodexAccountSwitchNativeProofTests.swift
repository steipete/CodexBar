import AppKit
import CodexBarCore
import Foundation
import Vision
import XCTest
@testable import CodexBar

/// Opt-in proof of the attached account card during real AppKit menu tracking, using synthetic accounts only.
@MainActor
final class StatusMenuCodexAccountSwitchNativeProofTests: XCTestCase {
    func test_accountSwitchRendersFetchedUsageInStillOpenCard() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["CODEXBAR_ACCOUNT_SWITCH_PROOF_DIR"] else {
            throw XCTSkip("Set CODEXBAR_ACCOUNT_SWITCH_PROOF_DIR for synthetic native menu proof")
        }
        guard environment["CODEXBAR_SUPPRESS_TEST_KEYCHAIN_ACCESS"] == "1",
              environment[CodexCredentialFileAccess.isolationEnvironmentKey] == "1",
              environment["CODEXBAR_TEST_SESSION_FILE_ISOLATION"] == "1",
              environment["CODEXBAR_ALLOW_TEST_KEYCHAIN_ACCESS"] != "1"
        else { return XCTFail("Native proof requires credential and session isolation") }
        let output = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let fixture = try CodexAccountMenuPhaseFixture()
        var mayCleanFixture = true
        defer { if mayCleanFixture { fixture.cleanup() } }
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
        let controller = fixture.makeController()
        defer { controller.releaseStatusItemsForTesting() }
        XCTAssertNil(controller._test_openMenuRebuildObserver)
        XCTAssertNil(controller._test_openMenuRefreshYieldOverride)
        let menu = try XCTUnwrap(controller.mergedMenu)
        let driver = try CodexAccountSwitchTrackingDriver(
            fixture: fixture,
            controller: controller,
            menu: menu,
            output: output)
        let timer = Timer(timeInterval: 0.1, repeats: true) { _ in
            MainActor.assumeIsolated { driver.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        defer { timer.invalidate() }
        app.activate(ignoringOtherApps: true)
        let button = try XCTUnwrap(controller.statusItem.button)
        mayCleanFixture = false
        await withCheckedContinuation { continuation in
            // Enter AppKit from its run loop after the async test releases the main actor.
            ProviderSwitcherTrackingRunLoopScheduler.schedule {
                button.performClick(nil)
                continuation.resume()
            }
        }
        timer.invalidate()
        driver.trackingReturned = true
        controller.releaseStatusItemsForTesting()
        fixture.gate.release()
        let deadline = ContinuousClock.now + .seconds(5)
        while !fixture.gate.completed, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        if fixture.gate.completed {
            await fixture.store.widgetSnapshotPersistTask?.value
            mayCleanFixture = true
        }
        try driver.writeReceipt()
        XCTAssertEqual(fixture.gate.startCount, 1, "A later refresh must not supply the expected card")
        XCTAssertFalse(fixture.gate.requestedUnexpectedProvider)
        XCTAssertTrue(fixture.gate.completed, "Keep fixture isolation alive until the entire action finishes")
        XCTAssertTrue(driver.selectedRenderedButton, "The actual attached account button must receive its action")
        XCTAssertTrue(driver.observedPendingFetch, "The synthetic fetch must remain held during menu tracking")
        XCTAssertTrue(driver.capturedAfter, "The still-open attached B card must show 17% before tracking ends")
        XCTAssertNil(driver.failure)
    }
}

@MainActor
private final class CodexAccountSwitchTrackingDriver {
    private let fixture: CodexAccountMenuPhaseFixture
    private let controller: StatusItemController
    private let menu: NSMenu
    private let output: URL
    private let targetID: String
    private var ticks = 0
    private var releasedAtTick: Int?
    private var receipts: [[String: Any]] = []
    var trackingReturned = false
    private(set) var selectedRenderedButton = false
    private(set) var observedPendingFetch = false
    private(set) var capturedAfter = false
    private(set) var failure: String?

    init(
        fixture: CodexAccountMenuPhaseFixture,
        controller: StatusItemController,
        menu: NSMenu,
        output: URL) throws
    {
        self.fixture = fixture
        self.controller = controller
        self.menu = menu
        self.output = output
        self.targetID = try fixture.managedVisibleAccount().id
    }

    func tick() {
        self.ticks += 1
        do {
            guard !self.trackingReturned,
                  self.controller.openMenus[ObjectIdentifier(self.menu)] === self.menu
            else { throw ProofFailure.menuNotTracking }
            if self.ticks > 300 { throw ProofFailure.deadline }
            if !self.selectedRenderedButton {
                guard self.ticks >= 5 else { return }
                guard !self.fixture.gate.entered else { throw ProofFailure.unexpectedFetch }
                let before = try self.capture(label: "before").replacingOccurrences(of: " ", with: "").lowercased()
                guard before.contains("account-a@example.invalid"), before.contains("11%") else {
                    throw ProofFailure.initialCardMismatch
                }
                let switcher = try XCTUnwrap(self.menu.items.compactMap { $0.view as? CodexAccountSwitcherView }.first)
                let button = try XCTUnwrap(Self.descendants(of: switcher).compactMap { $0 as? NSButton }
                    .first { $0.identifier?.rawValue == self.targetID })
                guard button.window != nil, button.isEnabled else { throw ProofFailure.detachedCard }
                self.selectedRenderedButton = true
                button.performClick(nil)
                return
            }
            if self.releasedAtTick == nil {
                guard self.fixture.gate.entered, self.ticks >= 10 else { return }
                guard self.fixture.gate.startCount == 1 else { throw ProofFailure.unexpectedFetch }
                self.observedPendingFetch = true
                self.record(label: "pending", text: "")
                self.releasedAtTick = self.ticks
                self.fixture.gate.release()
                return
            }
            guard self.fixture.store.snapshots[.codex]?.primary?.usedPercent == 17,
                  self.fixture.settings.codexVisibleAccountProjection.activeVisibleAccountID == self.targetID,
                  self.ticks.isMultiple(of: 10)
            else { return }
            let text = try self.capture(label: "after")
            let compact = text.replacingOccurrences(of: " ", with: "").lowercased()
            if compact.contains("17%"), compact.contains("account-b@example.invalid") {
                self.capturedAfter = true
                self.menu.cancelTrackingWithoutAnimation()
            } else if self.ticks - (self.releasedAtTick ?? self.ticks) > 120 {
                throw ProofFailure.cardDidNotUpdate
            }
        } catch {
            self.failure = String(describing: error)
            self.fixture.gate.release()
            self.menu.cancelTrackingWithoutAnimation()
        }
    }

    func writeReceipt() throws {
        let data: [String: Any] = [
            "syntheticOnly": true,
            "selectedRenderedButton": self.selectedRenderedButton,
            "observedPendingFetch": self.observedPendingFetch,
            "capturedAfter": self.capturedAfter,
            "providerRefreshCount": self.fixture.gate.startCount,
            "scopedRefreshCompleted": self.fixture.gate.completed,
            "unexpectedProviderRequest": self.fixture.gate.requestedUnexpectedProvider,
            "failure": self.failure as Any? ?? NSNull(),
            "phases": self.receipts,
        ]
        try JSONSerialization.data(withJSONObject: data, options: [.prettyPrinted, .sortedKeys])
            .write(to: self.output.appendingPathComponent("receipt.json"), options: .atomic)
    }

    private func record(label: String, text: String) {
        var receipt = MergedMenuScrollingSwapNativeProofTests.phaseReceipt(
            menu: self.menu, label: label, settings: self.fixture.settings)
        receipt["trackingReturned"] = self.trackingReturned
        receipt["selectedAccount"] = self.fixture.settings.codexVisibleAccountProjection.activeVisibleAccountID
        receipt["publishedEmail"] = self.fixture.store.snapshots[.codex]?.accountEmail(for: .codex)
        receipt["publishedUsedPercent"] = self.fixture.store.snapshots[.codex]?.primary?.usedPercent
        receipt["cardText"] = text
        self.receipts.append(receipt)
    }

    private func capture(label: String) throws -> String {
        let menuURL = self.output.appendingPathComponent("\(label)-menu-\(UUID().uuidString).png")
        MergedMenuScrollingSwapNativeProofTests.capture(menu: self.menu, to: menuURL)
        let image = try XCTUnwrap(NSImage(contentsOf: menuURL)?.cgImage(forProposedRect: nil, context: nil, hints: nil))
        try Data(contentsOf: menuURL).write(
            to: self.output.appendingPathComponent("\(label)-menu.png"), options: .atomic)
        guard let card = self.menu.items.first(where: {
            let id = $0.representedObject as? String ?? ""
            return id.hasPrefix("menuCard") && $0.view?.window != nil
        })?.view else {
            self.record(label: label, text: "")
            return ""
        }
        let window = try XCTUnwrap(card.window)
        guard window.isVisible, card.bounds.width > 0, card.bounds.height > 0 else {
            throw ProofFailure.detachedCard
        }
        let frame = card.convert(card.bounds, to: nil)
        let scaleX = CGFloat(image.width) / window.frame.width
        let scaleY = CGFloat(image.height) / window.frame.height
        let cropRect = CGRect(
            x: frame.minX * scaleX,
            y: CGFloat(image.height) - frame.maxY * scaleY,
            width: frame.width * scaleX,
            height: frame.height * scaleY).integral
        let crop = try XCTUnwrap(image.cropping(to: cropRect))
        let png = try XCTUnwrap(NSBitmapImageRep(cgImage: crop).representation(using: .png, properties: [:]))
        try png.write(to: self.output.appendingPathComponent("\(label)-card.png"), options: .atomic)
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        try VNImageRequestHandler(cgImage: crop).perform([request])
        let text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
        self.record(label: label, text: text)
        return text
    }

    private static func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + self.descendants(of: $0) }
    }

    private enum ProofFailure: Error {
        case menuNotTracking
        case deadline
        case detachedCard
        case cardDidNotUpdate
        case initialCardMismatch
        case unexpectedFetch
    }
}
