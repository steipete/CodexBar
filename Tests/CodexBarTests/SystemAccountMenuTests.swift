import Testing
@testable import CodexBar
@testable import CodexBarCore

/// `.grok` stands in for any provider: the submenu builder is provider-agnostic.
struct SystemAccountMenuTests {
    private func submenu(_ menu: SystemAccountMenuEntries) -> (title: String, items: [MenuDescriptor.SubmenuItem])? {
        var entries: [ProviderMenuEntry] = []
        SystemAccountMenu.append(menu, provider: .grok, to: &entries)
        guard case let .submenu(title, _, items)? = entries.first else { return nil }
        return (title, items)
    }

    @Test
    func `system entry is checked and switchable entries are enabled`() throws {
        let menu = SystemAccountMenuEntries(cliName: "Grok CLI", isBlocked: false, entries: [
            .init(accountID: "2", title: "Account 2", isSystem: true, isSwitchable: false),
            .init(accountID: "7", title: "Account 7", isSystem: false, isSwitchable: true),
            .init(accountID: "9", title: "Account 9", isSystem: false, isSwitchable: false),
        ])
        let submenu = try #require(self.submenu(menu))
        #expect(submenu.title == "System Account")
        #expect(submenu.items.map(\.title) == ["Account 2", "Account 7", "Account 9"])
        #expect(submenu.items.map(\.isChecked) == [true, false, false])
        #expect(submenu.items.map(\.isEnabled) == [false, true, false])
        #expect(submenu.items[1].action == .requestSystemAccountSwitch(provider: .grok, accountID: "7"))
        #expect(submenu.items[0].action == nil)
        #expect(submenu.items[2].action == nil)
    }

    @Test
    func `blocked menus disable every entry`() throws {
        let menu = SystemAccountMenuEntries(cliName: "Grok CLI", isBlocked: true, entries: [
            .init(accountID: "2", title: "Account 2", isSystem: true, isSwitchable: false),
            .init(accountID: "7", title: "Account 7", isSystem: false, isSwitchable: true),
        ])
        #expect(try #require(self.submenu(menu)).items.allSatisfy { !$0.isEnabled })
    }

    @Test
    func `a lone system account adds no submenu`() {
        let menu = SystemAccountMenuEntries(cliName: "Grok CLI", isBlocked: false, entries: [
            .init(accountID: "2", title: "Account 2", isSystem: true, isSwitchable: false),
        ])
        #expect(self.submenu(menu) == nil)
    }
}
