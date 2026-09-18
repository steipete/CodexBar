import AppKit
import SwiftUI
import XCTest
@testable import CodexBar
@testable import CodexBarCore

/// Opt-in native pointer proof using synthetic data and the production chart inside NSMenu.
@MainActor
final class InlineCostHoverNativeProofTests: XCTestCase {
    func test_pointerMenu() throws {
        guard let path = ProcessInfo.processInfo.environment["CODEXBAR_INLINE_HOVER_NATIVE_DIR"] else {
            throw XCTSkip("Set CODEXBAR_INLINE_HOVER_NATIVE_DIR for native pointer proof")
        }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let app = NSApplication.shared
        guard app.delegate == nil else { return XCTFail("Requires a standalone test application") }
        let previousApp = NSWorkspace.shared.frontmostApplication
        let previousPolicy = app.activationPolicy()
        let menu = NSMenu()
        menu.autoenablesItems = false
        let model = Self.model()
        let hosting = NSHostingView(rootView: InlineUsageDashboardContent(model: model)
            .padding(20).frame(width: 310).background(Color(nsColor: .windowBackgroundColor)))
        hosting.frame = NSRect(origin: .zero, size: hosting.fittingSize)
        let row = NSMenuItem()
        row.view = hosting
        menu.addItem(row)
        let host = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 600),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false)
        host.title = "CodexBar Synthetic Hover Proof"
        host.isReleasedWhenClosed = false
        let button = InlineCostHoverProofButton(frame: NSRect(x: 80, y: 80, width: 200, height: 32))
        button.title = "Open cost chart"
        button.proofMenu = menu
        button.target = button
        button.action = #selector(InlineCostHoverProofButton.openMenu)
        host.contentView?.addSubview(button)
        defer {
            menu.cancelTracking()
            host.close()
            _ = app.setActivationPolicy(previousPolicy)
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier {
                previousApp?.activate()
            }
        }
        _ = app.setActivationPolicy(.regular)
        app.finishLaunching()
        host.center()
        host.makeKeyAndOrderFront(nil)
        app.activate(ignoringOtherApps: true)
        let deadline = Date().addingTimeInterval(600)
        let done = directory.appendingPathComponent("done").path
        let timer = Timer(timeInterval: 0.1, repeats: true) { _ in
            MainActor.assumeIsolated {
                var receipt = [
                    "pid": String(ProcessInfo.processInfo.processIdentifier),
                    "window": String(host.windowNumber),
                    "screenHeight": String(Double(NSScreen.screens.first?.frame.maxY ?? 0)),
                ]
                if let tracker = Self.tracker(in: hosting), let window = tracker.window {
                    let rect = window.convertToScreen(tracker.convert(tracker.bounds, to: nil))
                    receipt["trackingRect"] = NSStringFromRect(rect)
                    receipt["rowSize"] = NSStringFromSize(hosting.frame.size)
                    receipt["barCount"] = String(model.points.count)
                }
                do {
                    try JSONEncoder().encode(receipt).write(
                        to: directory.appendingPathComponent("state.json"), options: .atomic)
                } catch { XCTFail("Could not persist native receipt: \(error)") }
                if FileManager.default.fileExists(atPath: done) || Date() >= deadline {
                    button.proofMenu?.cancelTracking()
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        defer { timer.invalidate() }
        while !FileManager.default.fileExists(atPath: done), Date() < deadline {
            if let event = app.nextEvent(
                matching: .any, until: Date().addingTimeInterval(0.02), inMode: .default, dequeue: true)
            {
                app.sendEvent(event)
            }
            _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: done), "Native proof timed out")
    }

    private static func tracker(in view: NSView) -> MouseLocationReader.TrackingView? {
        if let tracker = view as? MouseLocationReader.TrackingView { return tracker }
        return view.subviews.lazy.compactMap { Self.tracker(in: $0) }.first
    }

    private static func model() -> InlineUsageDashboardModel {
        let points = (0..<4).map { index in
            let detail: InlineUsageDashboardModel.HoverDetail? = index == 1 ? nil : .init(
                dateLabel: "Sep \(index + 5)",
                cost: Double(index + 1),
                tokenCount: (index + 1) * 1000,
                currencyCode: "USD")
            return InlineUsageDashboardModel.Point(
                id: "synthetic-\(index)",
                label: "Sep \(index + 5)",
                value: detail?.cost,
                accessibilityValue: detail?.summary ?? "Sep 6: Unknown",
                hoverDetail: detail)
        }
        return InlineUsageDashboardModel(
            accessibilityLabel: "Synthetic cost history",
            valueStyle: .currencyUSD,
            kpis: [.init(title: "Today", value: "$4.00", emphasis: true)],
            points: points,
            detailLines: ["Synthetic usage · four calendar days"],
            currencyCode: "USD")
    }
}

@MainActor
private final class InlineCostHoverProofButton: NSButton {
    var proofMenu: NSMenu?

    @objc func openMenu() {
        self.proofMenu?.popUp(positioning: nil, at: NSPoint(x: 0, y: self.bounds.maxY), in: self)
    }
}
