import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import CodexBarCore

struct ProviderPluginConsoleCapabilitiesTests {
    @Test(arguments: BundledPluginTestSupport.engines)
    func `shared date helper preserves daily resets across DST`(engine: ProviderPluginEngineKind) async throws {
        let now = try #require(ISO8601DateParser.parse("2026-03-08T12:00:00Z"))
        let runtime = try Self.runtime(engine, body: """
        return { primary: { usedPercent: 0, resetsAt: ctx.date.nextDailyReset('America/Los_Angeles', 0) } };
        """)
        #expect(try await runtime.fetchUsage(now: now).primary?.resetsAt ==
            ISO8601DateParser.parse("2026-03-09T07:00:00Z"))
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `form POST encodes a string map and retains the final URL`(engine: ProviderPluginEngineKind) async throws {
        let runtime = try Self.runtime(engine, body: """
        const response = await ctx.http.post('https://console.example.com/api', {
          form: { sec_token: 'fixture +&=%雪', params: '{"value":"a+b&c=d"}' }
        });
        return { identity: { loginMethod: response.url } };
        """, transport: ProviderHTTPTransportHandler { request in
            #expect(request.httpMethod == "POST")
            #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/x-www-form-urlencoded")
            let body = try #require(String(data: request.httpBody ?? Data(), encoding: .utf8))
            let fields = Dictionary(uniqueKeysWithValues: body.split(separator: "&").map { pair in
                let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                return (String(parts[0]).removingPercentEncoding!, String(parts[1]).removingPercentEncoding!)
            })
            #expect(fields == ["sec_token": "fixture +&=%雪", "params": "{\"value\":\"a+b&c=d\"}"])
            return Self.response(request, body: "ok")
        })
        #expect(try await runtime.fetchUsage().identity?.loginMethod == "https://console.example.com/api")
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `form values are redacted from transport and script failures`(engine: ProviderPluginEngineKind) async throws {
        let runtime = try Self.runtime(engine, body: """
        await ctx.http.post('https://console.example.com/api', { form: { sec_token: 'fixture-secret-value' } });
        throw new Error('fixture-secret-value');
        """, transport: ProviderHTTPTransportHandler { request in Self.response(request, body: "ok") })
        let error = await #expect(throws: ProviderPluginError.self) { try await runtime.fetchUsage() }
        #expect(error?.localizedDescription.contains("<redacted>") == true)
        #expect(error?.localizedDescription.contains("fixture-secret-value") == false)
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `calendar months clamp month ends and retain local time across DST`(
        engine: ProviderPluginEngineKind) async throws
    {
        for (text, months, zone) in [
            ("2024-03-31T12:30:00Z", -1, "UTC"),
            ("2023-01-31T12:30:00Z", 1, "UTC"),
            ("2026-04-08T19:30:00Z", -1, "America/Los_Angeles"),
            ("2026-10-31T23:30:00Z", 1, "Europe/Vienna"),
        ] {
            let date = try #require(ISO8601DateParser.parse(text))
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = try #require(TimeZone(identifier: zone))
            let expected = try #require(calendar.date(byAdding: .month, value: months, to: date))
            let runtime = try Self.runtime(engine, body: """
            const date = ctx.date.addMonths(ctx.date.iso('\(text)'), \(months), '\(zone)');
            return { primary: { usedPercent: 0, resetsAt: date } };
            """)
            #expect(try await runtime.fetchUsage().primary?.resetsAt == expected)
        }
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `invalid month arithmetic and form bodies fail without transport`(
        engine: ProviderPluginEngineKind) async throws
    {
        for expression in [
            "ctx.date.addMonths(new Date(), 1.5, 'UTC')",
            "ctx.date.addMonths(new Date(), 1, 'Invalid/Zone')",
            "ctx.date.addMonths(new Date(NaN), 1, 'UTC')",
            "ctx.date.addMonths(new Date(), 120001, 'UTC')",
            "ctx.date.addMonths(new Date(), Infinity, 'UTC')",
            "await ctx.http.post('https://console.example.com/api', { form: 'raw=body' })",
            "await ctx.http.post('https://console.example.com/api', { form: { key: 3 } })",
            "await ctx.http.post('https://console.example.com/api', { form: {}, body: {} })",
        ] {
            let runtime = try Self.runtime(engine, body: "\(expression); return { empty: true };")
            await #expect(throws: ProviderPluginError.self) { try await runtime.fetchUsage() }
        }
    }

    @Test
    func `form logging redacts raw percent encoded and JSON escaped values`() throws {
        let value = "fixture&=+\"\\/\n雪"
        let redaction = ProviderPluginRedactionValues([])
        let manifest = try Self.runtime(.quickJS, body: "return { empty: true };").manifest
        let request = try ProviderPluginHTTPResponse.Request(
            rawURL: "https://console.example.com/api",
            options: ["form": ["secret": value]],
            method: "POST", settings: [:], secrets: [:], manifest: manifest,
            enforcesUserResponsePolicy: true, redactionValues: redaction)
        let data = try #require(request.primary.httpBody)
        let form = try #require(String(data: data, encoding: .utf8))
        let json = try #require(String(
            data: JSONSerialization.data(withJSONObject: ["secret": value], options: [.withoutEscapingSlashes]),
            encoding: .utf8))
        // Both engines pass ctx.log and failures through this same fetch-scoped redactor.
        #expect(redaction.redact(value) == "<redacted>")
        #expect(redaction.redact(form) == "secret=<redacted>")
        #expect(redaction.redact(json) == "{\"secret\":\"<redacted>\"}")
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `form requests cannot bypass origin and deadline validation`(engine: ProviderPluginEngineKind) async throws {
        for expression in [
            "ctx.http.post('https://undeclared.example.com/api', { form: { value: 'fixture' } })",
            "ctx.http.post('https://console.example.com/api', { form: {}, timeoutSeconds: 0 })",
            "ctx.http.post('https://console.example.com/api', { form: {}, timeoutSeconds: 91 })",
        ] {
            let runtime = try Self.runtime(engine, body: "await \(expression); return { empty: true };")
            await #expect(throws: ProviderPluginError.self) { try await runtime.fetchUsage() }
        }
    }

    @Test(.timeLimit(.minutes(1)), arguments: BundledPluginTestSupport.engines)
    func `form transport is bounded by its request deadline`(engine: ProviderPluginEngineKind) async throws {
        let (starts, started) = AsyncStream<Void>.makeStream()
        let (cancellations, cancelled) = AsyncStream<Bool>.makeStream()
        defer { started.finish(); cancelled.finish() }
        let runtime = try Self.runtime(engine, body: """
        await ctx.http.post('https://console.example.com/api', { form: {}, timeoutSeconds: 1 });
        return { empty: true };
        """, transport: ProviderHTTPTransportHandler { request in
            #expect(request.timeoutInterval == 1)
            started.yield()
            defer { cancelled.yield(Task.isCancelled) }
            try await BundledPluginTestSupport.suspendUntilCancelled()
            return Self.response(request, body: "late")
        }, contextOptions: ProviderPluginContextOptions(
            optionalRequestTimeoutSeconds: nil,
            waitForHTTPDeadline: { _, budget in
                #expect(budget == .seconds(1))
                var iterator = starts.makeAsyncIterator()
                #expect(await iterator.next() != nil)
                try Task.checkCancellation()
            }))
        await #expect(throws: URLError(.timedOut)) { try await runtime.fetchUsage() }
        var iterator = cancellations.makeAsyncIterator()
        #expect(await iterator.next() == true)
    }

    @Test(arguments: BundledPluginTestSupport.engines, ["size", "compression"])
    func `form responses retain user plugin representation limits`(
        engine: ProviderPluginEngineKind, failure: String) async throws
    {
        let runtime = try Self.runtime(engine, body: """
        await ctx.http.post('https://console.example.com/api', { form: {} });
        return { empty: true };
        """, transport: ProviderHTTPTransportHandler { request in
            #expect(request.value(forHTTPHeaderField: "Accept-Encoding") == "identity")
            let headers = failure == "compression" ? ["Content-Encoding": "gzip"] : [:]
            return (Data((failure == "size" ? "too many bytes" : "ok").utf8), HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: headers)!)
        }, userPolicy: true, responseLimit: 8)
        await #expect(throws: ProviderPluginError.self) { try await runtime.fetchUsage() }
    }

    static func runtime(
        _ engine: ProviderPluginEngineKind,
        body: String,
        transport: any ProviderHTTPTransport = ProviderHTTPTransportHandler { _ in
            Issue.record("Unexpected network request")
            throw URLError(.unsupportedURL)
        },
        contextOptions: ProviderPluginContextOptions = BundledPluginTestSupport.contextOptions,
        userPolicy: Bool = false,
        responseLimit: Int = 1024) throws -> ProviderPluginRuntime
    {
        try ProviderPluginRuntime(
            source: """
            defineProvider({ id: 'qwencloud', name: 'Fixture', endpoints: ['https://console.example.com'], settings: [],
              async fetchUsage(ctx) { \(body) }
            });
            """,
            resourceBundle: CodexBarCoreResources.bundle,
            transport: transport,
            timeout: BundledPluginTestSupport.timeout,
            responseSizeLimit: responseLimit,
            enforcesUserResponsePolicy: userPolicy,
            contextOptions: contextOptions,
            engine: engine)
    }

    static func response(_ request: URLRequest, body: String) -> (Data, URLResponse) {
        (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}
