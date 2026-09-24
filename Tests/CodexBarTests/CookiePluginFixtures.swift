import Foundation
import Testing
@testable import CodexBarCore

/// Historical projections are test oracles only; every fixture executes the bundled plugin on both engines.
enum CookiePluginFixtures {
    static func response(_ request: URLRequest, body: String, status: Int = 200) throws -> (Data, HTTPURLResponse) {
        let response = try #require(HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]))
        return (Data(body.utf8), response)
    }

    static func manus(_ data: Data, now: Date = Date()) async throws -> ManusCreditsResponse {
        let reference: ManusCreditsResponse
        do {
            reference = try ManusReferenceParser.parseResponse(data)
        } catch {
            for engine in BundledPluginTestSupport.engines {
                let runtime = try self.runtime("manus", data: data, engine: engine)
                await self.expectFailure(.parseFailure) {
                    try await runtime.fetchUsage(cookieResolver: { _, _ in "session_id=fixture" })
                }
            }
            throw error
        }
        for engine in BundledPluginTestSupport.engines {
            let usage = try await self.runtime("manus", data: data, engine: engine)
                .fetchUsage(now: now, cookieResolver: { _, _ in "session_id=fixture" })
            let expected = reference.toUsageSnapshot(now: now)
            #expect(usage.primary == expected.primary)
            #expect(usage.secondary == expected.secondary)
            #expect(usage.identity?.loginMethod == expected.identity?.loginMethod)
        }
        return reference
    }

    static func t3chat(_ text: String, now: Date = Date()) async throws -> T3ChatUsageSnapshot {
        let reference = try T3ChatUsageParser.parseJSONLines(text, now: now)
        for engine in BundledPluginTestSupport.engines {
            let usage = try await self.runtime("t3chat", data: Data(text.utf8), engine: engine)
                .fetchUsage(now: now, cookieResolver: { _, _ in "session=fixture" })
            let expected = reference.toUsageSnapshot()
            #expect(usage.primary == expected.primary)
            #expect(usage.secondary == expected.secondary)
            #expect(usage.identity?.loginMethod == expected.identity?.loginMethod)
        }
        return reference
    }

    static func perplexity(_ data: Data, now: Date = Date()) async throws -> PerplexityUsageSnapshot {
        let reference: PerplexityUsageSnapshot
        do {
            reference = try PerplexityUsageSnapshot(
                response: JSONDecoder().decode(PerplexityCreditsResponse.self, from: data), now: now)
        } catch {
            for engine in BundledPluginTestSupport.engines {
                let runtime = try self.runtime("perplexity", data: data, engine: engine)
                await self.expectFailure(.parseFailure) {
                    try await runtime.fetchUsage(cookieResolver: { _, _ in "authjs.session-token=fixture" })
                }
            }
            throw PerplexityAPIError.parseFailed("invalid fixture")
        }
        for engine in BundledPluginTestSupport.engines {
            let usage = try await self.runtime("perplexity", data: data, engine: engine)
                .fetchUsage(now: now, cookieResolver: { _, _ in "authjs.session-token=fixture" })
            let expected = reference.toUsageSnapshot()
            #expect(usage.primary == expected.primary)
            #expect(usage.secondary == expected.secondary)
            #expect(usage.tertiary == expected.tertiary)
            #expect(usage.identity?.loginMethod == expected.identity?.loginMethod)
        }
        return reference
    }

    static func qoder(data: Data, now: Date = Date()) async throws -> QoderUsageSnapshot {
        let reference: QoderUsageSnapshot
        do {
            reference = try QoderReferenceParser.parseUsage(data: data, now: now)
        } catch {
            for engine in BundledPluginTestSupport.engines {
                let runtime = try self.runtime("qoder", data: data, engine: engine)
                await self.expectFailure(.parseFailure) {
                    try await runtime.fetchUsage(cookieSource: .manual, cookieResolver: { _, _ in "session=fixture" })
                }
            }
            throw error
        }
        for engine in BundledPluginTestSupport.engines {
            let usage = try await self.runtime("qoder", data: data, engine: engine)
                .fetchUsage(now: now, cookieResolver: { _, _ in "session=fixture" })
            #expect(usage.primary == reference.toUsageSnapshot().primary)
            #expect(usage.identity?.loginMethod == "browser / qoder.com")
        }
        return reference
    }

    static func expectFailure(
        _ kind: ProviderFetchClassifiedError.Kind,
        operation: () async throws -> UsageSnapshot) async
    {
        do {
            _ = try await operation()
            Issue.record("Expected classified provider failure")
        } catch let error as ProviderFetchClassifiedError {
            #expect(error.kind == kind)
        } catch {
            Issue.record("Expected classified provider failure, got \(error)")
        }
    }

    private static func runtime(_ name: String, data: Data, engine: ProviderPluginEngineKind) throws
        -> ProviderPluginRuntime
    {
        let body = try #require(String(data: data, encoding: .utf8))
        return try BundledPluginTestSupport.runtime(
            name,
            engine: engine,
            transport: ProviderHTTPTransportHandler { request in
                try self.response(request, body: body)
            })
    }
}
