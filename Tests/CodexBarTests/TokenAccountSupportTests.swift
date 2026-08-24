import CodexBarCore
import Testing

struct TokenAccountSupportTests {
    private static func makeSupport(
        injection: TokenAccountInjection,
        migratesExistingAPIKeyOnFirstAccount: Bool? = nil) -> TokenAccountSupport
    {
        TokenAccountSupport(
            title: "Accounts",
            subtitle: "Test",
            placeholder: "token",
            injection: injection,
            requiresManualCookieSource: false,
            cookieName: nil,
            migratesExistingAPIKeyOnFirstAccount: migratesExistingAPIKeyOnFirstAccount)
    }

    @Test
    func `defaults to migrating an existing key for environment injected providers`() {
        let support = Self.makeSupport(injection: .environment(key: "TEST_API_KEY"))
        #expect(support.migratesExistingAPIKeyOnFirstAccount == true)
    }

    @Test
    func `defaults to not migrating for cookie header injected providers`() {
        let support = Self.makeSupport(injection: .cookieHeader)
        #expect(support.migratesExistingAPIKeyOnFirstAccount == false)
    }

    @Test
    func `an explicit override always wins over the injection-based default`() {
        let environmentOptedOut = Self.makeSupport(
            injection: .environment(key: "TEST_API_KEY"),
            migratesExistingAPIKeyOnFirstAccount: false)
        let cookieOptedIn = Self.makeSupport(
            injection: .cookieHeader,
            migratesExistingAPIKeyOnFirstAccount: true)

        #expect(environmentOptedOut.migratesExistingAPIKeyOnFirstAccount == false)
        #expect(cookieOptedIn.migratesExistingAPIKeyOnFirstAccount == true)
    }
}
