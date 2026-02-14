import Foundation
import Testing
@testable import CodexBarCore

@Suite
struct ClaudeOAuthRefreshDispositionTests {
    @Test
    func invalidGrant_isTerminal() {
        let data = Data(#"{"error":"invalid_grant"}"#.utf8)
        #expect(ClaudeOAuthCredentialsStore
            .refreshFailureDispositionForTesting(statusCode: 400, data: data) == "terminalInvalidGrant")
    }

    @Test
    func otherError_isTransient() {
        let data = Data(#"{"error":"invalid_request"}"#.utf8)
        #expect(ClaudeOAuthCredentialsStore
            .refreshFailureDispositionForTesting(statusCode: 400, data: data) == "transientBackoff")
    }

    @Test
    func undecodableBody_isTransient() {
        let data = Data("not-json".utf8)
        #expect(ClaudeOAuthCredentialsStore
            .refreshFailureDispositionForTesting(statusCode: 401, data: data) == "transientBackoff")
        #expect(ClaudeOAuthCredentialsStore.extractOAuthErrorCodeForTesting(from: data) == nil)
    }

    @Test
    func nonAuthStatus_isNotHandled() {
        let data = Data(#"{"error":"invalid_grant"}"#.utf8)
        #expect(ClaudeOAuthCredentialsStore.refreshFailureDispositionForTesting(statusCode: 500, data: data) == nil)
    }
}
