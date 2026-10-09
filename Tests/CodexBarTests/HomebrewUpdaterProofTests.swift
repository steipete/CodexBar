import AppKit
import SwiftUI
import XCTest
@testable import CodexBar

@MainActor
final class HomebrewUpdaterProofTests: XCTestCase {
    func test_renderSyntheticHomebrewUpdates() async throws {
        guard let path = ProcessInfo.processInfo.environment["CODEXBAR_HOMEBREW_PROOF_DIR"] else {
            throw XCTSkip("Set CODEXBAR_HOMEBREW_PROOF_DIR to render synthetic Homebrew update rows")
        }
        let updater = HomebrewUpdaterController(
            savedAutoCheck: false,
            dependencies: .init(
                installedVersion: { "0.65.0" },
                fetchCaskSource: { "version \"0.66.0\"" },
                runUpgrade: {},
                relaunch: {},
                cask: { .tap }),
            startScheduledChecks: false)
        await updater.performCheck()
        let directory = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try CodexBarLocalizationOverride.$appLanguage.withValue("en") {
            for width in [530.0, 320.0] {
                try self.render(
                    AboutUpdatesUnavailableView(reason: L("Managed by Homebrew"), command: updater.manualUpdateCommand),
                    width: width,
                    to: directory.appendingPathComponent("before-\(Int(width)).png"))
                try self.render(
                    AboutHomebrewUpdateStatusView(updater: updater),
                    width: width,
                    to: directory.appendingPathComponent("after-\(Int(width)).png"))
            }
        }
    }

    private func render(_ content: some View, width: CGFloat, to url: URL) throws {
        let view = Form {
            Section {
                content
            } header: {
                Text(L("section_updates"))
            }
        }
        .formStyle(.grouped)
        .environment(\.colorScheme, .light)
        .frame(width: width, height: 190)
        let hosting = NSHostingView(rootView: view)
        hosting.appearance = NSAppearance(named: .aqua)
        let data = try XCTUnwrap(MenuLayoutScreenshotRenderTests.pngDataWithWindow(hosting: hosting))
        try data.write(to: url, options: .atomic)
    }
}
