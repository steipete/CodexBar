import Foundation
import Testing
@testable import CodexBarCore

enum TypeSafeTestFixture {
    static let now = Date(timeIntervalSince1970: 1_758_240_000)
    private static let actionID = String(repeating: "b", count: 40)
    private static let html = #"<script src="/_next/static/chunks/app.js"></script>"#
    private static let chunk = "\"" + Self.actionID
        + "\",c.callServer,void 0,c.findSourceMapURL,\"getBillingOverviewResult\""
    // swiftlint:disable line_length
    private static let body = #"""
    0:{"a":"$@1"}
    1:{"ok":true,"data":{"billing":{"plan":"free_plan","spent":0.01,"freeCreditsRemaining":4.98,"balance":4.98,"purchased":0,"resetsInDays":12,"cycleLabel":"September 2026","credits":[{"id":"00000000-0000-4000-8000-000000000001","amount":5,"remaining":4.98,"expiresAt":"2026-10-19T00:00:00Z"},{"id":"00000000-0000-4000-8000-000000000002","amount":2,"remaining":0,"expiresAt":"2026-10-19T00:00:00Z"}]}}}
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
        case ("GET", "/settings/billing"):
            try self.response(request, body: self.html, contentType: "text/html")
        case ("GET", "/_next/static/chunks/app.js"):
            try self.response(request, body: self.chunk, contentType: "application/javascript")
        case ("POST", "/settings/billing"):
            try self.response(request, body: self.body, contentType: "text/x-component")
        default:
            try self.response(request, status: 404, body: "not found")
        }
    }

    static func response(
        _ request: URLRequest,
        status: Int = 200,
        body: String,
        contentType: String = "application/json") throws -> (Data, URLResponse)
    {
        let url = try #require(request.url)
        let response = try #require(HTTPURLResponse(
            url: url,
            statusCode: status,
            httpVersion: nil,
            headerFields: ["Content-Type": contentType]))
        return (Data(body.utf8), response)
    }
}
