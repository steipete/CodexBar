import Foundation
import SwiftUI
import Testing
@testable import CodexBarCore
@testable import CodexBar

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

        let implementation = DeepgramProviderImplementation()
        let fields = implementation.settingsFields(context: context)

        let apiField = try #require(fields.first(where: { $0.id == "deepgram-api-key" }))
        let projectField = try #require(fields.first(where: { $0.id == "deepgram-project-id" }))

        #expect(apiField.kind == .secure)
        #expect(projectField.kind == .plain)

        // Verify bindings update the SettingsStore
        apiField.binding.wrappedValue = "dg_test_token"
        #expect(settings.deepgramAPIToken == "dg_test_token")

        projectField.binding.wrappedValue = "proj-1234"
        #expect(settings.deepgramProjectID == "proj-1234")
    }

    @Test
    nonisolated func `parses usage breakdown response into visible usage notes`() throws {
        let body = #"""
        {
          "start": "2025-01-16",
          "end": "2025-01-23",
          "resolution": {
            "units": "day",
            "amount": 1
          },
          "results": [
            {
              "hours": 1619.7242069444444,
              "total_hours": 1621.7395791666668,
              "requests": 373381,
              "grouping": {
                "start": "2025-01-16",
                "end": "2025-01-16",
                "endpoint": "listen"
              }
            },
            {
              "hours": 2.25,
              "total_hours": 3.5,
              "requests": 19,
              "grouping": {
                "start": "2025-01-17",
                "end": "2025-01-17",
                "endpoint": "speak"
              }
            }
          ]
        }
        """#

        let updatedAt = Date(timeIntervalSince1970: 123)
        let snapshot = try DeepgramUsageFetcher._parseSnapshotForTesting(
            Data(body.utf8),
            projectID: "project-123",
            updatedAt: updatedAt)
        let usage = snapshot.toUsageSnapshot()

        #expect(snapshot.requests == 373400)
        #expect(snapshot.hours == 1621.9742069444444)
        #expect(snapshot.totalHours == 1625.2395791666668)
        #expect(usage.deepgramUsage?.requests == 373400)
        #expect(usage.loginMethod(for: .deepgram) == "Project: project-123")
        #expect(usage.deepgramUsage?.displayLines == [
            "Requests: 373,400",
            "1,622.0 audio hours · 1,625.2 billable hours",
            "Period: 2025-01-16 to 2025-01-23",
        ])
    }

    @Test
    nonisolated func `fetch usage calls breakdown endpoint with token auth`() async throws {
        let registered = URLProtocol.registerClass(DeepgramStubURLProtocol.self)
        defer {
            if registered {
                URLProtocol.unregisterClass(DeepgramStubURLProtocol.self)
            }
            DeepgramStubURLProtocol.handler = nil
        }

        DeepgramStubURLProtocol.handler = { request in
            guard let url = request.url else { throw URLError(.badURL) }
            #expect(url.path == "/v1/projects/project-123/usage/breakdown")
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            #expect(components?.queryItems?.contains(URLQueryItem(name: "start", value: "2025-01-16")) == true)
            #expect(components?.queryItems?.contains(URLQueryItem(name: "end", value: "2025-01-23")) == true)
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Token dg-test")
            #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
            #expect(request.timeoutInterval == 15)

            let body = #"""
            {
              "start": "2025-01-16",
              "end": "2025-01-23",
              "resolution": {
                "units": "day",
                "amount": 1
              },
              "results": [
                {
                  "hours": 1.5,
                  "total_hours": 2,
                  "requests": 7
                }
              ]
            }
            """#
            return Self.makeResponse(url: url, body: body)
        }

        let usage = try await DeepgramUsageFetcher.fetchUsage(
            apiKey: " dg-test ",
            projectID: " project-123 ",
            query: DeepgramUsageQuery(start: "2025-01-16", end: "2025-01-23"),
            environment: ["DEEPGRAM_API_URL": "https://deepgram.test/v1"])

        #expect(usage.projectID == "project-123")
        #expect(usage.requests == 7)
        #expect(usage.hours == 1.5)
        #expect(usage.totalHours == 2)
    }

    private nonisolated static func makeResponse(
        url: URL,
        body: String,
        statusCode: Int = 200) -> (HTTPURLResponse, Data)
    {
        let response = HTTPURLResponse(
            url: url,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"])!
        return (response, Data(body.utf8))
    }
}

final class DeepgramStubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override static func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "deepgram.test"
    }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.handler else {
            self.client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let (response, data) = try handler(self.request)
            self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            self.client?.urlProtocol(self, didLoad: data)
            self.client?.urlProtocolDidFinishLoading(self)
        } catch {
            self.client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
