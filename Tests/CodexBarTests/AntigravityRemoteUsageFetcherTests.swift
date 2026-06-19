import CodexBarCore
import Foundation
import Testing

private actor AntigravityCredentialUpdateCapture {
    private var captured: [AntigravityOAuthCredentials] = []

    func append(_ credentials: AntigravityOAuthCredentials) {
        self.captured.append(credentials)
    }

    func values() -> [AntigravityOAuthCredentials] {
        self.captured
    }
}

@Suite(.serialized)
// swiftlint:disable:next type_body_length
struct AntigravityRemoteUsageFetcherTests {
    @Test
    func `antigravity supports token accounts for quick account switching`() {
        let support = TokenAccountSupportCatalog.support(for: .antigravity)

        #expect(support?.title == "Google accounts")
        #expect(support?.requiresManualCookieSource == false)
        #expect(TokenAccountSupportCatalog.envOverride(
            for: .antigravity,
            token: "serialized-credentials")?[AntigravityOAuthCredentialsStore.environmentCredentialsKey] ==
            "serialized-credentials")
    }

    @Test
    func `oauth credentials round trip through token account value`() throws {
        let credentials = AntigravityOAuthCredentials(
            accessToken: "access-token",
            refreshToken: "refresh-token",
            expiryDate: Date(timeIntervalSince1970: 1_700_000_000),
            idToken: GeminiAPITestHelpers.makeIDToken(email: "user@example.com"),
            email: "user@example.com",
            projectID: "project-123",
            clientID: "client-id",
            clientSecret: "client-secret")

        let token = try AntigravityOAuthCredentialsStore.tokenAccountValue(for: credentials)
        let decoded = try #require(AntigravityOAuthCredentialsStore.credentials(fromTokenAccountValue: token))

        #expect(decoded == credentials)
    }

    @Test
    func `remote fetch uses selected token account credentials before shared credentials`() async throws {
        let env = try GeminiTestEnvironment()
        defer { env.cleanup() }
        try env.writeAntigravityCredentials(
            accessToken: "shared-token",
            refreshToken: nil,
            expiry: Date().addingTimeInterval(3600),
            idToken: GeminiAPITestHelpers.makeIDToken(email: "shared@example.com"),
            email: "shared@example.com")
        let selectedCredentials = AntigravityOAuthCredentials(
            accessToken: "selected-token",
            refreshToken: nil,
            expiryDate: Date().addingTimeInterval(3600),
            idToken: GeminiAPITestHelpers.makeIDToken(email: "selected@example.com"),
            email: "selected@example.com",
            projectID: nil,
            clientID: nil,
            clientSecret: nil)
        let token = try AntigravityOAuthCredentialsStore.tokenAccountValue(for: selectedCredentials)

        let dataLoader = GeminiAPITestHelpers.dataLoader { request in
            guard let url = request.url, let host = url.host else {
                throw URLError(.badURL)
            }
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer selected-token")

            switch host {
            case "cloudcode-pa.googleapis.com":
                if url.path == "/v1internal:loadCodeAssist" {
                    return GeminiAPITestHelpers.response(
                        url: url.absoluteString,
                        status: 200,
                        body: GeminiAPITestHelpers.jsonData([
                            "currentTier": ["id": "free-tier", "name": "free"],
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
            timeout: 1,
            homeDirectory: env.homeURL.path,
            environment: [AntigravityOAuthCredentialsStore.environmentCredentialsKey: token],
            dataLoader: dataLoader)
        let snapshot = try await fetcher.fetch()

        #expect(snapshot.accountEmail == "selected@example.com")
    }

    @Test
    func `remote fetch refreshes selected token account without mutating shared credentials`() async throws {
        let env = try GeminiTestEnvironment()
        defer { env.cleanup() }
        try env.writeAntigravityCredentials(
            accessToken: "shared-token",
            refreshToken: "shared-refresh",
            expiry: Date().addingTimeInterval(3600),
            idToken: GeminiAPITestHelpers.makeIDToken(email: "shared@example.com"),
            email: "shared@example.com",
            clientID: "shared-client-id",
            clientSecret: "shared-client-secret")
        let selectedCredentials = AntigravityOAuthCredentials(
            accessToken: "selected-old-token",
            refreshToken: "selected-refresh",
            expiryDate: Date().addingTimeInterval(-3600),
            idToken: GeminiAPITestHelpers.makeIDToken(email: "selected-old@example.com"),
            email: "selected-old@example.com",
            projectID: nil,
            clientID: "selected-client-id",
            clientSecret: "selected-client-secret")
        let token = try AntigravityOAuthCredentialsStore.tokenAccountValue(for: selectedCredentials)
        let updateCapture = AntigravityCredentialUpdateCapture()

        let dataLoader = GeminiAPITestHelpers.dataLoader { request in
            guard let url = request.url, let host = url.host else {
                throw URLError(.badURL)
            }

            switch host {
            case "oauth2.googleapis.com":
                let body = String(data: request.httpBody ?? Data(), encoding: .utf8) ?? ""
                #expect(body.contains("client_id=selected-client-id"))
                #expect(body.contains("refresh_token=selected-refresh"))
                return GeminiAPITestHelpers.response(
                    url: url.absoluteString,
                    status: 200,
                    body: GeminiAPITestHelpers.jsonData([
                        "access_token": "selected-new-token",
                        "expires_in": 3600,
                        "id_token": GeminiAPITestHelpers.makeIDToken(email: "selected-new@example.com"),
                    ]))
            case "cloudcode-pa.googleapis.com":
                #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer selected-new-token")
                if url.path == "/v1internal:loadCodeAssist" {
                    return GeminiAPITestHelpers.response(
                        url: url.absoluteString,
                        status: 200,
                        body: GeminiAPITestHelpers.jsonData([
                            "currentTier": ["id": "free-tier", "name": "free"],
                            "cloudaicompanionProject": "selected-project-123",
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
            timeout: 1,
            homeDirectory: env.homeURL.path,
            environment: [AntigravityOAuthCredentialsStore.environmentCredentialsKey: token],
            dataLoader: dataLoader,
            credentialsUpdateHandler: { credentials in
                await updateCapture.append(credentials)
            })
        let snapshot = try await fetcher.fetch()
        let shared = try env.readAntigravityCredentials()
        let updatedCredentials = await updateCapture.values()

        #expect(snapshot.accountEmail == "selected-new@example.com")
        #expect(shared["access_token"] as? String == "shared-token")
        #expect(shared["email"] as? String == "shared@example.com")
        #expect(updatedCredentials.last?.accessToken == "selected-new-token")
        #expect(updatedCredentials.last?.projectID == "selected-project-123")
    }

    @Test
    func `remote fetch ignores selected token account project id persistence failure`() async throws {
        let env = try GeminiTestEnvironment()
        defer { env.cleanup() }
        let selectedCredentials = AntigravityOAuthCredentials(
            accessToken: "selected-token",
            refreshToken: nil,
            expiryDate: Date().addingTimeInterval(3600),
            idToken: GeminiAPITestHelpers.makeIDToken(email: "selected@example.com"),
            email: "selected@example.com",
            projectID: nil,
            clientID: nil,
            clientSecret: nil)
        let token = try AntigravityOAuthCredentialsStore.tokenAccountValue(for: selectedCredentials)

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
                            "currentTier": ["id": "free-tier", "name": "free"],
                            "cloudaicompanionProject": "selected-project-123",
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
            timeout: 1,
            homeDirectory: env.homeURL.path,
            environment: [AntigravityOAuthCredentialsStore.environmentCredentialsKey: token],
            dataLoader: dataLoader,
            credentialsUpdateHandler: { _ in
                throw CocoaError(.fileWriteUnknown)
            })
        let snapshot = try await fetcher.fetch()

        #expect(snapshot.accountEmail == "selected@example.com")
    }

    @Test
    func `remote fetch rejects invalid selected token account`() async throws {
        let env = try GeminiTestEnvironment()
        defer { env.cleanup() }
        try env.writeAntigravityCredentials(
            accessToken: "shared-token",
            refreshToken: nil,
            expiry: Date().addingTimeInterval(3600),
            idToken: GeminiAPITestHelpers.makeIDToken(email: "shared@example.com"),
            email: "shared@example.com")

        let fetcher = AntigravityRemoteUsageFetcher(
            timeout: 1,
            homeDirectory: env.homeURL.path,
            environment: [AntigravityOAuthCredentialsStore.environmentCredentialsKey: "not-json"],
            dataLoader: GeminiAPITestHelpers.dataLoader { _ in
                throw URLError(.badServerResponse)
            })

        do {
            _ = try await fetcher.fetch()
            #expect(Bool(false), "Expected selected account decode failure")
        } catch let error as AntigravityRemoteFetchError {
            guard case let .parseFailed(message) = error else {
                #expect(Bool(false), "Unexpected Antigravity error: \(error)")
                return
            }
            #expect(message.contains("selected account"))
        } catch {
            #expect(Bool(false), "Unexpected error: \(error)")
        }
    }

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
        #expect(usage.primary?.remainingPercent.rounded() == 20)
        #expect(usage.secondary?.remainingPercent.rounded() == 50)
        #expect(usage.tertiary == nil)
    }

    @Test
    func `remote fetch verifies full model quotas with quota endpoint`() async throws {
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
                        body: GeminiAPITestHelpers.loadCodeAssistResponse(
                            tierId: "standard-tier",
                            projectId: "managed-project-123"))
                }
                if url.path == "/v1internal:fetchAvailableModels" {
                    return GeminiAPITestHelpers.response(
                        url: url.absoluteString,
                        status: 200,
                        body: GeminiAPITestHelpers.jsonData([
                            "models": [
                                "claude-sonnet-4": [
                                    "displayName": "Claude Sonnet 4",
                                    "quotaInfo": ["remainingFraction": 1],
                                ],
                                "gemini-2.5-pro": [
                                    "displayName": "Gemini 2.5 Pro",
                                    "quotaInfo": ["remainingFraction": 1],
                                ],
                                "gemini-2.5-flash": [
                                    "displayName": "Gemini 2.5 Flash",
                                    "quotaInfo": ["remainingFraction": 1],
                                ],
                            ],
                        ]))
                }
                if url.path == "/v1internal:retrieveUserQuota" {
                    quotaCalls.increment()
                    return GeminiAPITestHelpers.response(
                        url: url.absoluteString,
                        status: 200,
                        body: GeminiAPITestHelpers.jsonData([
                            "buckets": [
                                [
                                    "modelId": "claude-sonnet-4",
                                    "resetTime": "2025-01-01T00:00:00Z",
                                ],
                                [
                                    "modelId": "gemini-2.5-pro",
                                    "remainingFraction": 0.6,
                                    "resetTime": "2025-01-01T00:00:00Z",
                                ],
                                [
                                    "modelId": "gemini-2.5-flash",
                                    "remainingFraction": 0.9,
                                    "resetTime": "2025-01-01T00:00:00Z",
                                ],
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
        let usage = try snapshot.toUsageSnapshot()

        #expect(quotaCalls.get() == 1)
        #expect(usage.primary?.remainingPercent == 60.0)
        #expect(usage.secondary?.remainingPercent == 100.0)
        #expect(usage.tertiary == nil)
    }

    @Test
    func `remote fetch ignores full model availability when verification has no quota data`() async throws {
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
                        body: GeminiAPITestHelpers.loadCodeAssistResponse(
                            tierId: "standard-tier",
                            projectId: "managed-project-123"))
                }
                if url.path == "/v1internal:fetchAvailableModels" {
                    return GeminiAPITestHelpers.response(
                        url: url.absoluteString,
                        status: 200,
                        body: GeminiAPITestHelpers.jsonData([
                            "models": [
                                "claude-sonnet-4": [
                                    "displayName": "Claude Sonnet 4",
                                    "quotaInfo": ["remainingFraction": 1],
                                ],
                                "gemini-2.5-pro": [
                                    "displayName": "Gemini 2.5 Pro",
                                    "quotaInfo": ["remainingFraction": 1],
                                ],
                            ],
                        ]))
                }
                if url.path == "/v1internal:retrieveUserQuota" {
                    return GeminiAPITestHelpers.response(
                        url: url.absoluteString,
                        status: 200,
                        body: GeminiAPITestHelpers.jsonData(["buckets": []]))
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
    }

    @Test
    func `remote fetch propagates quota verification server errors`() async throws {
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
                        body: GeminiAPITestHelpers.loadCodeAssistResponse(
                            tierId: "standard-tier",
                            projectId: "managed-project-123"))
                }
                if url.path == "/v1internal:fetchAvailableModels" {
                    return GeminiAPITestHelpers.response(
                        url: url.absoluteString,
                        status: 200,
                        body: GeminiAPITestHelpers.jsonData([
                            "models": [
                                "claude-sonnet-4": [
                                    "displayName": "Claude Sonnet 4",
                                    "quotaInfo": ["remainingFraction": 1],
                                ],
                                "gemini-2.5-pro": [
                                    "displayName": "Gemini 2.5 Pro",
                                    "quotaInfo": ["remainingFraction": 1],
                                ],
                            ],
                        ]))
                }
                if url.path == "/v1internal:retrieveUserQuota" {
                    return GeminiAPITestHelpers.response(
                        url: url.absoluteString,
                        status: 503,
                        body: Data("temporary outage".utf8))
                }
                return GeminiAPITestHelpers.response(url: url.absoluteString, status: 404, body: Data())
            default:
                return GeminiAPITestHelpers.response(url: url.absoluteString, status: 404, body: Data())
            }
        }

        do {
            _ = try await AntigravityRemoteUsageFetcher(
                timeout: 1,
                homeDirectory: env.homeURL.path,
                dataLoader: dataLoader)
                .fetch()
            Issue.record("Expected quota verification server error")
        } catch let error as AntigravityRemoteFetchError {
            guard case let .apiError(message) = error else {
                Issue.record("Unexpected Antigravity error: \(error)")
                return
            }
            #expect(message.contains("HTTP 503"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test
    func `remote fetch keeps full quotas when verified quota endpoint has fractions`() async throws {
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
                        body: GeminiAPITestHelpers.loadCodeAssistResponse(
                            tierId: "standard-tier",
                            projectId: "managed-project-123"))
                }
                if url.path == "/v1internal:fetchAvailableModels" {
                    return GeminiAPITestHelpers.response(
                        url: url.absoluteString,
                        status: 200,
                        body: GeminiAPITestHelpers.jsonData([
                            "models": [
                                "claude-sonnet-4": [
                                    "displayName": "Claude Sonnet 4",
                                    "quotaInfo": ["remainingFraction": 1],
                                ],
                                "gemini-2.5-pro": [
                                    "displayName": "Gemini 2.5 Pro",
                                    "quotaInfo": ["remainingFraction": 1],
                                ],
                            ],
                        ]))
                }
                if url.path == "/v1internal:retrieveUserQuota" {
                    return GeminiAPITestHelpers.response(
                        url: url.absoluteString,
                        status: 200,
                        body: GeminiAPITestHelpers.jsonData([
                            "buckets": [
                                [
                                    "modelId": "claude-sonnet-4",
                                    "remainingFraction": 1,
                                    "resetTime": "2025-01-01T00:00:00Z",
                                ],
                                [
                                    "modelId": "gemini-2.5-pro",
                                    "remainingFraction": 1,
                                    "resetTime": "2025-01-01T00:00:00Z",
                                ],
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
        let usage = try snapshot.toUsageSnapshot()

        #expect(usage.primary?.remainingPercent == 100.0)
        #expect(usage.secondary?.remainingPercent == 100.0)
        #expect(usage.tertiary == nil)
    }

    @Test
    func `remote fetch drops full quota rows absent from partial verification`() async throws {
        let env = try GeminiTestEnvironment()
        defer { env.cleanup() }
        try env.writeAntigravityCredentials(
            accessToken: "token",
            refreshToken: nil,
            expiry: Date().addingTimeInterval(3600),
            idToken: GeminiAPITestHelpers.makeIDToken(email: "user@example.com"),
            email: "user@example.com")

        let dataLoader = GeminiAPITestHelpers.dataLoader { request in
            guard let url = request.url else {
                throw URLError(.badURL)
            }
            if url.path == "/v1internal:loadCodeAssist" {
                return GeminiAPITestHelpers.response(
                    url: url.absoluteString,
                    status: 200,
                    body: GeminiAPITestHelpers.loadCodeAssistResponse(
                        tierId: "standard-tier",
                        projectId: "managed-project-123"))
            }
            if url.path == "/v1internal:fetchAvailableModels" {
                return GeminiAPITestHelpers.response(
                    url: url.absoluteString,
                    status: 200,
                    body: GeminiAPITestHelpers.jsonData([
                        "models": [
                            "claude-sonnet-4": [
                                "displayName": "Claude Sonnet 4",
                                "quotaInfo": ["remainingFraction": 1],
                            ],
                            "gemini-2.5-pro": [
                                "displayName": "Gemini 2.5 Pro",
                                "quotaInfo": ["remainingFraction": 1],
                            ],
                        ],
                    ]))
            }
            if url.path == "/v1internal:retrieveUserQuota" {
                return GeminiAPITestHelpers.response(
                    url: url.absoluteString,
                    status: 200,
                    body: GeminiAPITestHelpers.jsonData([
                        "buckets": [
                            [
                                "modelId": "gemini-2.5-pro",
                                "remainingFraction": 0.5,
                            ],
                        ],
                    ]))
            }
            return GeminiAPITestHelpers.response(url: url.absoluteString, status: 404, body: Data())
        }

        let snapshot = try await AntigravityRemoteUsageFetcher(
            timeout: 1,
            homeDirectory: env.homeURL.path,
            dataLoader: dataLoader)
            .fetch()

        #expect(snapshot.modelQuotas.map(\.modelId) == ["gemini-2.5-pro"])
        #expect(snapshot.modelQuotas.map(\.remainingFraction) == [0.5])
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
        #expect(usage.primary?.remainingPercent == 60.0)
        #expect(usage.secondary == nil)
        #expect(usage.tertiary == nil)
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
