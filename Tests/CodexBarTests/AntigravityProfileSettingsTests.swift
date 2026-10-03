import AppKit
import Foundation
import SwiftUI
import Testing
@testable import CodexBar
@testable import CodexBarCore

extension ProviderSettingsDescriptorTests {
    @Test
    func `antigravity profile directories default empty and persist add remove edits`() throws {
        let suite = "ProviderSettingsDescriptorTests-antigravity-profile-homes"
        let fixture = try self.makeSettingsFixture(suite: suite)
        let context = fixture.settingsContext(provider: .antigravity)
        let implementation = AntigravityProviderImplementation()
        let descriptor = try #require(implementation.settingsDirectoryLists(context: context).first)
        #expect(descriptor.title == "Additional Gemini profile homes")
        #expect(descriptor.binding.wrappedValue.isEmpty)
        #expect(fixture.settings.providerConfig(for: .antigravity)?.antigravityAdditionalProfileHomes == nil)
        let homes = ["/Synthetic/Profiles/Work/.gemini", "/Synthetic/Profiles/Personal/.gemini"]
        descriptor.binding.wrappedValue = homes
        let persisted = try #require(try testConfigStore(suiteName: suite, reset: false).load())
        #expect(persisted.providerConfig(for: .antigravity)?.antigravityAdditionalProfileHomes == homes)
        #expect(persisted.providerConfig(for: .gemini)?.antigravityAdditionalProfileHomes == nil)
        if let directory = ProcessInfo.processInfo.environment["CODEXBAR_ANTIGRAVITY_PROFILE_PROOF_DIR"] {
            let picker = try #require(implementation.settingsPickers(context: context).first)
            try Self.captureProfileSettings(picker: picker, directories: descriptor, directory: directory)
        }
        descriptor.binding.wrappedValue.removeFirst()
        #expect(fixture.settings.antigravityAdditionalProfileHomes == [homes[1]])
        descriptor.binding.wrappedValue = []
        let cleared = try #require(try testConfigStore(suiteName: suite, reset: false).load())
        #expect(cleared.providerConfig(for: .antigravity)?.antigravityAdditionalProfileHomes == [])
    }

    private static func captureProfileSettings(
        picker: ProviderSettingsPickerDescriptor,
        directories: ProviderSettingsDirectoryListDescriptor,
        directory: String) throws
    {
        let environment = ProcessInfo.processInfo.environment
        precondition(environment["CODEXBAR_SUPPRESS_TEST_KEYCHAIN_ACCESS"] == "1")
        precondition(environment["CODEXBAR_TEST_SESSION_FILE_ISOLATION"] == "1")
        precondition(environment[CodexCredentialFileAccess.isolationEnvironmentKey] == "1")
        let output = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for stage in ["before", "after"] {
            let hosting = NSHostingView(rootView: Form {
                Section("Antigravity · synthetic settings") {
                    ProviderSettingsPickerRowView(picker: picker)
                }
                if stage == "after" {
                    ProviderSettingsDirectoryListRowView(descriptor: directories)
                }
            }.formStyle(.grouped).frame(width: 740, height: 350).preferredColorScheme(.light))
            hosting.appearance = NSAppearance(named: .aqua)
            let png = try #require(MenuLayoutScreenshotRenderTests.pngDataWithWindow(hosting: hosting))
            try png.write(to: output.appendingPathComponent("profile-homes-\(stage).png"))
        }
    }
}
