import AppKit
import SwiftUI
import XCTest
@testable import CodexBar

@MainActor
final class AboutUpdatePreferenceTests: XCTestCase {
    func test_openingAboutPreservesTheInstallChoice() throws {
        let defaults = InMemoryUserDefaults(values: ["autoUpdateEnabled": true, "SUAutomaticallyUpdate": false])
        let updater = RecordingUpdater()
        let selection = PreferencesSelection(userDefaults: defaults)
        selection.requestAboutRoot()
        let hosting = NSHostingView(rootView: AboutPane(updater: updater, selection: selection)
            .defaultAppStorage(defaults)
            .frame(width: 700, height: 680))
        _ = try XCTUnwrap(MenuLayoutScreenshotRenderTests.pngDataWithWindow(hosting: hosting))
        XCTAssertTrue(updater.automaticallyChecksForUpdates)
        XCTAssertFalse(updater.automaticallyDownloadsUpdates)
        XCTAssertEqual(updater.installWrites, 0, "Opening Settings must not write Sparkle's install preference")
    }

    private final class RecordingUpdater: UpdaterProviding {
        var automaticallyChecksForUpdates = false
        var automaticallyDownloadsUpdates = false {
            didSet { self.installWrites += 1 }
        }

        var installWrites = 0
        let isAvailable = true
        let unavailableReason: String? = nil
        let updateStatus = UpdateStatus()
        func checkForUpdates(_: Any?) {}
        func installUpdate() {}
    }
}
