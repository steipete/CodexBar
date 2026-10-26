import AppKit
import SwiftUI
import XCTest
@testable import CodexBar

@MainActor
final class AboutUpdatePreferenceStateTests: XCTestCase {
    func test_installToggleObservesSavedChoiceWhileChecksAreOffAndDialogChanges() throws {
        let updater = try SparklePreferenceFixture(install: true, checks: false)
        defer { updater.cleanup() }
        let selection = PreferencesSelection(userDefaults: updater.defaults)
        selection.requestAboutRoot()
        let hosting = NSHostingView(rootView: AboutPane(updater: updater, selection: selection)
            .defaultAppStorage(updater.defaults).frame(width: 700, height: 680))
        hosting.frame = CGRect(x: 0, y: 0, width: 700, height: 680)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        defer {
            window.contentView = nil
            window.close()
        }
        window.layoutIfNeeded()
        hosting.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)

        XCTAssertFalse(updater.automaticallyDownloadsUpdates)
        XCTAssertTrue(updater.defaults.bool(forKey: "SUAutomaticallyUpdate"))
        try self.assertInstallChoice(true, in: hosting)

        updater.defaults.set(true, forKey: "autoUpdateEnabled")
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        self.drainUntil {
            hosting.layoutSubtreeIfNeeded()
            return updater.automaticallyDownloadsUpdates
        }
        XCTAssertTrue(updater.automaticallyDownloadsUpdates)
        try self.assertInstallChoice(true, in: hosting)

        updater.automaticallyDownloadsUpdates = false
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        try self.assertInstallChoice(false, in: hosting)
        XCTAssertFalse(updater.defaults.bool(forKey: "SUAutomaticallyUpdate"))
    }

    private func assertInstallChoice(_ enabled: Bool, in hosting: NSView) throws {
        self.drainUntil {
            hosting.layoutSubtreeIfNeeded()
            return self.installChoice(in: hosting) == enabled
        }
        XCTAssertEqual(try XCTUnwrap(self.installChoice(in: hosting)), enabled)
    }

    private func installChoice(in hosting: NSView) -> Bool? {
        let switches = self.switches(in: hosting).sorted {
            let lhs = $0.convert($0.bounds, to: hosting).midY
            let rhs = $1.convert($1.bounds, to: hosting).midY
            return hosting.isFlipped ? lhs < rhs : lhs > rhs
        }
        // The update controls are ordered checks, then installs. Offscreen Forms hide AX children.
        guard switches.count == 2 else { return nil }
        return switches[1].state == .on
    }

    private func switches(in view: NSView) -> [NSSwitch] {
        if let toggle = view as? NSSwitch { return [toggle] }
        return view.subviews.flatMap { self.switches(in: $0) }
    }

    private func drainUntil(_ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(2)
        while !condition(), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
    }
}
