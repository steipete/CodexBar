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
        let scenes: [(suffix: String, width: CGFloat, scheme: ColorScheme, language: String)] = [
            ("", 530, .light, "en"),
            ("-dark", 530, .dark, "en"),
            ("-narrow", 320, .light, "en"),
            ("-german", 530, .light, "de"),
            ("-arabic", 530, .light, "ar"),
        ]
        for scene in scenes {
            try self.renderRow(path: path, scene: scene)
        }
    }

    private func renderRow(
        path: String,
        scene: (suffix: String, width: CGFloat, scheme: ColorScheme, language: String)) throws
    {
        try CodexBarLocalizationOverride.$appLanguage.withValue(scene.language) {
            let updater = DisabledUpdaterController.homebrew()
            let reason = try XCTUnwrap(updater.unavailableReason)
            let view = Form {
                Section {
                    AboutUpdatesUnavailableView(reason: reason, command: updater.manualUpdateCommand)
                } header: {
                    Text(L("section_updates"))
                }
            }
            .formStyle(.grouped)
            .environment(\.locale, Locale(identifier: scene.language))
            .environment(\.layoutDirection, scene.language == "ar" ? .rightToLeft : .leftToRight)
            .environment(\.colorScheme, scene.scheme)
            .frame(width: scene.width, height: 190)
            let hosting = NSHostingView(rootView: view)
            hosting.appearance = NSAppearance(named: scene.scheme == .dark ? .darkAqua : .aqua)
            let data = try XCTUnwrap(MenuLayoutScreenshotRenderTests.pngDataWithWindow(hosting: hosting))
            let baseURL = URL(fileURLWithPath: path)
            let url = baseURL.deletingPathExtension()
                .appendingPathExtension("\(scene.suffix.isEmpty ? "" : scene.suffix + ".")png")
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        }
    }
}
