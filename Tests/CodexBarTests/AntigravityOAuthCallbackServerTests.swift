import Darwin
import Foundation
import Testing
@testable import CodexBar

@Suite(.serialized)
struct AntigravityOAuthCallbackServerTests {
    @Test
    func `retryable invalid callback does not consume listener`() async throws {
        let dataForRequest: @Sendable (URLRequest) async throws -> (Data, URLResponse) = { request in
            guard let url = request.url else { throw URLError(.badURL) }

            switch url.host {
            case "oauth2.googleapis.com":
                return Self.makeResponse(
                    url: url,
                    body: """
                    {
                        "access_token": "access-123",
                        "refresh_token": "refresh-123",
                        "expires_in": 3600
                    }
                    """,
                    statusCode: 200,
                    contentType: "application/json")
            case "www.googleapis.com":
                return Self.makeResponse(
                    url: url,
                    body: #"{"email":"user@example.com"}"#,
                    statusCode: 200,
                    contentType: "application/json")
            default:
                throw URLError(.unsupportedURL)
            }
        }

        let tokens = try await AntigravityOAuthCallbackServer.$dataForRequestOverride.withValue(dataForRequest) {
            let port = try self.makeAvailablePort()
            let task = Task {
                try await AntigravityOAuthCallbackServer.waitForCallback(
                    port: port,
                    expectedState: "expected-state",
                    timeout: 5)
            }

            let invalidBody = try await self.fetchLocalBody(
                path: "http://127.0.0.1:\(port)/callback?code=bad-code&state=wrong-state")
            #expect(invalidBody.contains("could not sign you in"))
            #expect(!invalidBody.contains("Signed in to CodexBar"))

            let validBody = try await self.fetchLocalBody(
                path: "http://127.0.0.1:\(port)/callback?code=good-code&state=expected-state")
            #expect(validBody.contains("Signed in to CodexBar"))

            return try await task.value
        }

        #expect(tokens.accessToken == "access-123")
        #expect(tokens.refreshToken == "refresh-123")
        #expect(tokens.email == "user@example.com")
    }

    private func fetchLocalBody(path: String) async throws -> String {
        let url = try #require(URL(string: path))
        var lastError: Error?

        for attempt in 0..<20 {
            do {
                let (data, response) = try await URLSession.shared.data(from: url)
                let http = try #require(response as? HTTPURLResponse)
                #expect(http.statusCode == 200)
                return try #require(String(bytes: data, encoding: .utf8))
            } catch {
                lastError = error
                if attempt < 19 {
                    try await Task.sleep(for: .milliseconds(50))
                    continue
                }
            }
        }

        throw lastError ?? URLError(.cannotConnectToHost)
    }

    private func makeAvailablePort() throws -> UInt16 {
        let socketFD = socket(AF_INET, SOCK_STREAM, 0)
        guard socketFD >= 0 else {
            throw POSIXError(.EIO)
        }
        defer { close(socketFD) }

        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(0)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")

        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                bind(socketFD, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            throw POSIXError(.EADDRINUSE)
        }

        var boundAddress = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &boundAddress) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                getsockname(socketFD, sockaddrPointer, &length)
            }
        }
        guard nameResult == 0 else {
            throw POSIXError(.EIO)
        }

        return CFSwapInt16BigToHost(boundAddress.sin_port)
    }

    private static func makeResponse(
        url: URL,
        body: String,
        statusCode: Int,
        contentType: String) -> (Data, URLResponse)
    {
        let response = HTTPURLResponse(
            url: url,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: ["Content-Type": contentType])!
        return (Data(body.utf8), response)
    }
}
