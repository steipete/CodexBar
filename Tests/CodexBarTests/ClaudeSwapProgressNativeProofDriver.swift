import AppKit
import CodexBarCore
import Foundation
import Vision
import XCTest
@testable import CodexBar

@MainActor
final class ClaudeSwapProgressNativeProofDriver {
    private let fixture: ClaudeSwapProgressNativeProofFixture
    private let controller: StatusItemController
    private let menu: NSMenu
    private let configuration: ClaudeSwapProgressNativeProofConfiguration
    private let startedAt = Date()
    private var stage: Stage = .opening
    private var stageStartedAt = Date()
    private var lastCaptureAt = Date.distantPast
    private var ticking = false
    private var selectionGeneration: Int?
    private var receipts: [[String: Any]] = []
    var trackingReturned = false
    private(set) var selectedRenderedButton = false
    private(set) var attemptedDisabledSelection = false
    private(set) var capturedActivating = false
    private(set) var capturedReconciling = false
    private(set) var capturedCompleted = false
    private(set) var failures: [String] = []

    init(
        fixture: ClaudeSwapProgressNativeProofFixture,
        controller: StatusItemController,
        menu: NSMenu,
        configuration: ClaudeSwapProgressNativeProofConfiguration)
    {
        self.fixture = fixture
        self.controller = controller
        self.menu = menu
        self.configuration = configuration
    }

    func tick() {
        guard self.stage != .finished, !self.ticking else { return }
        self.ticking = true
        defer { self.ticking = false }
        do {
            guard Date().timeIntervalSince(self.startedAt) < 45 else { throw ProofFailure.deadline }
            guard !self.trackingReturned,
                  self.controller.openMenus[ObjectIdentifier(self.menu)] === self.menu
            else { throw ProofFailure.menuNotTracking }
            guard !self.fixture.unexpectedArguments,
                  !self.fixture.refreshGate.requestedUnexpectedProvider,
                  self.fixture.refreshGate.callCount <= 1
            else { throw ProofFailure.unexpectedRequest }
            if let selectionGeneration {
                guard self.controller.menuSession.isCurrentMenuInteraction(
                    selectionGeneration, for: ObjectIdentifier(self.menu))
                else { throw ProofFailure.trackingGenerationChanged }
            }
            switch self.stage {
            case .opening: try self.openingTick()
            case .activating: try self.activatingTick()
            case .reconciling: try self.reconcilingTick()
            case .completed: try self.completedTick()
            case .finished: break
            }
        } catch {
            self.failures.append("\(self.stage.rawValue): \(error)")
            self.record(label: "failure", content: self.attachedContent(), capture: nil)
            self.finishTracking()
        }
    }

    private func openingTick() throws {
        guard !self.fixture.refreshGate.entered, !self.fixture.subprocessEntered else {
            throw ProofFailure.requestBeforeRenderedClick
        }
        guard let content = self.attachedContent(), self.shouldCapture else { return }
        let capture = try self.capture(label: "initial", content: content)
        let matches = Self.contains(capture.cardText, "Account 1") && Self.contains(capture.cardText, "61%") &&
            self.chipsMatch(content, activeSlot: 1, enabled: true) && self.headingMatches(capture)
        guard self.acceptCapture(matches: matches, description: "Initial attached Account 1 / 61% card and chips")
        else {
            return
        }
        let button = try XCTUnwrap(content.buttons.first { $0.title == "Account 2" })
        guard button.isEnabled, button.window === content.window else { throw ProofFailure.detachedContent }
        self.selectedRenderedButton = true
        button.performClick(nil)
        try self.fixture.observeStartedTransaction()
        self.selectionGeneration = try XCTUnwrap(
            self.controller.menuSession.menuInteractionGeneration(for: ObjectIdentifier(self.menu)))
        self.record(label: "rendered-account-2-click", content: self.attachedContent(), capture: nil)
        self.transition(to: .activating)
    }

    private func activatingTick() throws {
        guard self.fixture.subprocessEntered else { return }
        guard !self.fixture.subprocessReleased, !self.fixture.refreshGate.entered else {
            throw ProofFailure.activationGateNotHeld
        }
        try self.requirePendingTransaction()
        guard let content = self.attachedContent(), self.shouldCapture else { return }
        let capture = try self.capture(label: "activating", content: content)
        let matches = self.pendingCaptureMatches(
            capture, content: content, expected: self.configuration.expectedActivating)
        guard self.acceptCapture(matches: matches, description: self.configuration.expectedActivating) else { return }
        self.capturedActivating = true
        try self.fixture.releaseSubprocess()
        self.transition(to: .reconciling)
    }

    private func reconcilingTick() throws {
        guard self.fixture.refreshGate.entered else { return }
        guard self.fixture.subprocessReleased, !self.fixture.refreshGate.released,
              self.fixture.store.refreshingProviders.contains(.claude)
        else { throw ProofFailure.refreshGateNotHeld }
        try self.requirePendingTransaction()
        guard let content = self.attachedContent(), self.shouldCapture else { return }
        let capture = try self.capture(label: "reconciling", content: content)
        let matches = self.pendingCaptureMatches(
            capture, content: content, expected: self.configuration.expectedReconciling)
        guard self.acceptCapture(matches: matches, description: self.configuration.expectedReconciling) else { return }
        self.capturedReconciling = true
        guard content.buttons.allSatisfy({ !$0.isEnabled }) else { throw ProofFailure.chipsNotDisabled }
        // Exercise the newly attached, disabled third chip while the original transaction remains held.
        let disabledButton = try XCTUnwrap(content.buttons.first { $0.title == "Account 3" })
        disabledButton.performClick(nil)
        self.attemptedDisabledSelection = true
        try self.requireSingleSwitch()
        self.record(label: "disabled-account-3-click", content: content, capture: nil)
        self.fixture.refreshGate.release()
        self.transition(to: .completed)
    }

    private func completedTick() throws {
        guard self.fixture.transactionDrained, self.fixture.widgetTaskDrained else { return }
        guard self.fixture.store.claudeSwapTransientState.task == nil,
              self.fixture.store.claudeSwapTransientState.switchingAccountID == nil,
              self.fixture.store.claudeSwapTransientState.lastError == nil,
              self.fixture.publishedReconciledAccounts,
              self.activeSlots == ["2"]
        else { throw ProofFailure.transactionDidNotReconcile }
        try self.requireSingleSwitch()
        guard let content = self.attachedContent(), self.shouldCapture else { return }
        let capture = try self.capture(label: "completed", content: content)
        var matches = Self.contains(capture.cardText, "Account 2") && Self.contains(capture.cardText, "17%") &&
            self.headingMatches(capture)
        if let expected = self.configuration.expectedCompleted {
            matches = matches && Self.contains(capture.cardText, expected) &&
                self.chipsMatch(content, activeSlot: 2, enabled: true)
        }
        guard self.acceptCapture(matches: matches, description: "Completed attached Account 2 card") else { return }
        self.capturedCompleted = true
        self.finishTracking()
    }

    private var shouldCapture: Bool {
        Date().timeIntervalSince(self.lastCaptureAt) >= 0.5
    }

    private var activeSlots: [String] {
        self.fixture.store.claudeSwapAccountSnapshots.filter(\.isActive).map(\.id.opaqueID)
    }

    private func requirePendingTransaction() throws {
        guard self.fixture.store.claudeSwapTransientState.task != nil,
              self.fixture.store.claudeSwapTransientState.switchingAccountID == self.fixture.targetID,
              self.fixture.store.claudeSwapTransientState.lastError == nil,
              self.activeSlots == ["1"],
              !self.fixture.publishedReconciledAccounts
        else { throw ProofFailure.pendingTransactionMismatch }
        try self.requireSingleSwitch()
    }

    private func requireSingleSwitch() throws {
        guard try self.fixture.switchArguments() == "--switch-to\n2\n--json\n" else {
            throw ProofFailure.unexpectedRequest
        }
    }

    private func pendingCaptureMatches(_ capture: Capture, content: Content, expected: String) -> Bool {
        Self.contains(capture.cardText, "Account 2") && Self.contains(capture.cardText, "17%") &&
            Self.contains(capture.cardText, expected) && self.chipsMatch(content, activeSlot: 1, enabled: false) &&
            self.headingMatches(capture)
    }

    private func chipsMatch(_ content: Content, activeSlot: Int, enabled: Bool) -> Bool {
        // Reconciliation moves the active slot first; identity must not depend on its position.
        guard content.buttons.count == 3,
              Set(content.buttons.map(\.title)) == Set(["Account 1", "Account 2", "Account 3"])
        else { return false }
        return content.buttons.allSatisfy { button in
            button.isEnabled == enabled &&
                button.state == (button.title == "Account \(activeSlot)" ? .on : .off)
        }
    }

    private func headingMatches(_ capture: Capture) -> Bool {
        self.configuration.expectedHeading.map { Self.contains(capture.menuText, $0) } ?? true
    }

    private func acceptCapture(matches: Bool, description: String) -> Bool {
        if matches { return true }
        guard Date().timeIntervalSince(self.stageStartedAt) >= 8 else { return false }
        // Record the mismatch, then advance by releasing the synthetic gate so both stages remain reviewable.
        self.failures.append("\(self.stage.rawValue): attached pixels/controls did not match \(description)")
        return true
    }

    private func transition(to stage: Stage) {
        self.stage = stage
        self.stageStartedAt = Date()
    }

    private func finishTracking() {
        try? self.fixture.releaseSubprocess()
        self.fixture.refreshGate.release()
        self.stage = .finished
        self.menu.cancelTrackingWithoutAnimation()
    }

    func writeReceipt() throws {
        let arguments = try self.fixture.switchArguments()
        let receipt: [String: Any] = [
            "syntheticOnly": true,
            "captureSource": "actual attached menu window pixels",
            "selectedRenderedAccount2Button": self.selectedRenderedButton,
            "attemptedDisabledAccount3Button": self.attemptedDisabledSelection,
            "capturedActivating": self.capturedActivating,
            "capturedReconciling": self.capturedReconciling,
            "capturedCompleted": self.capturedCompleted,
            "expectedActivating": self.configuration.expectedActivating,
            "expectedReconciling": self.configuration.expectedReconciling,
            "expectedCompleted": self.configuration.expectedCompleted ?? "record only",
            "expectedHeading": self.configuration.expectedHeading ?? "record only",
            "switchArguments": arguments,
            "switchCommandCount": arguments.split(separator: "\n").count / 3,
            "unexpectedArguments": self.fixture.unexpectedArguments,
            "providerRefreshCount": self.fixture.refreshGate.callCount,
            "unexpectedProviderRequest": self.fixture.refreshGate.requestedUnexpectedProvider,
            "transactionDrainedAfterTracking": self.fixture.transactionDrained,
            "widgetTaskDrainedAfterTracking": self.fixture.widgetTaskDrained,
            "publishedReconciledAccounts": self.fixture.publishedReconciledAccounts,
            "finalTaskPresent": self.fixture.store.claudeSwapTransientState.task != nil,
            "finalTargetSlot": self.fixture.store.claudeSwapTransientState.switchingAccountID?.opaqueID ?? "none",
            "trackingReturned": self.trackingReturned,
            "failures": self.failures,
            "stages": self.receipts,
        ]
        try JSONSerialization.data(withJSONObject: receipt, options: [.prettyPrinted, .sortedKeys])
            .write(to: self.configuration.output.appendingPathComponent("receipt.json"), options: .atomic)
    }

    private func record(label: String, content: Content?, capture: Capture?) {
        var receipt = MergedMenuScrollingSwapNativeProofTests.phaseReceipt(
            menu: self.menu, label: label, settings: self.fixture.settings)
        receipt["trackingReturned"] = self.trackingReturned
        receipt["sameMenuObjectTracking"] = self.controller.openMenus[ObjectIdentifier(self.menu)] === self.menu
        receipt["menuInteractionGeneration"] = self.controller.menuSession.menuInteractionGeneration(
            for: ObjectIdentifier(self.menu)) ?? -1
        receipt["statusItemMenuGeneration"] = (self.menu as? StatusItemMenu)?.menuInteractionGeneration ?? -1
        receipt["selectionGeneration"] = self.selectionGeneration ?? -1
        receipt["subprocessEntered"] = self.fixture.subprocessEntered
        receipt["subprocessReleased"] = self.fixture.subprocessReleased
        receipt["refreshGateEntered"] = self.fixture.refreshGate.entered
        receipt["refreshGateReleased"] = self.fixture.refreshGate.released
        receipt["refreshingClaude"] = self.fixture.store.refreshingProviders.contains(.claude)
        receipt["refreshCount"] = self.fixture.refreshGate.callCount
        receipt["switchCommandCount"] = (try? self.fixture.switchArguments().split(separator: "\n").count / 3) ?? -1
        receipt["taskPresent"] = self.fixture.store.claudeSwapTransientState.task != nil
        receipt["targetSlot"] = self.fixture.store.claudeSwapTransientState.switchingAccountID?.opaqueID ?? "none"
        receipt["adapterRevision"] = self.fixture.store.claudeSwapRevision
        receipt["activeSlots"] = self.activeSlots
        receipt["publishedReconciledAccounts"] = self.fixture.publishedReconciledAccounts
        receipt["transactionDrained"] = self.fixture.transactionDrained
        receipt["cardOCR"] = capture?.cardText ?? ""
        receipt["menuOCR"] = capture?.menuText ?? ""
        if let content {
            receipt["cardObject"] = String(describing: ObjectIdentifier(content.card))
            receipt["switcherObject"] = String(describing: ObjectIdentifier(content.switcher))
            receipt["windowObject"] = String(describing: ObjectIdentifier(content.window))
            receipt["windowNumber"] = content.window.windowNumber
            receipt["windowVisible"] = content.window.isVisible
            receipt["cardVisibleRect"] = NSStringFromRect(content.card.visibleRect)
            receipt["buttons"] = content.buttons.map { button -> [String: Any] in
                [
                    "tag": button.tag,
                    "title": button.title,
                    "enabled": button.isEnabled,
                    "state": button.state.rawValue,
                    "toolTip": button.toolTip ?? "",
                    "accessibilityLabel": button.accessibilityLabel() ?? "",
                    "sameWindowAsCard": button.window === content.window,
                    "frameInWindow": NSStringFromRect(button.convert(button.bounds, to: nil)),
                ]
            }
        }
        self.receipts.append(receipt)
    }

    private func attachedContent() -> Content? {
        guard let switcher = self.menu.items.compactMap({ $0.view as? ClaudeSwapAccountSwitcherView }).first,
              let card = self.menu.items.first(where: { ($0.representedObject as? String) == "menuCard-0" })?.view,
              let window = card.window,
              window.isVisible,
              switcher.window === window,
              self.menu.items.lazy.compactMap({ $0.view?.window }).first === window,
              card.visibleRect.width > 0, card.visibleRect.height > 0
        else { return nil }
        let buttons = Self.descendants(of: switcher).compactMap { $0 as? NSButton }.sorted { $0.tag < $1.tag }
        guard buttons.count == 3, buttons.map(\.tag) == [0, 1, 2],
              buttons.allSatisfy({ $0.window === window && $0.visibleRect.width > 0 && $0.visibleRect.height > 0 })
        else { return nil }
        return Content(card: card, switcher: switcher, window: window, buttons: buttons)
    }

    private func capture(label: String, content: Content) throws -> Capture {
        self.lastCaptureAt = Date()
        let url = self.configuration.output.appendingPathComponent("\(label)-menu-\(UUID().uuidString).png")
        MergedMenuScrollingSwapNativeProofTests.capture(menu: self.menu, to: url)
        let image = try XCTUnwrap(NSImage(contentsOf: url)?.cgImage(forProposedRect: nil, context: nil, hints: nil))
        try Data(contentsOf: url).write(
            to: self.configuration.output.appendingPathComponent("\(label)-menu.png"), options: .atomic)
        let frame = content.card.convert(content.card.bounds, to: nil)
        let scaleX = CGFloat(image.width) / content.window.frame.width
        let scaleY = CGFloat(image.height) / content.window.frame.height
        let cropRect = CGRect(
            x: frame.minX * scaleX,
            y: CGFloat(image.height) - frame.maxY * scaleY,
            width: frame.width * scaleX,
            height: frame.height * scaleY).integral
        let crop = try XCTUnwrap(image.cropping(to: cropRect))
        let png = try XCTUnwrap(NSBitmapImageRep(cgImage: crop).representation(using: .png, properties: [:]))
        try png.write(to: self.configuration.output.appendingPathComponent("\(label)-card.png"), options: .atomic)
        let capture = try Capture(cardText: Self.recognize(crop), menuText: Self.recognize(image))
        self.record(label: label, content: content, capture: capture)
        return capture
    }

    private static func recognize(_ image: CGImage) throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["en-US"]
        // Keep synthetic OCR independent of accelerator availability on the test host.
        for (stage, devices) in try request.supportedComputeStageDevices {
            let cpu = try XCTUnwrap(devices.first { device in
                if case .cpu = device { return true }
                return false
            })
            request.setComputeDevice(cpu, for: stage)
        }
        try VNImageRequestHandler(cgImage: image).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }

    private static func contains(_ actual: String, _ expected: String) -> Bool {
        func normalized(_ value: String) -> String {
            value.lowercased().filter { $0.isLetter || $0.isNumber || $0 == "%" }
        }
        return normalized(actual).contains(normalized(expected))
    }

    private static func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + self.descendants(of: $0) }
    }

    private struct Content {
        let card: NSView
        let switcher: ClaudeSwapAccountSwitcherView
        let window: NSWindow
        let buttons: [NSButton]
    }

    private struct Capture {
        let cardText: String
        let menuText: String
    }

    private enum Stage: String {
        case opening
        case activating
        case reconciling
        case completed
        case finished
    }

    private enum ProofFailure: Error {
        case deadline
        case menuNotTracking
        case trackingGenerationChanged
        case detachedContent
        case unexpectedRequest
        case requestBeforeRenderedClick
        case activationGateNotHeld
        case refreshGateNotHeld
        case pendingTransactionMismatch
        case chipsNotDisabled
        case transactionDidNotReconcile
    }
}
