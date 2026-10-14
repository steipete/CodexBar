import AppKit
import SwiftUI
import XCTest
@testable import CodexBar

@MainActor
final class HomebrewUpdateFailureProofTests: XCTestCase {
    func test_renderSyntheticHomebrewFailures() throws {
        guard let path = ProcessInfo.processInfo.environment["CODEXBAR_HOMEBREW_FAILURE_PROOF_DIR"] else {
            throw XCTSkip("Set CODEXBAR_HOMEBREW_FAILURE_PROOF_DIR to render synthetic Homebrew failures")
        }
        let directory = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let failure = HomebrewUpdateFailure(
            stage: .preparing,
            details: """
            Command failed (1): ==> Updating Homebrew…
            remote: Repository not found.
            Error: homebrew/homebrew-cask-versions does not exist!
            Updated 3 taps (steipete/tap, homebrew/core and homebrew/cask).

            CodexBar availability check:
            The requested version is not available.
            """ + String(repeating: "\nUnrelated Homebrew package output", count: 100))
        let scenes: [(name: String, width: CGFloat, scheme: ColorScheme, language: String)] = [
            ("light", 530, .light, "en"),
            ("dark", 530, .dark, "en"),
            ("narrow", 320, .light, "en"),
            ("chinese", 530, .light, "zh-Hans"),
            ("arabic", 530, .light, "ar"),
        ]
        for scene in scenes {
            try CodexBarLocalizationOverride.$appLanguage.withValue(scene.language) {
                let view = Form {
                    Section {
                        AboutHomebrewUpdateFailureView(
                            failure: failure,
                            manualUpdateCommand: "brew upgrade --cask steipete/tap/codexbar",
                            retry: {})
                    } header: {
                        Text(L("section_updates"))
                    }
                }
                .formStyle(.grouped)
                .environment(\.locale, Locale(identifier: scene.language))
                .environment(\.layoutDirection, scene.language == "ar" ? .rightToLeft : .leftToRight)
                .environment(\.colorScheme, scene.scheme)
                .frame(width: scene.width, height: 340)
                let hosting = NSHostingView(rootView: view)
                hosting.appearance = NSAppearance(named: scene.scheme == .dark ? .darkAqua : .aqua)
                let data = try XCTUnwrap(MenuLayoutScreenshotRenderTests.pngDataWithWindow(hosting: hosting))
                try data.write(
                    to: directory.appendingPathComponent("homebrew-failure-\(scene.name).png"),
                    options: .atomic)
            }
        }
    }
}
