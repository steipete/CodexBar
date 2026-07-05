import Foundation
import Testing
@testable import CodexBarCore

#if os(macOS)
struct DeepSeekLocalStorageImporterTests {
    @Test
    func `accepts auth_token jwt with email and sub`() {
        let jwt = Self.sampleJWT(payload: [
            "sub": "3157",
            "email": "user@example.com",
            "name": "User",
            "iat": 1_700_000_000,
            "exp": Int(Date().timeIntervalSince1970) + 86400,
        ])
        let bearer = "Bearer \(jwt)"
        #expect(DeepSeekLocalStorageImporter.looksLikeDeepSeekJWT(bearer))
        #expect(DeepSeekLocalStorageImporter.authorizationHeader(from: ["auth_token": jwt]) == bearer)
    }

    @Test
    func `rejects firebase jwt`() {
        let jwt = Self.sampleJWT(payload: [
            "aud": "writefull",
            "user_id": "abc",
            "firebase": ["sign_in_provider": "custom"],
        ])
        #expect(!DeepSeekLocalStorageImporter.looksLikeDeepSeekJWT("Bearer \(jwt)"))
    }

    @Test
    func `rejects expired jwt`() {
        let jwt = Self.sampleJWT(payload: [
            "sub": "3157",
            "email": "user@example.com",
            "exp": 1_700_000_000,
        ])
        #expect(!DeepSeekLocalStorageImporter.looksLikeDeepSeekJWT("Bearer \(jwt)"))
    }

    @Test
    func `rejects websocket jwt`() {
        let jwt = Self.sampleJWT(payload: [
            "type": "websocket",
            "userId": "123",
            "email": "user@example.com",
        ])
        #expect(!DeepSeekLocalStorageImporter.looksLikeDeepSeekJWT("Bearer \(jwt)"))
    }

    @Test
    func `rejects openai jwt with email`() {
        let jwt = Self.sampleJWT(payload: [
            "email": "user@example.com",
            "iss": "https://auth.openai.com",
            "auth_provider": "apple",
            "sub": "apple|001907.example",
            "exp": Int(Date().timeIntervalSince1970) + 86400,
        ])
        #expect(!DeepSeekLocalStorageImporter.looksLikeDeepSeekJWT("Bearer \(jwt)"))
    }

    @Test
    func `rejects unrelated jwt with userId and openid`() {
        let jwt = Self.sampleJWT(payload: [
            "openid": "o0Y2126BisWHqFq8QXhmdbi1XpEA",
            "userId": "6a316731edfed9da6add1d07",
            "role": "user",
            "iat": 1_781_622_577,
            "exp": Int(Date().timeIntervalSince1970) + 86400,
        ])
        #expect(!DeepSeekLocalStorageImporter.looksLikeDeepSeekJWT("Bearer \(jwt)"))
    }

    @Test
    func `rejects jwt without exp claim`() {
        let jwt = Self.sampleJWT(payload: [
            "sub": "00849f1a-7b02-44ae-9137-493c9591c234",
        ])
        #expect(!DeepSeekLocalStorageImporter.looksLikeDeepSeekJWT("Bearer \(jwt)"))
    }

    @Test
    func `sanitized drops expired authorization header`() {
        let jwt = Self.sampleJWT(payload: [
            "sub": "3157",
            "email": "user@example.com",
            "exp": 1_700_000_000,
        ])
        let session = DeepSeekPlatformSession(
            cookieHeader: "ds_session_id=abc",
            authorizationHeader: "Bearer \(jwt)")
        let sanitized = DeepSeekLocalStorageImporter.sanitized(session)
        #expect(sanitized.authorizationHeader == nil)
        #expect(sanitized.cookieHeader == "ds_session_id=abc")
    }

    @Test
    func `accepts userToken json wrapper`() throws {
        let raw = #"{"value":"9fvx9QNC2ZY7pAiB7Me3YQCF/NmIj9lO6yRu3tjT2tGkEoVGcpVsOkAzZ1v6TIGr","__version":"0"}"#
        let bearer = try #require(DeepSeekLocalStorageImporter.bearer(from: raw))
        #expect(DeepSeekLocalStorageImporter.looksLikeDeepSeekAuthorizationHeader(bearer))
    }

    @Test
    func `storage payload round trips through session parser`() throws {
        let session = DeepSeekPlatformSession(
            cookieHeader: "ds_session_id=abc",
            authorizationHeader: "Bearer eyJ.test.token")
        let payload = session.storagePayload
        let parsed = try #require(DeepSeekCookieHeader.session(from: payload))
        #expect(parsed.cookieHeader == "ds_session_id=abc")
        #expect(parsed.authorizationHeader == "Bearer eyJ.test.token")
    }

    private static func sampleJWT(payload: [String: Any]) -> String {
        let header = Data(#"{"alg":"HS256","typ":"JWT"}"#.utf8).base64EncodedString()
            .replacingOccurrences(of: "=", with: "")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
        let bodyData = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data()
        let body = bodyData.base64EncodedString()
            .replacingOccurrences(of: "=", with: "")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
        return "\(header).\(body).signature"
    }
}
#endif
