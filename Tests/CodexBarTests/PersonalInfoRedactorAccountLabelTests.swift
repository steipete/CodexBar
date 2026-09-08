import Testing
@testable import CodexBar

struct PersonalInfoRedactorAccountLabelTests {
    @Test
    func `nil and empty labels stay empty`() {
        #expect(PersonalInfoRedactor.redactAccountLabel(nil, isEnabled: true) == "")
        #expect(PersonalInfoRedactor.redactAccountLabel(nil, isEnabled: false) == "")
        #expect(PersonalInfoRedactor.redactAccountLabel("  ", isEnabled: true) == "")
    }

    @Test
    func `user-chosen alias survives hidePersonalInfo`() {
        #expect(PersonalInfoRedactor.redactAccountLabel("personal", isEnabled: true) == "personal")
        #expect(PersonalInfoRedactor.redactAccountLabel("keepgroup", isEnabled: true) == "keepgroup")
        #expect(PersonalInfoRedactor.redactAccountLabel("eggyrooch-eggyroochgrop", isEnabled: true) == "eggyrooch-eggyroochgrop")
    }

    @Test
    func `slot fallback label survives hidePersonalInfo`() {
        #expect(PersonalInfoRedactor.redactAccountLabel("Account 3", isEnabled: true) == "Account 3")
    }

    @Test
    func `raw email is still fully redacted`() {
        #expect(PersonalInfoRedactor.redactAccountLabel("sunkie8@eggyroochgroup.com", isEnabled: true) == "")
        #expect(PersonalInfoRedactor.redactAccountLabel("sunkie8@eggyroochgroup.com", isEnabled: false) == "sunkie8@eggyroochgroup.com")
    }

    @Test
    func `email org label keeps the organization and drops the orphan separator`() {
        #expect(
            PersonalInfoRedactor.redactAccountLabel(
                "sunkie8@eggyroochgroup.com · keepgroup",
                isEnabled: true)
            == "keepgroup")
    }
}
