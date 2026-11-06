import Foundation
import Testing
@testable import CodexBarCore

enum TypeSafeTestFixture {
    static let now = Date(timeIntervalSince1970: 1_758_240_000)
    // swiftlint:disable line_length
    static let overviewBody = #"""
    {"billing":{"plan":"free_plan","spent":0.01,"freeCreditsRemaining":4.98,"balance":4.98,"purchased":0,"resetsInDays":12,"cycleLabel":"September 2026","credits":[{"id":"00000000-0000-4000-8000-000000000001","amount":5,"remaining":4.98,"expiresAt":"2026-10-19T00:00:00Z"},{"id":"00000000-0000-4000-8000-000000000002","amount":2,"remaining":0,"expiresAt":"2026-10-19T00:00:00Z"}]},"payments":[],"credits":[],"hasMore":false}
    """#
    // swiftlint:enable line_length

    static func fetch(engine: ProviderPluginEngineKind) async throws -> UsageSnapshot {
        let runtime = try BundledPluginTestSupport.runtime(
            "typesafe",
            engine: engine,
            transport: ProviderHTTPTransportHandler { request in try Self.pluginResponse(for: request) })
        return try await runtime.fetchUsage(now: self.now, cookieResolver: { _, _ in "session=fixture" })
    }

    static func pluginResponse(for request: URLRequest) throws -> (Data, URLResponse) {
        switch (request.httpMethod, request.url?.path) {
        case ("GET", "/api/billing/overview"):
            try self.response(request, body: self.overviewBody)
        default:
            try self.response(request, status: 404, body: "not found")
        }
    }

    static func response(
        _ request: URLRequest,
        status: Int = 200,
        body: String,
        contentType: String = "application/json",
        headers: [String: String] = [:]) throws -> (Data, URLResponse)
    {
        let url = try #require(request.url)
        var headerFields = ["Content-Type": contentType]
        for (name, value) in headers {
            headerFields[name] = value
        }
        let response = try #require(HTTPURLResponse(
            url: url,
            statusCode: status,
            httpVersion: nil,
            headerFields: headerFields))
        return (Data(body.utf8), response)
    }
}
