import CodexBarCore
import Foundation
import Testing

@Suite(.serialized)
struct AntigravityRemoteUsageFetcherTests {
    @Test
    func `remote fetch maps cloud code models into antigravity usage`() async throws {
        let env = try GeminiTestEnvironment()
        defer { env.cleanup() }
        try env.writeAntigravityCredentials(
            accessToken: "token",
            refreshToken: nil,
            expiry: Date().addingTimeInterval(3600),
            idToken: GeminiAPITestHelpers.makeIDToken(email: "user@company.com", hostedDomain: "company.com"),
            email: "user@company.com")

        let dataLoader = GeminiAPITestHelpers.dataLoader { request in
            guard let url = request.url, let host = url.host else {
                throw URLError(.badURL)
            }

            switch host {
            case "cloudcode-pa.googleapis.com":
                if url.path == "/v1internal:loadCodeAssist" {
                    return GeminiAPITestHelpers.response(
                        url: url.absoluteString,
                        status: 200,
                        body: GeminiAPITestHelpers.jsonData([
                            "currentTier": ["id": "standard-tier", "name": "standard"],
                            "cloudaicompanionProject": "managed-project-123",
                        ]))
                }
                if url.path == "/v1internal:fetchAvailableModels" {
                    let body = try #require(request.httpBody)
                    let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
                    #expect(json["project"] as? String == "managed-project-123")
                    return GeminiAPITestHelpers.response(
                        url: url.absoluteString,
                        status: 200,
                        body: Self.availableModelsResponse())
                }
                return GeminiAPITestHelpers.response(url: url.absoluteString, status: 404, body: Data())
            default:
                return GeminiAPITestHelpers.response(url: url.absoluteString, status: 404, body: Data())
            }
        }

        let fetcher = AntigravityRemoteUsageFetcher(
            timeout: 1,
            homeDirectory: env.homeURL.path,
            dataLoader: dataLoader)
        let snapshot = try await fetcher.fetch()

        #expect(snapshot.accountEmail == "user@company.com")
        #expect(snapshot.accountPlan == "Paid")

        let usage = try snapshot.toUsageSnapshot()
        #expect(usage.primary?.remainingPercent.rounded() == 50)
        #expect(usage.secondary?.remainingPercent.rounded() == 80)
        #expect(usage.tertiary?.remainingPercent.rounded() == 20)
    }

    @Test
    func `remote fetch refreshes expired shared google token`() async throws {
        let env = try GeminiTestEnvironment()
        defer { env.cleanup() }
        try env.writeAntigravityCredentials(
            accessToken: "old-token",
            refreshToken: "refresh-token",
            expiry: Date().addingTimeInterval(-3600),
            idToken: GeminiAPITestHelpers.makeIDToken(email: "stale@example.com"),
            email: "stale@example.com",
            clientID: "test-client-id",
            clientSecret: "test-client-secret")

        let dataLoader = GeminiAPITestHelpers.dataLoader { request in
            guard let url = request.url, let host = url.host else {
                throw URLError(.badURL)
            }

            switch host {
            case "oauth2.googleapis.com":
                return GeminiAPITestHelpers.response(
                    url: url.absoluteString,
                    status: 200,
                    body: GeminiAPITestHelpers.jsonData([
                        "access_token": "new-token",
                        "expires_in": 3600,
                        "id_token": GeminiAPITestHelpers.makeIDToken(email: "refreshed@example.com"),
                    ]))
            case "cloudcode-pa.googleapis.com":
                let auth = request.value(forHTTPHeaderField: "Authorization")
                #expect(auth == "Bearer new-token")
                if url.path == "/v1internal:loadCodeAssist" {
                    return GeminiAPITestHelpers.response(
                        url: url.absoluteString,
                        status: 200,
                        body: GeminiAPITestHelpers.jsonData([
                            "currentTier": ["id": "standard-tier", "name": "standard"],
                            "cloudaicompanionProject": "managed-project-123",
                        ]))
                }
                if url.path == "/v1internal:fetchAvailableModels" {
                    return GeminiAPITestHelpers.response(
                        url: url.absoluteString,
                        status: 200,
                        body: Self.availableModelsResponse())
                }
                return GeminiAPITestHelpers.response(url: url.absoluteString, status: 404, body: Data())
            default:
                return GeminiAPITestHelpers.response(url: url.absoluteString, status: 404, body: Data())
            }
        }

        let fetcher = AntigravityRemoteUsageFetcher(
            timeout: 2,
            homeDirectory: env.homeURL.path,
            dataLoader: dataLoader)
        let snapshot = try await fetcher.fetch()

        let updated = try env.readAntigravityCredentials()
        #expect(updated["access_token"] as? String == "new-token")
        #expect(snapshot.accountEmail == "refreshed@example.com")
    }

    @Test
    func `remote fetch refreshes nearly expired shared google token`() async throws {
        let env = try GeminiTestEnvironment()
        defer { env.cleanup() }
        try env.writeAntigravityCredentials(
            accessToken: "old-token",
            refreshToken: "refresh-token",
            expiry: Date().addingTimeInterval(5),
            idToken: GeminiAPITestHelpers.makeIDToken(email: "stale@example.com"),
            email: "stale@example.com",
            clientID: "test-client-id",
            clientSecret: "test-client-secret")

        let dataLoader = GeminiAPITestHelpers.dataLoader { request in
            guard let url = request.url, let host = url.host else {
                throw URLError(.badURL)
            }

            switch host {
            case "oauth2.googleapis.com":
                return GeminiAPITestHelpers.response(
                    url: url.absoluteString,
                    status: 200,
                    body: GeminiAPITestHelpers.jsonData([
                        "access_token": "new-token",
                        "expires_in": 3600,
                        "id_token": GeminiAPITestHelpers.makeIDToken(email: "refreshed@example.com"),
                    ]))
            case "cloudcode-pa.googleapis.com":
                #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer new-token")
                if url.path == "/v1internal:loadCodeAssist" {
                    return GeminiAPITestHelpers.response(
                        url: url.absoluteString,
                        status: 200,
                        body: GeminiAPITestHelpers.jsonData([
                            "currentTier": ["id": "standard-tier", "name": "standard"],
                            "cloudaicompanionProject": "managed-project-123",
                        ]))
                }
                if url.path == "/v1internal:fetchAvailableModels" {
                    return GeminiAPITestHelpers.response(
                        url: url.absoluteString,
                        status: 200,
                        body: Self.availableModelsResponse())
                }
                return GeminiAPITestHelpers.response(url: url.absoluteString, status: 404, body: Data())
            default:
                return GeminiAPITestHelpers.response(url: url.absoluteString, status: 404, body: Data())
            }
        }

        let fetcher = AntigravityRemoteUsageFetcher(
            timeout: 2,
            homeDirectory: env.homeURL.path,
            dataLoader: dataLoader)
        let snapshot = try await fetcher.fetch()

        let updated = try env.readAntigravityCredentials()
        #expect(updated["access_token"] as? String == "new-token")
        #expect(snapshot.accountEmail == "refreshed@example.com")
    }

    @Test
    func `remote refresh requires configured oauth client`() async throws {
        let env = try GeminiTestEnvironment()
        defer { env.cleanup() }
        try env.writeAntigravityCredentials(
            accessToken: "old-token",
            refreshToken: "refresh-token",
            expiry: Date().addingTimeInterval(-3600),
            idToken: GeminiAPITestHelpers.makeIDToken(email: "user@example.com"),
            email: "user@example.com")

        let fetcher = AntigravityRemoteUsageFetcher(
            timeout: 1,
            homeDirectory: env.homeURL.path,
            dataLoader: GeminiAPITestHelpers.dataLoader { _ in
                throw URLError(.badServerResponse)
            },
            oauthClientResolver: { nil })

        do {
            _ = try await fetcher.fetch()
            #expect(Bool(false), "Expected missing OAuth client configuration error")
        } catch let error as AntigravityRemoteFetchError {
            guard case let .apiError(message) = error else {
                #expect(Bool(false), "Unexpected Antigravity error: \(error)")
                return
            }
            #expect(message.contains("ANTIGRAVITY_OAUTH_CLIENT_ID"))
        } catch {
            #expect(Bool(false), "Unexpected error: \(error)")
        }
    }

    @Test
    func `remote fetch onboards project before fetching models`() async throws {
        let env = try GeminiTestEnvironment()
        defer { env.cleanup() }
        try env.writeAntigravityCredentials(
            accessToken: "token",
            refreshToken: nil,
            expiry: Date().addingTimeInterval(3600),
            idToken: GeminiAPITestHelpers.makeIDToken(email: "user@example.com"),
            email: "user@example.com")

        final class Recorder: @unchecked Sendable {
            private let lock = NSLock()
            private var projects: [String] = []

            func append(_ value: String) {
                self.lock.lock()
                self.projects.append(value)
                self.lock.unlock()
            }

            func last() -> String? {
                self.lock.lock()
                defer { self.lock.unlock() }
                return self.projects.last
            }
        }

        let recorder = Recorder()
        let dataLoader = GeminiAPITestHelpers.dataLoader { request in
            guard let url = request.url, let host = url.host else {
                throw URLError(.badURL)
            }

            switch host {
            case "cloudcode-pa.googleapis.com":
                if url.path == "/v1internal:loadCodeAssist" {
                    return GeminiAPITestHelpers.response(
                        url: url.absoluteString,
                        status: 200,
                        body: GeminiAPITestHelpers.jsonData([
                            "currentTier": ["id": "standard-tier", "name": "standard"],
                            "allowedTiers": [["id": "standard-tier", "isDefault": true]],
                        ]))
                }
                if url.path == "/v1internal:onboardUser" {
                    return GeminiAPITestHelpers.response(
                        url: url.absoluteString,
                        status: 200,
                        body: GeminiAPITestHelpers.jsonData([
                            "response": [
                                "cloudaicompanionProject": [
                                    "id": "onboarded-project-456",
                                ],
                            ],
                        ]))
                }
                if url.path == "/v1internal:fetchAvailableModels" {
                    let body = try #require(request.httpBody)
                    let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
                    if let project = json["project"] as? String {
                        recorder.append(project)
                    }
                    return GeminiAPITestHelpers.response(
                        url: url.absoluteString,
                        status: 200,
                        body: Self.availableModelsResponse())
                }
                return GeminiAPITestHelpers.response(url: url.absoluteString, status: 404, body: Data())
            default:
                return GeminiAPITestHelpers.response(url: url.absoluteString, status: 404, body: Data())
            }
        }

        let fetcher = AntigravityRemoteUsageFetcher(
            timeout: 1,
            homeDirectory: env.homeURL.path,
            dataLoader: dataLoader)
        _ = try await fetcher.fetch()

        #expect(recorder.last() == "onboarded-project-456")
    }

    @Test
    func `remote fetch falls back to retrieve user quota when model endpoint is forbidden`() async throws {
        let env = try GeminiTestEnvironment()
        defer { env.cleanup() }
        try env.writeAntigravityCredentials(
            accessToken: "token",
            refreshToken: nil,
            expiry: Date().addingTimeInterval(3600),
            idToken: GeminiAPITestHelpers.makeIDToken(email: "user@example.com"),
            email: "user@example.com")

        final class Counter: @unchecked Sendable {
            private let lock = NSLock()
            private var value = 0

            func increment() {
                self.lock.lock()
                self.value += 1
                self.lock.unlock()
            }

            func get() -> Int {
                self.lock.lock()
                defer { self.lock.unlock() }
                return self.value
            }
        }

        let quotaCalls = Counter()
        let dataLoader = GeminiAPITestHelpers.dataLoader { request in
            guard let url = request.url, let host = url.host else {
                throw URLError(.badURL)
            }

            switch host {
            case "cloudcode-pa.googleapis.com":
                if url.path == "/v1internal:loadCodeAssist" {
                    return GeminiAPITestHelpers.response(
                        url: url.absoluteString,
                        status: 200,
                        body: GeminiAPITestHelpers.jsonData([
                            "currentTier": ["id": "standard-tier", "name": "standard"],
                            "cloudaicompanionProject": "managed-project-123",
                        ]))
                }
                if url.path == "/v1internal:fetchAvailableModels" {
                    return GeminiAPITestHelpers.response(
                        url: url.absoluteString,
                        status: 403,
                        body: GeminiAPITestHelpers.jsonData([
                            "error": [
                                "code": 403,
                                "message": "The caller does not have permission",
                                "status": "PERMISSION_DENIED",
                            ],
                        ]))
                }
                if url.path == "/v1internal:retrieveUserQuota" {
                    quotaCalls.increment()
                    return GeminiAPITestHelpers.response(
                        url: url.absoluteString,
                        status: 200,
                        body: GeminiAPITestHelpers.sampleQuotaResponse())
                }
                return GeminiAPITestHelpers.response(url: url.absoluteString, status: 404, body: Data())
            default:
                return GeminiAPITestHelpers.response(url: url.absoluteString, status: 404, body: Data())
            }
        }

        let fetcher = AntigravityRemoteUsageFetcher(
            timeout: 1,
            homeDirectory: env.homeURL.path,
            dataLoader: dataLoader)
        let snapshot = try await fetcher.fetch()
        let usage = try snapshot.toUsageSnapshot()

        #expect(quotaCalls.get() == 1)
        #expect(usage.secondary?.remainingPercent == 60.0)
        #expect(usage.tertiary?.remainingPercent == 90.0)
    }

    @Test
    func `antigravity descriptor advertises oauth mode`() {
        let descriptor = ProviderDescriptorRegistry.descriptor(for: .antigravity)
        #expect(descriptor.fetchPlan.sourceModes == [.auto, .cli, .oauth])
    }

    @Test
    func `remote fetch returns identity when both remote quota endpoints are forbidden`() async throws {
        let env = try GeminiTestEnvironment()
        defer { env.cleanup() }
        try env.writeAntigravityCredentials(
            accessToken: "token",
            refreshToken: nil,
            expiry: Date().addingTimeInterval(3600),
            idToken: GeminiAPITestHelpers.makeIDToken(email: "user@example.com"),
            email: "user@example.com")

        let dataLoader = GeminiAPITestHelpers.dataLoader { request in
            guard let url = request.url, let host = url.host else {
                throw URLError(.badURL)
            }

            switch host {
            case "cloudcode-pa.googleapis.com":
                if url.path == "/v1internal:loadCodeAssist" {
                    return GeminiAPITestHelpers.response(
                        url: url.absoluteString,
                        status: 200,
                        body: GeminiAPITestHelpers.jsonData([
                            "currentTier": ["id": "standard-tier", "name": "standard"],
                            "cloudaicompanionProject": "managed-project-123",
                        ]))
                }
                if url.path == "/v1internal:fetchAvailableModels" || url.path == "/v1internal:retrieveUserQuota" {
                    return GeminiAPITestHelpers.response(
                        url: url.absoluteString,
                        status: 403,
                        body: GeminiAPITestHelpers.jsonData([
                            "error": [
                                "code": 403,
                                "message": "The caller does not have permission",
                                "status": "PERMISSION_DENIED",
                            ],
                        ]))
                }
                return GeminiAPITestHelpers.response(url: url.absoluteString, status: 404, body: Data())
            default:
                return GeminiAPITestHelpers.response(url: url.absoluteString, status: 404, body: Data())
            }
        }

        let snapshot = try await AntigravityRemoteUsageFetcher(
            timeout: 1,
            homeDirectory: env.homeURL.path,
            dataLoader: dataLoader)
            .fetch()

        #expect(snapshot.modelQuotas.isEmpty)
        #expect(snapshot.accountEmail == "user@example.com")
        #expect(snapshot.accountPlan == "Paid")
    }

    @Test
    func `remote fetch ignores gemini credentials when antigravity auth is missing`() async throws {
        let env = try GeminiTestEnvironment()
        defer { env.cleanup() }
        try env.writeCredentials(
            accessToken: "gemini-token",
            refreshToken: nil,
            expiry: Date().addingTimeInterval(3600),
            idToken: GeminiAPITestHelpers.makeIDToken(email: "gemini@example.com"))

        let fetcher = AntigravityRemoteUsageFetcher(
            timeout: 1,
            homeDirectory: env.homeURL.path,
            dataLoader: GeminiAPITestHelpers.dataLoader { _ in
                throw URLError(.badServerResponse)
            })

        await #expect(throws: AntigravityRemoteFetchError.notLoggedIn) {
            try await fetcher.fetch()
        }
    }

    @Test
    func `remote fetch prefers stored project id from antigravity credentials`() async throws {
        let env = try GeminiTestEnvironment()
        defer { env.cleanup() }
        try env.writeAntigravityCredentials(
            accessToken: "token",
            refreshToken: nil,
            expiry: Date().addingTimeInterval(3600),
            idToken: GeminiAPITestHelpers.makeIDToken(email: "user@example.com"),
            email: "user@example.com",
            projectID: "stored-project-789")

        final class Recorder: @unchecked Sendable {
            private let lock = NSLock()
            private var projects: [String] = []

            func append(_ value: String) {
                self.lock.lock()
                self.projects.append(value)
                self.lock.unlock()
            }

            func last() -> String? {
                self.lock.lock()
                defer { self.lock.unlock() }
                return self.projects.last
            }
        }

        let recorder = Recorder()
        let dataLoader = GeminiAPITestHelpers.dataLoader { request in
            guard let url = request.url, let host = url.host else {
                throw URLError(.badURL)
            }

            switch host {
            case "cloudcode-pa.googleapis.com":
                if url.path == "/v1internal:loadCodeAssist" {
                    return GeminiAPITestHelpers.response(
                        url: url.absoluteString,
                        status: 200,
                        body: GeminiAPITestHelpers.jsonData([
                            "currentTier": ["id": "standard-tier", "name": "standard"],
                        ]))
                }
                if url.path == "/v1internal:fetchAvailableModels" {
                    let body = try #require(request.httpBody)
                    let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
                    if let project = json["project"] as? String {
                        recorder.append(project)
                    }
                    return GeminiAPITestHelpers.response(
                        url: url.absoluteString,
                        status: 200,
                        body: Self.availableModelsResponse())
                }
                return GeminiAPITestHelpers.response(url: url.absoluteString, status: 404, body: Data())
            default:
                return GeminiAPITestHelpers.response(url: url.absoluteString, status: 404, body: Data())
            }
        }

        _ = try await AntigravityRemoteUsageFetcher(
            timeout: 1,
            homeDirectory: env.homeURL.path,
            dataLoader: dataLoader)
            .fetch()

        #expect(recorder.last() == "stored-project-789")
    }

    private static func availableModelsResponse() -> Data {
        GeminiAPITestHelpers.jsonData([
            "models": [
                "claude-sonnet-4": [
                    "displayName": "Claude Sonnet 4",
                    "quotaInfo": [
                        "remainingFraction": 0.5,
                        "resetTime": "2025-01-01T00:00:00Z",
                    ],
                ],
                "gemini-3-pro-low": [
                    "displayName": "Gemini 3 Pro Low",
                    "quotaInfo": [
                        "remainingFraction": 0.8,
                        "resetTime": "2025-01-01T00:00:00Z",
                    ],
                ],
                "gemini-3-flash": [
                    "displayName": "Gemini 3 Flash",
                    "quotaInfo": [
                        "remainingFraction": 0.2,
                        "resetTime": "2025-01-01T00:00:00Z",
                    ],
                ],
                "gemini-3-flash-lite": [
                    "displayName": "Gemini 3 Flash Lite",
                    "quotaInfo": [
                        "remainingFraction": 0.7,
                        "resetTime": "2025-01-01T00:00:00Z",
                    ],
                ],
            ],
        ])
    }
}
