import AppKit
import SwiftUI
import XCTest
@testable import CodexBar

@MainActor
final class AboutUpdateCommandProofTests: XCTestCase {
    func test_renderUnavailableUpdateRow() throws {
        guard let path = ProcessInfo.processInfo.environment["CODEXBAR_ABOUT_COPY_PROOF_PATH"] else {
            throw XCTSkip("Set CODEXBAR_ABOUT_COPY_PROOF_PATH to render the synthetic About update row")
        }
        try CodexBarLocalizationOverride.$appLanguage.withValue("en") {
            let updater = DisabledUpdaterController.homebrew()
            let reason = try XCTUnwrap(updater.unavailableReason)
            let view = Form {
                Section {
                    AboutUpdatesUnavailableView(reason: reason, command: updater.manualUpdateCommand)
                }
            }
            .formStyle(.grouped)
            .environment(\.locale, Locale(identifier: "en_US_POSIX"))
            .environment(\.colorScheme, .light)
            .frame(width: 530, height: 190)
            let hosting = NSHostingView(rootView: view)
            hosting.appearance = NSAppearance(named: .aqua)
            let data = try XCTUnwrap(MenuLayoutScreenshotRenderTests.pngDataWithWindow(hosting: hosting))
            let url = URL(fileURLWithPath: path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        }
    }
}
