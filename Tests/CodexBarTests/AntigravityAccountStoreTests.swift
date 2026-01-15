import CodexBarCore
import Testing

@Test("AntigravityAccountData encoding and decoding")
func antigravityAccountDataEncoding() throws {
    let now = Date().timeIntervalSince1970

    let account1 = AntigravityAccount(
        email: "user1@example.com",
        refreshToken: "refresh-token-1",
        projectId: "project-1",
        addedAt: now,
        lastUsed: now,
        rateLimitResetTimes: [:],
        coolingDownUntil: nil,
        cooldownReason: nil)

    let account2 = AntigravityAccount(
        email: "user2@example.com",
        refreshToken: "refresh-token-2",
        projectId: "project-2",
        addedAt: now,
        lastUsed: now,
        rateLimitResetTimes: ["claude": now + 3600],
        coolingDownUntil: nil,
        cooldownReason: nil)

    let store = AntigravityAccountData(
        version: 3,
        accounts: [account1, account2],
        activeIndex: 0,
        activeIndexByFamily: [:])

    let encoder = JSONEncoder()
    let data = try encoder.encode(store)

    let decoder = JSONDecoder()
    let decoded = try decoder.decode(AntigravityAccountData.self, from: data)

    #expect(decoded.version == 3)
    #expect(decoded.accounts.count == 2)
    #expect(decoded.accounts[0].email == "user1@example.com")
    #expect(decoded.accounts[1].email == "user2@example.com")
    #expect(decoded.accounts[1].rateLimitResetTimes["claude"] != nil)
}

@Test("AntigravityAccount refreshTokenWithProjectId format")
func antigravityAccountTokenFormat() throws {
    let now = Date().timeIntervalSince1970

    let accountWithProjectId = AntigravityAccount(
        email: "user@example.com",
        refreshToken: "my-refresh-token",
        projectId: "project-123",
        addedAt: now,
        lastUsed: now,
        rateLimitResetTimes: [:],
        coolingDownUntil: nil,
        cooldownReason: nil)

    let accountWithoutProjectId = AntigravityAccount(
        email: "user@example.com",
        refreshToken: "my-refresh-token",
        projectId: nil,
        addedAt: now,
        lastUsed: now,
        rateLimitResetTimes: [:],
        coolingDownUntil: nil,
        cooldownReason: nil)

    #expect(accountWithProjectId.refreshTokenWithProjectId == "my-refresh-token|project-123")
    #expect(accountWithoutProjectId.refreshTokenWithProjectId == "my-refresh-token|")
}

@Test("AntigravityAccount displayName")
func antigravityAccountDisplayName() throws {
    let now = Date().timeIntervalSince1970

    let account = AntigravityAccount(
        email: "test@example.com",
        refreshToken: "token",
        projectId: nil,
        addedAt: now,
        lastUsed: now,
        rateLimitResetTimes: [:],
        coolingDownUntil: nil,
        cooldownReason: nil)

    #expect(account.displayName == "test@example.com")
}
