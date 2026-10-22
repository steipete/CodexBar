import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
struct TokenAccountEditingTests {
    @Test
    func `editing and reordering preserve identity metadata selection and persisted order`() throws {
        let settings = testSettingsStore(
            suiteName: "TokenAccountEditingTests",
            userDefaults: InMemoryUserDefaults(),
            config: testConfigWithAllProvidersDisabled())
        settings.addTokenAccount(
            provider: .claude,
            label: "First",
            token: "fixture-first",
            organizationID: "fixture-org",
            claudeConfigDirectory: "/fixture/claude")
        let first = try #require(settings.selectedTokenAccount(for: .claude))
        settings.addTokenAccount(provider: .claude, label: "Second", token: "fixture-second")
        let activeID = try #require(settings.selectedTokenAccount(for: .claude)).id

        settings.updateTokenAccount(provider: .claude, accountID: first.id, label: " Updated ", token: " replacement ")
        let edited = try #require(settings.tokenAccounts(for: .claude).first)
        #expect(edited.id == first.id)
        #expect(edited.label == "Updated")
        #expect(edited.token == "replacement")
        #expect(edited.addedAt == first.addedAt)
        #expect(edited.organizationID == first.organizationID)
        #expect(edited.claudeConfigDirectory == first.claudeConfigDirectory)
        #expect(settings.selectedTokenAccount(for: .claude)?.id == activeID)

        settings.moveTokenAccount(provider: .claude, accountID: activeID, to: 0)
        #expect(settings.tokenAccounts(for: .claude).map(\.id) == [activeID, first.id])
        #expect(settings.selectedTokenAccount(for: .claude)?.id == activeID)
        settings.moveTokenAccount(provider: .claude, accountID: activeID, to: 1)
        #expect(settings.tokenAccounts(for: .claude).map(\.id) == [first.id, activeID])
        #expect(settings.selectedTokenAccount(for: .claude)?.id == activeID)

        settings.updateTokenAccount(provider: .claude, accountID: activeID, label: "Active renamed")
        #expect(settings.selectedTokenAccount(for: .claude)?.token == "fixture-second")
        settings.moveTokenAccount(provider: .claude, accountID: activeID, to: 0)
        settings.reloadTokenAccounts()
        #expect(settings.tokenAccounts(for: .claude).map(\.id) == [activeID, first.id])
        #expect(settings.selectedTokenAccount(for: .claude)?.id == activeID)
        #expect(settings.selectedTokenAccount(for: .claude)?.label == "Active renamed")
        #expect(settings.tokenAccounts(for: .claude).last?.token == "replacement")
    }

    @Test
    func `editing a dormant account does not activate it`() throws {
        let settings = testSettingsStore(
            suiteName: "TokenAccountEditingTests-dormant",
            userDefaults: InMemoryUserDefaults(),
            config: testConfigWithAllProvidersDisabled())
        settings.addTokenAccount(
            provider: .cursor,
            label: "Saved",
            token: "WorkosCursorSessionToken=fixture-old")
        let account = try #require(settings.selectedTokenAccount(for: .cursor))
        settings.cursorCookieSource = .auto
        #expect(settings.effectiveSelectedTokenAccount(for: .cursor) == nil)

        settings.updateTokenAccount(
            provider: .cursor,
            accountID: account.id,
            label: "Renamed",
            token: "WorkosCursorSessionToken=fixture-new")

        #expect(settings.cursorCookieSource == .auto)
        #expect(settings.effectiveSelectedTokenAccount(for: .cursor) == nil)
        #expect(settings.selectedTokenAccount(for: .cursor)?.id == account.id)
        #expect(settings.selectedTokenAccount(for: .cursor)?.label == "Renamed")
        #expect(settings.selectedTokenAccount(for: .cursor)?.token == "WorkosCursorSessionToken=fixture-new")
        settings.setActiveTokenAccountIndex(0, for: .cursor)
        #expect(settings.cursorCookieSource == .manual)
        #expect(settings.effectiveSelectedTokenAccount(for: .cursor)?.id == account.id)
    }

    @Test
    func `invalid moves and blank replacement tokens leave accounts unchanged`() throws {
        let settings = testSettingsStore(
            suiteName: "TokenAccountEditingTests-invalid",
            userDefaults: InMemoryUserDefaults(),
            config: testConfigWithAllProvidersDisabled())
        settings.addTokenAccount(provider: .claude, label: "First", token: "fixture-first")
        let account = try #require(settings.selectedTokenAccount(for: .claude))
        settings.moveTokenAccount(provider: .claude, accountID: account.id, to: -1)
        settings.moveTokenAccount(provider: .claude, accountID: account.id, to: 1)
        settings.moveTokenAccount(provider: .claude, accountID: UUID(), to: 0)
        settings.updateTokenAccount(provider: .claude, accountID: account.id, label: "Discarded", token: " \n ")
        let retained = try #require(settings.selectedTokenAccount(for: .claude))
        #expect(settings.tokenAccounts(for: .claude).count == 1)
        #expect(retained.id == account.id)
        #expect(retained.label == account.label)
        #expect(retained.token == account.token)
    }
}
