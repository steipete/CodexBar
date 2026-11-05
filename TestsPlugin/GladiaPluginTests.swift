import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import CodexBarCore

struct GladiaPluginTests {
    private static let now = ISO8601DateFormatter().date(from: "2026-11-05T10:00:00Z")!

    private static func item(status: String = "done", billingTime: String? = "60") -> String {
        let result = billingTime.map {
            #"{"metadata":{"audio_duration":\#($0),"number_of_distinct_channels":1,"billing_time":\#($0),"transcription_time":12.5}}"#
        } ?? "null"
        return #"{"id":"job","status":"\#(status)","created_at":"2026-11-02T08:00:00.000Z","kind":"pre-recorded","file":{"audio_duration":60},"result":\#(result)}"#
    }

    private static func page(_ items: [String], next: Bool = false) -> String {
        let nextURL = next ? #""https://api.gladia.io/v2/pre-recorded?offset=200&limit=200""# : "null"
        return #"{"first":"https://api.gladia.io/v2/pre-recorded","current":"https://api.gladia.io/v2/pre-recorded","next":\#(nextURL),"items":[\#(items.joined(separator: ","))]}"#
    }

    private static let preRecorded = Self.page([
        Self.item(billingTime: "4957.216"),
        Self.item(billingTime: "1200"),
        Self.item(status: "queued", billingTime: nil),
        Self.item(status: "error", billingTime: nil),
    ])
    private static let live = Self.page([Self.item(billingTime: "720")])

    @Test(arguments: BundledPluginTestSupport.engines)
    func `billed seconds of completed jobs are summed for the current UTC month`(
        engine: ProviderPluginEngineKind) async throws
    {
        let recorder = GladiaRequestRecorder()
        let usage = try await Self.fetch(engine, recorder: recorder)
        #expect(usage.detailRow(label: "Billed audio")?.value == "1.9 h")
        #expect(usage.detailRow(label: "Pre-recorded")?.value == "1.7 h")
        #expect(usage.detailRow(label: "Live")?.value == "12 min")
        #expect(usage.detailRow(label: "Transcriptions")?.value == "3")
        #expect(usage.details.first?.title == "This month")
        #expect(usage.primary == nil)
        #expect(usage.providerCost == nil)
        #expect(recorder.urls == [
            "https://api.gladia.io/v2/pre-recorded?after_date=2026-11-01T00%3A00%3A00.000Z&offset=0&limit=200",
            "https://api.gladia.io/v2/live?after_date=2026-11-01T00%3A00%3A00.000Z&offset=0&limit=200",
        ])
    }

    @Test(arguments: [
        ("2026-12-31T23:59:59Z", "2026-12-01T00%3A00%3A00.000Z"),
        ("2027-01-01T00:00:00Z", "2027-01-01T00%3A00%3A00.000Z"),
        ("2028-02-29T12:00:00Z", "2028-02-01T00%3A00%3A00.000Z"),
    ], BundledPluginTestSupport.engines)
    func `month start follows UTC across year and leap boundaries`(
        dates: (String, String), engine: ProviderPluginEngineKind) async throws
    {
        let recorder = GladiaRequestRecorder()
        let now = try #require(ISO8601DateFormatter().date(from: dates.0))
        _ = try await Self.fetch(engine, now: now, recorder: recorder)
        #expect(recorder.urls.allSatisfy { $0.contains("after_date=\(dates.1)&") })
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `empty month reports zero usage instead of failing`(engine: ProviderPluginEngineKind) async throws {
        let usage = try await Self.fetch(engine, preRecorded: Self.page([]), live: Self.page([]))
        #expect(usage.detailRow(label: "Billed audio")?.value == "0 min")
        #expect(usage.detailRow(label: "Transcriptions")?.value == "0")
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `paging stops at the cap and marks totals as lower bounds`(engine: ProviderPluginEngineKind) async throws {
        let recorder = GladiaRequestRecorder()
        let full = Self.page(Array(repeating: Self.item(billingTime: "10"), count: 200), next: true)
        let usage = try await Self.fetch(engine, preRecorded: full, live: Self.page([]), recorder: recorder)
        #expect(usage.detailRow(label: "Billed audio")?.value == "≥ 2.8 h")
        #expect(usage.detailRow(label: "Pre-recorded")?.value == "≥ 2.8 h")
        #expect(usage.detailRow(label: "Live")?.value == "0 min")
        #expect(usage.detailRow(label: "Transcriptions")?.value == "≥ 1,000")
        let offsets = recorder.urls.filter { $0.contains("/v2/pre-recorded") }.map {
            $0.components(separatedBy: "offset=")[1].components(separatedBy: "&")[0]
        }
        #expect(offsets == ["0", "200", "400", "600", "800"])
        #expect(recorder.urls.count == 6)
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `a full last page without a next link ends paging`(engine: ProviderPluginEngineKind) async throws {
        let recorder = GladiaRequestRecorder()
        let full = Self.page(Array(repeating: Self.item(billingTime: "10"), count: 200), next: false)
        let usage = try await Self.fetch(engine, preRecorded: full, live: Self.page([]), recorder: recorder)
        #expect(usage.detailRow(label: "Pre-recorded")?.value == "33 min")
        #expect(recorder.urls.count == 2)
    }

    @Test(arguments: [
        ("pre-recorded", "not-json"),
        ("pre-recorded", "[]"),
        ("pre-recorded", #"{"items":null}"#),
        ("pre-recorded", #"{"items":[42]}"#),
        ("pre-recorded", #"{"items":[{"status":1}]}"#),
        ("live", #"{"items":[{"status":"done","result":{"metadata":{"billing_time":"60"}}}]}"#),
        ("live", #"{"items":[{"status":"done","result":{"metadata":{"billing_time":-1}}}]}"#),
    ], BundledPluginTestSupport.engines)
    func `malformed lists are rejected rather than reported as zero usage`(
        fixture: (String, String), engine: ProviderPluginEngineKind) async
    {
        await #expect {
            try await Self.fetch(
                engine,
                preRecorded: fixture.0 == "pre-recorded" ? fixture.1 : Self.preRecorded,
                live: fixture.0 == "live" ? fixture.1 : Self.live)
        } throws: { error in
            (error as? ProviderFetchClassifiedError)?.kind == .parseFailure &&
                error.localizedDescription.contains("Refresh to try again")
        }
    }

    @Test(arguments: [401, 403, 429, 500, 400, 404], BundledPluginTestSupport.engines)
    func `HTTP failures are classified without exposing response bodies`(
        status: Int, engine: ProviderPluginEngineKind) async
    {
        let kind: ProviderFetchClassifiedError.Kind = switch status {
        case 401: .authenticationExpired
        case 403: .permissionDenied
        case 429: .rateLimited
        case 500: .providerUnavailable
        default: .apiFailure
        }
        for path in ["pre-recorded", "live"] {
            await #expect {
                try await Self.fetch(engine, failurePath: path, status: status)
            } throws: { error in
                (error as? ProviderFetchClassifiedError)?.kind == kind &&
                    !error.localizedDescription.contains("private-response-marker")
            }
        }
    }

    @Test
    func `standard credentials project the API key and advertise API sources`() throws {
        let descriptor = GladiaProviderDescriptor.descriptor
        let credentials = try #require(descriptor.credentials)
        let config = ProviderConfig(id: .gladia, apiKey: "gladia-fixture")
        let environment = credentials.applyConfig(base: [:], config: config)
        #expect(environment["GLADIA_API_KEY"] == "gladia-fixture")
        #expect(credentials.resolveToken(environment: environment)?.token == "gladia-fixture")
        #expect(descriptor.fetchPlan.sourceModes == [.auto, .api])
    }

    private static func fetch(
        _ engine: ProviderPluginEngineKind,
        now: Date = Self.now,
        preRecorded: String = Self.preRecorded,
        live: String = Self.live,
        failurePath: String? = nil,
        status: Int = 200,
        recorder: GladiaRequestRecorder? = nil) async throws -> UsageSnapshot
    {
        let transport = ProviderHTTPTransportHandler { request in
            let url = try #require(request.url)
            recorder?.record(url.absoluteString)
            #expect(url.scheme == "https")
            #expect(url.host == "api.gladia.io")
            #expect(request.httpMethod == "GET")
            #expect(request.value(forHTTPHeaderField: "x-gladia-key") == "gladia-fixture")
            #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
            let path = String(url.path.dropFirst("/v2/".count))
            let body: String = switch path {
            case "pre-recorded": preRecorded
            case "live": live
            default: throw URLError(.badURL)
            }
            let failed = path == failurePath
            let response = try #require(HTTPURLResponse(
                url: url, statusCode: failed ? status : 200, httpVersion: nil, headerFields: nil))
            return (Data((failed ? "private-response-marker" : body).utf8), response)
        }
        let runtime = try BundledPluginTestSupport.runtime("gladia", engine: engine, transport: transport)
        return try await runtime.fetchUsage(secrets: ["GLADIA_API_KEY": "gladia-fixture"], now: now)
    }
}

private final class GladiaRequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var value: [String] = []
    var urls: [String] {
        self.lock.withLock { self.value }
    }

    func record(_ url: String) { self.lock.withLock { self.value.append(url) } }
}
