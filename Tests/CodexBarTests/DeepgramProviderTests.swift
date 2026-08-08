#if canImport(JavaScriptCore)
import Foundation
import SwiftUI
import Testing
@testable import CodexBar
@testable import CodexBarCore

@MainActor
struct DeepgramProviderTests {
    @Test
    func `deepgram field kinds and bindings`() throws {
        let suite = "DeepgramProviderTests-field-kinds"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let configStore = testConfigStore(suiteName: suite)
        let settings = SettingsStore(
            userDefaults: defaults,
            configStore: configStore,
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings)
        let context = ProviderSettingsContext(
            provider: .deepgram,
            settings: settings,
            store: store,
            boolBinding: { keyPath in
                Binding(
                    get: { settings[keyPath: keyPath] },
                    set: { settings[keyPath: keyPath] = $0 })
            },
            stringBinding: { keyPath in
                Binding(
                    get: { settings[keyPath: keyPath] },
                    set: { settings[keyPath: keyPath] = $0 })
            },
            statusText: { _ in nil },
            setStatusText: { _, _ in },
            lastAppActiveRunAt: { _ in nil },
            setLastAppActiveRunAt: { _, _ in },
            requestConfirmation: { _ in },
            runLoginFlow: {})

        let fields = DeepgramProviderImplementation().settingsFields(context: context)
        let apiField = try #require(fields.first(where: { $0.id == "deepgram-api-key" }))
        let projectField = try #require(fields.first(where: { $0.id == "deepgram-project-id" }))

        #expect(apiField.kind == .secure)
        #expect(projectField.kind == .plain)
        apiField.binding.wrappedValue = "dg_test_token"
        #expect(settings[providerConfig: .deepgram, field: .apiKey] == "dg_test_token")
        projectField.binding.wrappedValue = "proj-1234"
        #expect(settings[providerConfig: .deepgram, field: .workspace] == "proj-1234")
    }

    @Test
    nonisolated func `usage breakdown fixture matches visible detail golden`() async throws {
        let body = #"""
        {
          "start": "2025-01-16",
          "end": "2025-01-23",
          "resolution": { "units": "day", "amount": 1 },
          "results": [
            {
              "hours": 1619.7242069444444,
              "total_hours": 1621.7395791666668,
              "agent_hours": 41.33564388888889,
              "tokens_in": 1200,
              "tokens_out": 340,
              "tts_characters": 9158866,
              "requests": 373381,
              "grouping": { "start": "2025-01-16", "end": "2025-01-16", "endpoint": "listen" }
            },
            {
              "hours": 2.25,
              "total_hours": 3.5,
              "requests": 19,
              "grouping": { "start": "2025-01-17", "end": "2025-01-17", "endpoint": "speak" }
            }
          ]
        }
        """#

        let usage = try await Self.fetch(
            projectID: "project-123",
            transport: Self.transport { _ in body },
            now: Date(timeIntervalSince1970: 123))

        #expect(usage.detailRow(label: "Requests")?.value == "373,400")
        #expect(usage.loginMethod(for: .deepgram) == "Project: project-123")
        #expect(usage.detailRow(label: "Audio")?.value == "1,622.0 hours")
        #expect(usage.detailRow(label: "Audio")?.secondaryValue == "1,625.2 billable hours")
        #expect(usage.detailRow(label: "Agent hours")?.value == "41.3")
        #expect(usage.detailRow(label: "Tokens")?.value == "1,540")
        #expect(usage.detailRow(label: "TTS characters")?.value == "9,158,866")
        #expect(usage.detailRow(label: "Period")?.value == "2025-01-16 to 2025-01-23")
    }

    @Test
    nonisolated func `fetch uses normalized override and token authorization`() async throws {
        let recorder = DeepgramRequestRecorder()
        let body = #"""
        {
          "start": "2025-01-16",
          "end": "2025-01-23",
          "resolution": { "units": "day", "amount": 1 },
          "results": [{ "hours": 1.5, "total_hours": 2, "requests": 7 }]
        }
        """#
        let transport = Self.transport(recorder: recorder) { _ in body }

        let usage = try await Self.fetch(
            projectID: "project-123",
            apiURL: "https://deepgram.test/v1",
            transport: transport)

        let request = try #require(await recorder.requests.first)
        #expect(request.url?.path == "/v1/projects/project-123/usage/breakdown")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Token dg-test")
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
        #expect(request.timeoutInterval == 15)
        #expect(usage.detailRow(label: "Requests")?.value == "7")
        #expect(usage.detailRow(label: "Audio")?.value == "1.5 hours")
    }

    @Test
    nonisolated func `project discovery aggregates every project`() async throws {
        let recorder = DeepgramRequestRecorder()
        let transport = Self.transport(recorder: recorder) { request in
            switch request.url?.path {
            case "/v1/projects":
                #"{"projects":[{"project_id":"project-a","name":"Alpha"},{"project_id":"project-b","name":"Beta"}]}"#
            case "/v1/projects/project-a/usage/breakdown":
                #"{"start":"2025-01-16","end":"2025-01-23","results":[{"hours":1,"total_hours":2,"requests":3}]}"#
            case "/v1/projects/project-b/usage/breakdown":
                #"{"start":"2025-01-17","end":"2025-01-24","results":[{"hours":4,"total_hours":5,"requests":6}]}"#
            default:
                throw URLError(.badURL)
            }
        }

        let usage = try await Self.fetch(apiURL: "https://deepgram.test/v1", transport: transport)

        #expect(usage.detailRow(label: "Requests")?.value == "9")
        #expect(usage.detailRow(label: "Audio")?.value == "5 hours")
        #expect(usage.detailRow(label: "Audio")?.secondaryValue == "7 billable hours")
        #expect(usage.detailRow(label: "Period")?.value == "2025-01-16 to 2025-01-24")
        #expect(usage.loginMethod(for: .deepgram) == "2 projects")
        #expect(await recorder.requests.map { $0.url?.path } == [
            "/v1/projects",
            "/v1/projects/project-a/usage/breakdown",
            "/v1/projects/project-b/usage/breakdown",
        ])
    }

    @Test(arguments: [
        (401, ProviderFetchClassifiedError.Kind.authenticationExpired),
        (403, .permissionDenied),
        (429, .rateLimited),
        (500, .providerUnavailable),
        (400, .apiFailure),
    ])
    nonisolated func `HTTP failures preserve classified surface`(
        status: Int,
        kind: ProviderFetchClassifiedError.Kind) async throws
    {
        let transport = ProviderHTTPTransportHandler { request in
            let response = try #require(HTTPURLResponse(
                url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil))
            return (Data("not-json".utf8), response)
        }

        do {
            _ = try await Self.fetch(projectID: "project-123", transport: transport)
            Issue.record("Expected classified failure")
        } catch let error as ProviderFetchClassifiedError {
            #expect(error.kind == kind)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test
    nonisolated func `network and parse failures retain their classifications`() async throws {
        do {
            _ = try await Self.fetch(
                projectID: "project-123",
                transport: ProviderHTTPTransportHandler { _ in throw URLError(.notConnectedToInternet) })
            Issue.record("Expected network failure")
        } catch let error as ProviderFetchClassifiedError {
            #expect(error.kind == .networkFailure)
        }

        do {
            _ = try await Self.fetch(projectID: "project-123", transport: Self.transport { _ in "not-json" })
            Issue.record("Expected parse failure")
        } catch let error as ProviderFetchClassifiedError {
            #expect(error.kind == .parseFailure)
        }
    }

    private nonisolated static func fetch(
        projectID: String? = nil,
        apiURL: String = "https://api.deepgram.com/v1",
        transport: ProviderHTTPTransportHandler,
        now: Date = Date()) async throws -> UsageSnapshot
    {
        var settings = [DeepgramSettingsReader.apiURLEnvironmentKey: apiURL]
        if let projectID {
            settings[DeepgramSettingsReader.projectIDEnvironmentKey] = projectID
        }
        let runtime = try ProviderPluginRuntime(bundledPlugin: "deepgram", transport: transport)
        return try await runtime.fetchUsage(
            settings: settings,
            secrets: [DeepgramSettingsReader.apiKeyEnvironmentKey: "dg-test"],
            now: now)
    }

    private nonisolated static func transport(
        recorder: DeepgramRequestRecorder? = nil,
        body: @escaping @Sendable (URLRequest) throws -> String) -> ProviderHTTPTransportHandler
    {
        ProviderHTTPTransportHandler { request in
            if let recorder {
                await recorder.append(request)
            }
            let response = try #require(HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]))
            return try (Data(body(request).utf8), response)
        }
    }
}

private actor DeepgramRequestRecorder {
    private(set) var requests: [URLRequest] = []

    func append(_ request: URLRequest) {
        self.requests.append(request)
    }
}
#endif
