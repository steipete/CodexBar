import AppKit
import Foundation
import SwiftUI
import Testing
@testable import CodexBar
@testable import CodexBarCore

extension ProviderSettingsDescriptorTests {
    @Test
    func `devin presentation follows store source label`() throws {
        let fixture = try self.makeSettingsFixture(suite: "ProviderSettingsDescriptorTests-devin-presentation")
        fixture.store.lastSourceLabels[.devin] = "web"
        let metadata = try #require(ProviderDescriptorRegistry.metadata[.devin])
        let context = fixture.presentationContext(provider: .devin, metadata: metadata)

        let detailLine = DevinProviderImplementation()
            .presentation(context: context)
            .detailLine(context)

        #expect(detailLine == "web")
    }

    @Test
    func `devin automatic auth explains Chromium browser support`() throws {
        let fixture = try self.makeSettingsFixture(suite: "ProviderSettingsDescriptorTests-devin-browsers")
        fixture.settings.devinCookieSource = .auto
        let picker = try #require(DevinProviderImplementation()
            .settingsPickers(context: fixture.settingsContext(provider: .devin)).first)

        let expected = "Automatically imports the app.devin.ai session from the Devin app or Chromium browsers."
        #expect(picker.subtitle == expected)
        if let directory = ProcessInfo.processInfo.environment["CODEXBAR_DEVIN_SETTINGS_PROOF_DIR"] {
            let output = URL(fileURLWithPath: directory, isDirectory: true)
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            for stage in ["before", "after"] {
                let displayed = ProviderSettingsPickerDescriptor(
                    id: picker.id,
                    title: picker.title,
                    subtitle: stage == "before"
                        ? "Automatically imports the app.devin.ai session from Chromium browsers." : picker.subtitle,
                    binding: .constant("auto"),
                    options: picker.options,
                    isVisible: nil,
                    onChange: nil)
                let hosting = NSHostingView(rootView: Form {
                    Section("Devin · synthetic settings") {
                        ProviderSettingsPickerRowView(picker: displayed)
                    }
                }
                .formStyle(.grouped)
                .frame(width: 580, height: 210)
                .environment(\.locale, Locale(identifier: "en"))
                .preferredColorScheme(.light))
                hosting.appearance = NSAppearance(named: .aqua)
                let png = try #require(MenuLayoutScreenshotRenderTests.pngDataWithWindow(hosting: hosting))
                try png.write(to: output.appendingPathComponent("devin-settings-\(stage).png"))
            }
        }
    }
}
