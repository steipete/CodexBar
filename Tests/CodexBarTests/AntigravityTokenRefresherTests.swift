import Foundation
import Testing
@testable import CodexBarCore

@Suite("AntigravityTokenRefresher Tests")
struct AntigravityTokenRefresherTests {
    @Test("buildRefreshRequest builds correct URL and method")
    func refreshRequestURL() {
        let request = AntigravityTokenRefresher.buildRefreshRequest(refreshToken: "test-refresh-token")

        #expect(request.url?.absoluteString == "https://oauth2.googleapis.com/token")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/x-www-form-urlencoded")
    }

    @Test("buildRefreshRequest includes required parameters in body")
    func refreshRequestBody() throws {
        let request = AntigravityTokenRefresher.buildRefreshRequest(refreshToken: "my-refresh-token")

        let body = try #require(request.httpBody)
        let bodyString = try #require(String(data: body, encoding: .utf8))

        #expect(bodyString.contains("grant_type=refresh_token"))
        #expect(bodyString.contains("refresh_token=my-refresh-token"))
        #expect(bodyString.contains("client_id="))
        #expect(bodyString.contains("client_secret="))
    }

    @Test("buildRefreshRequest percent-encodes reserved refresh-token characters")
    func refreshRequestBodyEncodesReservedCharacters() throws {
        let request = AntigravityTokenRefresher.buildRefreshRequest(refreshToken: "refresh+token&with=reserved")

        let body = try #require(request.httpBody)
        let bodyString = try #require(String(data: body, encoding: .utf8))

        #expect(bodyString.contains("refresh_token=refresh%2Btoken%26with%3Dreserved"))
        #expect(!bodyString.contains("refresh_token=refresh+token&with=reserved"))
    }
}
