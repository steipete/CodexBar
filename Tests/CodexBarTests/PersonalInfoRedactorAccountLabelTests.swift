import Testing
@testable import CodexBar

struct PersonalInfoRedactorAccountLabelTests {
    private static func redacted(_ label: String?, hidePersonalInfo: Bool) -> String {
        PersonalInfoRedactor.redactAccountLabel(label, isEnabled: hidePersonalInfo)
    }

    @Test
    func `nil and empty labels stay empty`() {
        #expect(Self.redacted(nil, hidePersonalInfo: true).isEmpty)
        #expect(Self.redacted(nil, hidePersonalInfo: false).isEmpty)
        #expect(Self.redacted("  ", hidePersonalInfo: true).isEmpty)
    }

    @Test
    func `user-chosen alias survives hidePersonalInfo`() {
        #expect(Self.redacted("personal", hidePersonalInfo: true) == "personal")
        #expect(Self.redacted("keepgroup", hidePersonalInfo: true) == "keepgroup")
        #expect(Self.redacted("eggyrooch-eggyroochgrop", hidePersonalInfo: true) == "eggyrooch-eggyroochgrop")
    }

    @Test
    func `slot fallback label survives hidePersonalInfo`() {
        #expect(Self.redacted("Account 3", hidePersonalInfo: true) == "Account 3")
    }

    @Test
    func `raw email is still fully redacted`() {
        let email = "sunkie8@eggyroochgroup.com"
        #expect(Self.redacted(email, hidePersonalInfo: true).isEmpty)
        #expect(Self.redacted(email, hidePersonalInfo: false) == email)
    }

    @Test
    func `email org label keeps the organization and drops the orphan separator`() {
        let label = "sunkie8@eggyroochgroup.com · keepgroup"
        #expect(Self.redacted(label, hidePersonalInfo: true) == "keepgroup")
    }
}
