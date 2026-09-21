import AppKit
import SwiftUI
import XCTest
@testable import CodexBar

@MainActor
final class AboutUpdateCommandTests: XCTestCase {
    func test_homebrewButtonCopiesOnlyCommandThroughDeferredWriter() throws {
        let updater = DisabledUpdaterController.homebrew()
        let probe = AboutCopyTriggerProbe()
        defer {
            probe.press = nil
            probe.pendingWrite = nil
        }
        let row = try AboutUpdatesUnavailableView(
            reason: XCTUnwrap(updater.unavailableReason),
            command: updater.manualUpdateCommand,
            copyAction: { text, completion in
                MenuPasteboardCopy.perform(
                    text,
                    scheduler: { probe.pendingWrite = $0 },
                    writer: { probe.writes.append($0) },
                    completion: { completion(true) })
            })
            .buttonStyle(AboutCopyTriggerStyle(probe: probe))
        try self.withHostedRow(row) {
            let press = try XCTUnwrap(probe.press, "The production row must expose a Copy button")
            XCTAssertTrue(probe.writes.isEmpty)
            press()
            XCTAssertTrue(probe.writes.isEmpty, "Copy remains deferred until the main-queue writer runs")
            let write = try XCTUnwrap(probe.pendingWrite)
            probe.pendingWrite = nil
            write()
            XCTAssertEqual(probe.writes, ["brew upgrade --cask steipete/tap/codexbar"])
        }
    }

    func test_genericUnavailableMessageDoesNotInventHomebrewAction() throws {
        let updater = DisabledUpdaterController(unavailableReason: "Run: brew upgrade --cask steipete/tap/codexbar")
        let probe = AboutCopyTriggerProbe()
        defer { probe.press = nil }
        let row = try AboutUpdatesUnavailableView(
            reason: XCTUnwrap(updater.unavailableReason),
            command: updater.manualUpdateCommand,
            copyAction: { text, completion in
                probe.writes.append(text)
                completion(true)
            })
            .buttonStyle(AboutCopyTriggerStyle(probe: probe))
        self.withHostedRow(row) {
            XCTAssertNil(probe.press)
            XCTAssertTrue(probe.writes.isEmpty)
        }
    }

    private func withHostedRow(
        _ row: some View,
        operation: () throws -> Void) rethrows
    {
        let form = Form {
            Section { row }
        }
        .formStyle(.grouped)
        .frame(width: 530, height: 190)
        let hosting = NSHostingView(rootView: form)
        let size = hosting.fittingSize
        XCTAssertGreaterThan(size.height, 0)
        hosting.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(
            contentRect: hosting.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        defer {
            window.contentView = nil
            window.close()
        }
        window.layoutIfNeeded()
        hosting.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
            XCTFail("The production row must render before its action is inspected")
            return
        }
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        try operation()
    }
}

@MainActor
private final class AboutCopyTriggerProbe {
    var press: (() -> Void)?
    var pendingWrite: MenuPasteboardCopy.DeferredAction?
    var writes: [String] = []
}

@MainActor
private struct AboutCopyTriggerStyle: PrimitiveButtonStyle {
    let probe: AboutCopyTriggerProbe

    func makeBody(configuration: Configuration) -> some View {
        configuration.label.onAppear {
            self.probe.press = { configuration.trigger() }
        }
    }
}
