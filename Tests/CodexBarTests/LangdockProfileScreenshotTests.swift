import AppKit
import SweetCookieKit
import SwiftUI
import Testing
@testable import CodexBar
@testable import CodexBarCore

@MainActor
struct LangdockProfileScreenshotTests {
    @Test
    func `render selected profile settings with synthetic data when requested`() throws {
        guard let path = ProcessInfo.processInfo.environment["CODEXBAR_LANGDOCK_PROOF_DIR"] else { return }
        let fixture = try ProviderSettingsDescriptorTests().makeSettingsFixture(suite: #function)
        let implementation = PluginCookieProviderImplementation(spec: LangdockProviderDescriptor.spec)
        let context = fixture.settingsContext(provider: .langdock)
        let browsers = try #require(LangdockProviderDescriptor.descriptor.settingsSection.selectedProfileBrowsers)
        let output = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for profile in LangdockPluginTests.profiles {
            fixture.settings.updateProviderConfig(provider: .langdock) {
                $0.browserID = profile.browserID
                $0.browserProfileID = profile.profileID
            }
            let browserPicker = implementation.browserPicker(browsers: browsers, context: context)
            let picker = implementation.browserProfilePicker(
                browser: profile.browserID,
                context: context,
                profiles: [.init(
                    id: profile.profileID,
                    name: profile.browserID == "safari" ? "synthetic-personal" : "Personal (synthetic)")])
            let view = NSHostingView(rootView: VStack(alignment: .leading, spacing: 12) {
                Text("Langdock · synthetic settings").font(.headline).padding(.horizontal, 20)
                Form {
                    Section("Connection") {
                        ProviderSettingsPickerRowView(picker: browserPicker)
                        ProviderSettingsPickerRowView(picker: picker)
                    }
                }.formStyle(.grouped)
            }.padding(.vertical, 16).frame(width: 620, height: 280).background(Color(nsColor: .windowBackgroundColor)))
            view.frame = NSRect(x: 0, y: 0, width: 620, height: 280)
            let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: .aqua)
            window.contentView = view
            defer { window.contentView = nil }
            window.layoutIfNeeded()
            view.layoutSubtreeIfNeeded()
            let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try #require(bitmap.representation(using: .png, properties: [:]))
                .write(to: output.appendingPathComponent("langdock-settings-\(profile.browserID).png"))
        }
    }
}
