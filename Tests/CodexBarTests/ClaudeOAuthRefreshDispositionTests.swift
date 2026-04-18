import Foundation
import Testing
@testable import CodexBarCore

struct ClaudeOAuthRefreshDispositionTests {
    @Test
    func `invalid grant is terminal`() {
        let data = Data(#"{"error":"invalid_grant"}"#.utf8)
        #expect(ClaudeOAuthCredentialsStore
            .refreshFailureDispositionForTesting(statusCode: 400, data: data) == "terminalInvalidGrant")
    }

    @Test
    func `other error is transient`() {
        let data = Data(#"{"error":"invalid_request"}"#.utf8)
        #expect(ClaudeOAuthCredentialsStore
            .refreshFailureDispositionForTesting(statusCode: 400, data: data) == "transientBackoff")
    }

    @Test
    func `undecodable body is transient`() {
        let data = Data("not-json".utf8)
        #expect(ClaudeOAuthCredentialsStore
            .refreshFailureDispositionForTesting(statusCode: 401, data: data) == "transientBackoff")
        #expect(ClaudeOAuthCredentialsStore.extractOAuthErrorCodeForTesting(from: data) == nil)
    }

    @Test
    func `non auth status is not handled`() {
        let data = Data(#"{"error":"invalid_grant"}"#.utf8)
        #expect(ClaudeOAuthCredentialsStore.refreshFailureDispositionForTesting(statusCode: 500, data: data) == nil)
    }
}
