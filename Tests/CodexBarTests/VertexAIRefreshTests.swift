import Foundation
import Testing
@testable import CodexBarCore

struct VertexAIRefreshTests {
    @Test
    func `shared form encoder preserves explicit field order`() throws {
        let body = FormURLEncoding.body([("second", "2"), ("first", "a+b"), ("empty", "")])
        #expect(body == Data("second=2&first=a%2Bb&empty=".utf8))
        #expect(try FormBodyTestSupport.decode(body) == ["second": "2", "first": "a+b", "empty": ""])
    }

    @Test
    func `shared form encoder preserves keys and empty values`() throws {
        let fields = ["key+&=% /東京": "value+&=% /東京", "empty": ""]
        #expect(try FormBodyTestSupport.decode(FormURLEncoding.body(fields)) == fields)
        #expect(FormURLEncoding.body([:]).isEmpty)
    }

    @Test
    func `refresh form preserves opaque credential values`() async throws {
        let credentials = Self.credentials(refreshToken: "fixture+refresh&extra=value% /東京")
        let transport = Self.transport(body: #"{"access_token":"new-access","expires_in":600}"#)

        _ = try await VertexAITokenRefresher.refresh(credentials, session: transport)

        let requests = await transport.requests()
        #expect(requests.count == 1)
        let request = try #require(requests.first)
        #expect(request.url?.absoluteString == "https://oauth2.googleapis.com/token")
        #expect(request.httpMethod == "POST")
        #expect(request.timeoutInterval == 30)
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/x-www-form-urlencoded")
        let body = try #require(request.httpBody)
        #expect(try FormBodyTestSupport.decode(body) == [
            "client_id": credentials.clientId,
            "client_secret": credentials.clientSecret,
            "refresh_token": credentials.refreshToken,
            "grant_type": "refresh_token",
        ])
    }

    @Test(arguments: [
        "{}",
        #"{"expires_in":600}"#,
        #"{"access_token":null}"#,
        #"{"access_token":42}"#,
        #"{"access_token":""}"#,
        #"{"access_token":" \t\n "}"#,
    ])
    func `successful status without usable access token fails refresh`(body: String) async {
        let transport = Self.transport(body: body)
        let error = await #expect(throws: VertexAITokenRefresher.RefreshError.self) {
            try await VertexAITokenRefresher.refresh(Self.credentials(), session: transport)
        }
        guard case .invalidResponse = error else {
            Issue.record("Expected invalid refresh response")
            return
        }
    }

    @Test
    func `missing refresh token fails before transport use`() async {
        let transport = Self.transport(body: #"{"access_token":"new-access"}"#)
        await #expect(throws: VertexAITokenRefresher.RefreshError.self) {
            try await VertexAITokenRefresher.refresh(Self.credentials(refreshToken: ""), session: transport)
        }
        #expect(await transport.requests().isEmpty)
    }

    @Test
    func `valid refresh preserves credential ownership and default expiry`() async throws {
        let credentials = Self.credentials()
        let transport = Self.transport(body: #"{"access_token":" new-access "}"#)
        let started = Date()

        let refreshed = try await VertexAITokenRefresher.refresh(credentials, session: transport)

        #expect(refreshed.accessToken == " new-access ")
        #expect(refreshed.refreshToken == credentials.refreshToken)
        #expect(refreshed.clientId == credentials.clientId)
        #expect(refreshed.clientSecret == credentials.clientSecret)
        #expect(refreshed.projectId == credentials.projectId)
        #expect(refreshed.email == credentials.email)
        let expiry = try #require(refreshed.expiryDate)
        #expect(expiry >= started.addingTimeInterval(3600))
        #expect(expiry <= Date().addingTimeInterval(3600))
    }

    @Test(arguments: [false, true])
    func `refresh preserves explicit expiry and display identity fallback`(validIdentity: Bool) async throws {
        let payload = Data(#"{"email":"updated@example.test"}"#.utf8).base64EncodedString()
        let identity = validIdentity ? "fixture.\(payload).fixture" : "malformed"
        let body = """
        {"access_token":"new-access","expires_in":600,"id_token":"\(identity)"}
        """
        let started = Date()
        let refreshed = try await VertexAITokenRefresher.refresh(
            Self.credentials(), session: Self.transport(body: body))

        #expect(refreshed.email == (validIdentity ? "updated@example.test" : "fixture@example.test"))
        let expiry = try #require(refreshed.expiryDate)
        #expect(expiry >= started.addingTimeInterval(600))
        #expect(expiry <= Date().addingTimeInterval(600))
    }

    @Test(arguments: [
        (400, #"{"error":"invalid_grant"}"#, "expired"),
        (401, #"{"error":"unauthorized_client"}"#, "revoked"),
        (400, "{}", "expired"),
        (400, #"{"error":"other"}"#, "invalidResponse"),
        (503, "{}", "invalidResponse"),
        (200, "not JSON", "invalidResponse"),
    ])
    func `refresh preserves response error categories`(statusCode: Int, body: String, expectedKind: String) async {
        let error = await #expect(throws: VertexAITokenRefresher.RefreshError.self) {
            try await VertexAITokenRefresher.refresh(
                Self.credentials(), session: Self.transport(body: body, statusCode: statusCode))
        }
        guard let error else { return }
        let kind = switch error {
        case .expired: "expired"
        case .revoked: "revoked"
        case .invalidResponse: "invalidResponse"
        case .networkError: "networkError"
        }
        #expect(kind == expectedKind)
    }

    @Test
    func `refresh retains underlying transport errors`() async {
        let transport = ProviderHTTPTransportStub { _ in throw URLError(.notConnectedToInternet) }
        let error = await #expect(throws: VertexAITokenRefresher.RefreshError.self) {
            try await VertexAITokenRefresher.refresh(Self.credentials(), session: transport)
        }
        guard case let .networkError(underlying) = error else {
            Issue.record("Expected network refresh error")
            return
        }
        #expect((underlying as? URLError)?.code == .notConnectedToInternet)
    }

    private static func credentials(refreshToken: String = "fixture-refresh") -> VertexAIOAuthCredentials {
        VertexAIOAuthCredentials(
            accessToken: "expired-access",
            refreshToken: refreshToken,
            clientId: "fixture+client&name=id",
            clientSecret: "fixture+secret&name=value",
            projectId: "fixture-project",
            email: "fixture@example.test",
            expiryDate: Date(timeIntervalSince1970: 0))
    }

    private static func transport(body: String, statusCode: Int = 200) -> ProviderHTTPTransportStub {
        ProviderHTTPTransportStub { request in
            let requestURL = try #require(request.url)
            let response = try #require(HTTPURLResponse(
                url: requestURL, statusCode: statusCode, httpVersion: nil, headerFields: nil))
            return (Data(body.utf8), response)
        }
    }
}
