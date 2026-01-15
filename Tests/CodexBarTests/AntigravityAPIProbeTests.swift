import CodexBarCore
import Testing

@Test("AntigravityAPIProbe initialization")
func antigravityAPIProbeInit() throws {
    let now = Date().timeIntervalSince1970
    let account = AntigravityAccountStore.AntigravityAccount(
        email: "test@example.com",
        refreshToken: "test-refresh-token",
        projectId: "test-project",
        addedAt: now,
        lastUsed: now,
        rateLimitResetTimes: [:],
        coolingDownUntil: nil,
        cooldownReason: nil
    )

    let probe = AntigravityAPIProbe(timeout: 10.0, account: account)

    #expect(probe.timeout == 10.0)
    #expect(probe.account.email == "test@example.com")
}

@Test("AntigravityAPIProbe request body construction")
func antigravityAPIProbeRequestBody() throws {
    let requestBody = type(of: AntigravityAPIProbe).method(named: "defaultRequestBody")?()

    #expect(requestBody != nil)
    if let body = requestBody {
        let dict = body as? [String: Any]
        #expect(dict != nil)
        if let dict = dict {
            let metadata = dict["metadata"] as? [String: Any]
            #expect(metadata != nil)
        }
    }
}