@testable import CodexBarCore
import Foundation
import Testing

@Suite("AntigravityOAuthStorage Tests")
struct AntigravityOAuthStorageTests {
    private let testServiceName = "com.codexbar.test.antigravity-oauth-\(UUID().uuidString)"

    @Test("Save and load round-trip")
    func saveAndLoadRoundTrip() throws {
        let storage = AntigravityOAuthStorage(serviceName: self.testServiceName)
        defer { storage.deleteTokens() }

        let tokens = AntigravityOAuthTokens(
            accessToken: "test-access",
            refreshToken: "test-refresh",
            expiresAt: Date().addingTimeInterval(3600),
            email: "test@example.com",
            projectId: "test-project-123")

        try storage.saveTokens(tokens)
        let loaded = storage.loadTokens()

        #expect(loaded != nil)
        #expect(loaded?.accessToken == "test-access")
        #expect(loaded?.refreshToken == "test-refresh")
        #expect(loaded?.email == "test@example.com")
        #expect(loaded?.projectId == "test-project-123")
    }

    @Test("Delete tokens")
    func deleteTokens() throws {
        let storage = AntigravityOAuthStorage(serviceName: self.testServiceName)
        let tokens = AntigravityOAuthTokens(
            accessToken: "x", refreshToken: "y",
            expiresAt: Date(), email: nil, projectId: nil)
        try storage.saveTokens(tokens)
        storage.deleteTokens()

        #expect(storage.loadTokens() == nil)
    }

    @Test("hasTokens returns correct state")
    func hasTokens() throws {
        let storage = AntigravityOAuthStorage(serviceName: self.testServiceName)
        defer { storage.deleteTokens() }

        #expect(storage.hasTokens() == false)

        let tokens = AntigravityOAuthTokens(
            accessToken: "a", refreshToken: "b",
            expiresAt: Date(), email: nil, projectId: nil)
        try storage.saveTokens(tokens)

        #expect(storage.hasTokens() == true)
    }

    @Test("loadTokens returns nil when nothing stored")
    func loadEmptyReturnsNil() {
        let storage = AntigravityOAuthStorage(serviceName: self.testServiceName)
        #expect(storage.loadTokens() == nil)
    }
}

@Suite("AntigravityOAuthTokens Tests")
struct AntigravityOAuthTokensTests {
    @Test("isExpired returns true for past expiry")
    func expiredToken() {
        let token = AntigravityOAuthTokens(
            accessToken: "x", refreshToken: "y",
            expiresAt: Date().addingTimeInterval(-60),
            email: nil, projectId: nil)
        #expect(token.isExpired == true)
    }

    @Test("isExpired returns true within 5-minute buffer")
    func almostExpiredToken() {
        let token = AntigravityOAuthTokens(
            accessToken: "x", refreshToken: "y",
            expiresAt: Date().addingTimeInterval(4 * 60), // 4 minutes left
            email: nil, projectId: nil)
        #expect(token.isExpired == true)
    }

    @Test("isExpired returns false for valid token")
    func validToken() {
        let token = AntigravityOAuthTokens(
            accessToken: "x", refreshToken: "y",
            expiresAt: Date().addingTimeInterval(3600),
            email: nil, projectId: nil)
        #expect(token.isExpired == false)
    }
}
