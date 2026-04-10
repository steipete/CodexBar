import CodexBarCore
import Testing

struct CodexIdentityResolverTests {
    @Test
    func `resolver prefers provider account over email`() {
        let identity = CodexIdentityResolver.resolve(
            accountId: "account-123",
            email: "Person@example.com")

        #expect(identity == .providerAccount(id: "account-123"))
    }

    @Test
    func `resolver falls back to normalized email when provider account missing`() {
        let identity = CodexIdentityResolver.resolve(
            accountId: nil,
            email: " Person@example.com ")

        #expect(identity == .emailOnly(normalizedEmail: "person@example.com"))
    }

    @Test
    func `resolver returns unresolved when account data missing`() {
        let identity = CodexIdentityResolver.resolve(accountId: nil, email: nil)

        #expect(identity == .unresolved)
    }

    @Test
    func `provider account does not equal email fallback even when email matches`() {
        let providerAccount = CodexIdentityResolver.resolve(
            accountId: "account-123",
            email: "person@example.com")
        let emailOnly = CodexIdentityResolver.resolve(
            accountId: nil,
            email: "person@example.com")

        #expect(providerAccount == .providerAccount(id: "account-123"))
        #expect(emailOnly == .emailOnly(normalizedEmail: "person@example.com"))
        #expect(providerAccount != emailOnly)
    }
}
