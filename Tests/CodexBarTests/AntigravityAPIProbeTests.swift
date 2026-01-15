import CodexBarCore
import Testing

@Test("AntigravityAPIProbe initialization")
func antigravityAPIProbeInit() throws {
    let now = Date().timeIntervalSince1970
    let account = AntigravityAccount(
        email: "test@example.com",
        refreshToken: "test-refresh-token",
        projectId: "test-project",
        addedAt: now,
        lastUsed: now,
        rateLimitResetTimes: [:],
        coolingDownUntil: nil,
        cooldownReason: nil)

    let probe = AntigravityAPIProbe(timeout: 10.0, account: account)

    #expect(probe.timeout == 10.0)
    #expect(probe.account.email == "test@example.com")
}

@Test("AntigravityAccount refreshTokenWithProjectId format")
func antigravityAccountRefreshTokenFormat() throws {
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
