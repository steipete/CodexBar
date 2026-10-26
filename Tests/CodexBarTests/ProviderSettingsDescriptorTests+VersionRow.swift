import Foundation
import SwiftUI
import Testing
@testable import CodexBar
@testable import CodexBarCore

/// Version-row regressions for web-only providers that have no version detector (#4769).
///
/// These providers used to leave `showsVersionInSettings` at its default, so the Settings card
/// rendered `Version: not detected` for a detection that never ran.
@MainActor
extension ProviderSettingsDescriptorTests {
    @Test
    func `cursor hides the unsupported version row while keeping its web source`() throws {
        let fixture = try self.makeSettingsFixture(suite: "ProviderSettingsDescriptorTests-cursor-version-row")
        let metadata = try #require(ProviderDescriptorRegistry.metadata[.cursor])
        let context = fixture.presentationContext(provider: .cursor, metadata: metadata)
        let implementation = try #require(ProviderCatalog.implementation(for: .cursor))

        let presentation = implementation.presentation(context: context)

        // Web-only source with versionDetector: nil — a Version row can only ever read "not detected".
        #expect(presentation.detailLine(context) == "web")
        #expect(presentation.showsVersionInSettings == false)
        #expect(ProviderDetailView<EmptyView>.versionText(provider: .cursor, store: fixture.store) == nil)
    }

    @Test
    func `raycast hides the unsupported version row while keeping its web source`() throws {
        let fixture = try self.makeSettingsFixture(suite: "ProviderSettingsDescriptorTests-raycast-version-row")
        let metadata = try #require(ProviderDescriptorRegistry.metadata[.raycast])
        let context = fixture.presentationContext(provider: .raycast, metadata: metadata)
        let implementation = try #require(ProviderCatalog.implementation(for: .raycast))

        let presentation = implementation.presentation(context: context)

        // Bundled web-cookie plugin with versionDetector: nil — a Version row can only read "not detected".
        #expect(presentation.detailLine(context) == "web")
        #expect(presentation.showsVersionInSettings == false)
        #expect(ProviderDetailView<EmptyView>.versionText(provider: .raycast, store: fixture.store) == nil)
    }

    @Test
    func `cursor account controls remain visible for manual cookies or saved accounts`() throws {
        let fixture = try self.makeSettingsFixture(suite: "ProviderSettingsDescriptorTests-cursor-accounts")
        let context = fixture.settingsContext(provider: .cursor)
        let implementation = CursorProviderImplementation()
        let support = try #require(TokenAccountSupportCatalog.support(for: .cursor))
        fixture.settings.cursorCookieSource = .auto
        #expect(!implementation.tokenAccountsVisibility(context: context, support: support))
        fixture.settings.cursorCookieSource = .manual
        #expect(implementation.tokenAccountsVisibility(context: context, support: support))
        fixture.settings.addTokenAccount(provider: .cursor, label: "Fixture", token: "fixture-cookie")
        fixture.settings.cursorCookieSource = .auto
        #expect(implementation.tokenAccountsVisibility(context: context, support: support))
    }

    @Test
    func `version-capable providers keep the shared version row`() throws {
        let fixture = try self.makeSettingsFixture(suite: "ProviderSettingsDescriptorTests-version-row-control")
        fixture.store.versions[.codex] = "1.2.3"

        #expect(ProviderDetailView<EmptyView>.versionText(provider: .codex, store: fixture.store) == "1.2.3")
        // A version-capable provider with no resolved version keeps the existing "not detected" row.
        #expect(
            ProviderDetailView<EmptyView>.versionText(provider: .gemini, store: fixture.store)
                == L("not detected"))
    }
}
