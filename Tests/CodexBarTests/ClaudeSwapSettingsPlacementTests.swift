import AppKit
import Foundation
import SwiftUI
import Testing
@testable import CodexBar
@testable import CodexBarCore

@MainActor
@Suite(.serialized)
struct ClaudeSwapSettingsPlacementTests {
    @Test
    func `claude swap path belongs to its toggle instead of the standalone fields`() throws {
        let fixture = try ProviderSettingsDescriptorTests()
            .makeSettingsFixture(suite: "ProviderSettingsDescriptorTests-claude-swap-path")
        let context = fixture.settingsContext(provider: .claude)
        let implementation = ClaudeProviderImplementation()
        let toggle = try #require(implementation.settingsToggles(context: context).first {
            $0.id == "claude-swap-accounts"
        })
        let fields = toggle.inlineFields
        #expect(fields.map(\.id) == ["claude-swap-executable-path"])
        let field = try #require(fields.first)
        #expect(!toggle.binding.wrappedValue)
        #expect(field.subtitle == "Path to the cswap executable (github.com/realiti4/claude-swap).")
        #expect(field.kind == .plain)
        toggle.binding.wrappedValue = true
        field.binding.wrappedValue = "/synthetic/bin/cswap"
        #expect(fixture.settings.claudeSwapExecutablePath == "/synthetic/bin/cswap")
        let otherFieldsAreEmpty = implementation.settingsToggles(context: context)
            .filter { $0.id != toggle.id }.allSatisfy(\.inlineFields.isEmpty)
        #expect(otherFieldsAreEmpty)
        #expect(!implementation.settingsFields(context: context).contains { $0.id == "claude-swap-executable-path" })
    }

    @Test
    func `source picker appears with the integration and switches to tcr`() throws {
        let fixture = try ProviderSettingsDescriptorTests()
            .makeSettingsFixture(suite: "ProviderSettingsDescriptorTests-claude-swap-source")
        let context = fixture.settingsContext(provider: .claude)
        let implementation = ClaudeProviderImplementation()
        let picker = try #require(implementation.settingsPickers(context: context).first {
            $0.id == "claude-swap-source"
        })
        #expect(picker.options.map(\.id) == ["claude-swap", "tcr"])
        #expect(picker.isVisible?() == false)
        #expect(picker.binding.wrappedValue == "claude-swap")

        fixture.settings.claudeSwapEnabled = true
        #expect(picker.isVisible?() == true)
        picker.binding.wrappedValue = "tcr"
        #expect(fixture.settings.claudeSwapSource == .tcr)
        #expect(fixture.settings.configSnapshot.providerConfig(for: .claude)?.claudeSwapSource == "tcr")

        // Choosing claude-swap again removes the key rather than writing the default.
        picker.binding.wrappedValue = "claude-swap"
        #expect(fixture.settings.configSnapshot.providerConfig(for: .claude)?.claudeSwapSource == nil)
    }

    @Test
    func `claude swap setup text is unchanged when claude swap is the source`() throws {
        let fixture = try ProviderSettingsDescriptorTests()
            .makeSettingsFixture(suite: "ProviderSettingsDescriptorTests-claude-swap-setup-text")
        fixture.settings.claudeSwapEnabled = true
        let context = fixture.settingsContext(provider: .claude)
        let toggle = try #require(ClaudeProviderImplementation().settingsToggles(context: context).first {
            $0.id == "claude-swap-accounts"
        })
        let field = try #require(toggle.inlineFields.first)

        #expect(fixture.settings.claudeSwapSource == .claudeSwap)
        #expect(toggle.title == "Read accounts from claude-swap")
        #expect(toggle.subtitle == "Shows usage and lets you switch accounts through `cswap`. " +
            "Credentials stay managed by claude-swap; CodexBar never reads them.")
        #expect(field.title == "claude-swap executable")
        #expect(field.subtitle == "Path to the cswap executable (github.com/realiti4/claude-swap).")
        #expect(field.placeholder == "~/.local/bin/cswap")
        #expect(toggle.statusText?() == "Set the cswap executable path below.")
    }

    @Test
    func `tcr source describes tcr and its read only accounts in the setup text`() throws {
        let fixture = try ProviderSettingsDescriptorTests()
            .makeSettingsFixture(suite: "ProviderSettingsDescriptorTests-tcr-setup-text")
        fixture.settings.claudeSwapEnabled = true
        fixture.settings.claudeSwapSource = .tcr
        let context = fixture.settingsContext(provider: .claude)
        let toggle = try #require(ClaudeProviderImplementation().settingsToggles(context: context).first {
            $0.id == "claude-swap-accounts"
        })
        let field = try #require(toggle.inlineFields.first)

        #expect(toggle.subtitle == "Shows usage from `tcr`; it does not switch accounts, because tcr picks " +
            "the account for each request. Credentials stay managed by tcr; CodexBar never reads them.")
        #expect(field.title == "tcr executable")
        #expect(field.subtitle == "Path to the tcr executable (github.com/dhkts1/teamclaude-rs).")
        #expect(field.placeholder == "/Applications/TcrBar.app/Contents/MacOS/tcr")
        #expect(toggle.statusText?() == "Set the tcr executable path below.")
        let setupText = [toggle.subtitle, field.title, field.subtitle, field.placeholder ?? "", toggle.statusText?()]
        #expect(!setupText.contains { $0?.contains("cswap") == true })
    }

    @Test
    func `render synthetic claude swap settings proof`() throws {
        guard let directory = ProcessInfo.processInfo.environment["CODEXBAR_CLAUDE_PRESENTATION_PROOF_DIR"] else {
            return
        }
        let fixture = try ProviderSettingsDescriptorTests()
            .makeSettingsFixture(suite: "ProviderSettingsDescriptorTests-claude-swap-proof")
        fixture.settings.claudeSwapEnabled = true
        let context = fixture.settingsContext(provider: .claude)
        let implementation = ClaudeProviderImplementation()
        let fields = implementation.settingsFields(context: context).filter { $0.id == "claude-swap-executable-path" }
        let toggles = implementation.settingsToggles(context: context).filter { $0.id == "claude-swap-accounts" }
        let hosting = NSHostingView(rootView: Form {
            ForEach(fields) { ProviderSettingsFieldRowView(field: $0) }
            Section("Options") {
                ForEach(toggles) { ProviderSettingsToggleRowView(toggle: $0) }
            }
        }
        .formStyle(.grouped)
        .frame(width: 600, height: 360)
        .environment(\.locale, Locale(identifier: "en"))
        .preferredColorScheme(.light))
        hosting.appearance = NSAppearance(named: .aqua)
        let png = try #require(MenuLayoutScreenshotRenderTests.pngDataWithWindow(hosting: hosting))
        try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("settings.png"))
    }
}
