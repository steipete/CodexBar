import CodexBarCore
import Testing

@Test("AntigravityAccountStore encoding and decoding")
func antigravityAccountStoreEncoding() throws {
    let now = Date().timeIntervalSince1970

    let account1 = AntigravityAccountStore.AntigravityAccount(
        email: "user1@example.com",
        refreshToken: "refresh-token-1",
        projectId: "project-1",
        addedAt: now,
        lastUsed: now,
        rateLimitResetTimes: [:],
        coolingDownUntil: nil,
        cooldownReason: nil
    )

    let account2 = AntigravityAccountStore.AntigravityAccount(
        email: "user2@example.com",
        refreshToken: "refresh-token-2",
        projectId: "project-2",
        addedAt: now,
        lastUsed: now,
        rateLimitResetTimes: ["claude": now + 3600],
        coolingDownUntil: nil,
        cooldownReason: nil
    )

    let store = AntigravityAccountStore(
        version: 3,
        accounts: [account1, account2],
        activeIndex: 0,
        activeIndexByFamily: [:]
    )

    let encoder = JSONEncoder()
    let data = try encoder.encode(store)

    let decoder = JSONDecoder()
    let decoded = try decoder.decode(AntigravityAccountStore.self, from: data)

    #expect(decoded.version == 3)
    #expect(decoded.accounts.count == 2)
    #expect(decoded.accounts[0].email == "user1@example.com")
    #expect(decoded.accounts[1].email == "user2@example.com")
    #expect(decoded.accounts[1].rateLimitResetTimes["claude"] != nil)
}

@Test("AntigravityAccount refreshTokenWithProjectId format")
func antigravityAccountTokenFormat() throws {
    let now = Date().timeIntervalSince1970

    let accountWithProjectId = AntigravityAccountStore.AntigravityAccount(
        email: "user@example.com",
        refreshToken: "my-refresh-token",
        projectId: "project-123",
        addedAt: now,
        lastUsed: now,
        rateLimitResetTimes: [:],
        coolingDownUntil: nil,
        cooldownReason: nil
    )

    let accountWithoutProjectId = AntigravityAccountStore.AntigravityAccount(
        email: "user@example.com",
        refreshToken: "my-refresh-token",
        projectId: nil,
        addedAt: now,
        lastUsed: now,
        rateLimitResetTimes: [:],
        coolingDownUntil: nil,
        cooldownReason: nil
    )

    #expect(accountWithProjectId.refreshTokenWithProjectId == "my-refresh-token|project-123")
    #expect(accountWithoutProjectId.refreshTokenWithProjectId == "my-refresh-token|")
}

@Test("AntigravityAccount displayName")
func antigravityAccountDisplayName() throws {
    let now = Date().timeIntervalSince1970

    let account = AntigravityAccountStore.AntigravityAccount(
        email: "test@example.com",
        refreshToken: "token",
        projectId: nil,
        addedAt: now,
        lastUsed: now,
        rateLimitResetTimes: [:],
        coolingDownUntil: nil,
        cooldownReason: nil
    )

    #expect(account.displayName == "test@example.com")
}