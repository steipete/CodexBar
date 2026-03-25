import Foundation
import Testing
@testable import CodexBarCore

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
            accessToken: "x",
            refreshToken: "y",
            expiresAt: Date(),
            email: nil,
            projectId: nil)
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
            accessToken: "a",
            refreshToken: "b",
            expiresAt: Date(),
            email: nil,
            projectId: nil)
        try storage.saveTokens(tokens)

        #expect(storage.hasTokens() == true)
    }

    @Test("loadTokens returns nil when nothing stored")
    func loadEmptyReturnsNil() {
        let storage = AntigravityOAuthStorage(serviceName: self.testServiceName)
        #expect(storage.loadTokens() == nil)
    }

    @Test("saveTokens keeps previous tokens when update fails")
    func saveTokensPreservesExistingTokensOnWriteFailure() throws {
        let existingTokens = AntigravityOAuthTokens(
            accessToken: "existing-access",
            refreshToken: "existing-refresh",
            expiresAt: Date().addingTimeInterval(3600),
            email: "existing@example.com",
            projectId: "existing-project")
        let replacementTokens = AntigravityOAuthTokens(
            accessToken: "replacement-access",
            refreshToken: "replacement-refresh",
            expiresAt: Date().addingTimeInterval(7200),
            email: "replacement@example.com",
            projectId: "replacement-project")

        final class FakeKeychainStore: @unchecked Sendable {
            var storedData: Data?
        }

        let fakeStore = FakeKeychainStore()
        fakeStore.storedData = try JSONEncoder().encode(existingTokens)

        let client = AntigravityOAuthStorage.KeychainClient(
            add: { _ in
                Issue.record("saveTokens should not attempt add when update fails for an existing item")
                return errSecDuplicateItem
            },
            update: { _, _ in
                errSecInteractionNotAllowed
            },
            copyMatchingData: { _ in
                guard let storedData = fakeStore.storedData else {
                    return (errSecItemNotFound, nil)
                }
                return (errSecSuccess, storedData)
            },
            delete: { _ in
                fakeStore.storedData = nil
                return errSecSuccess
            },
            exists: { _ in
                fakeStore.storedData != nil
            })

        let storage = AntigravityOAuthStorage(
            serviceName: self.testServiceName,
            keychainClient: client)

        #expect(throws: AntigravityOAuthError.self) {
            try storage.saveTokens(replacementTokens)
        }

        let loaded = try #require(storage.loadTokens())
        #expect(loaded.accessToken == existingTokens.accessToken)
        #expect(loaded.refreshToken == existingTokens.refreshToken)
        #expect(loaded.email == existingTokens.email)
        #expect(loaded.projectId == existingTokens.projectId)
    }
}

@Suite("AntigravityOAuthTokens Tests")
struct AntigravityOAuthTokensTests {
    @Test("isExpired returns true for past expiry")
    func expiredToken() {
        let token = AntigravityOAuthTokens(
            accessToken: "x",
            refreshToken: "y",
            expiresAt: Date().addingTimeInterval(-60),
            email: nil,
            projectId: nil)
        #expect(token.isExpired == true)
    }

    @Test("isExpired returns true within 5-minute buffer")
    func almostExpiredToken() {
        let token = AntigravityOAuthTokens(
            accessToken: "x",
            refreshToken: "y",
            expiresAt: Date().addingTimeInterval(4 * 60), // 4 minutes left
            email: nil,
            projectId: nil)
        #expect(token.isExpired == true)
    }

    @Test("isExpired returns false for valid token")
    func validToken() {
        let token = AntigravityOAuthTokens(
            accessToken: "x",
            refreshToken: "y",
            expiresAt: Date().addingTimeInterval(3600),
            email: nil,
            projectId: nil)
        #expect(token.isExpired == false)
    }
}
