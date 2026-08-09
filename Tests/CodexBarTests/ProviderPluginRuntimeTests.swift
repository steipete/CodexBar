import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import CodexBarCore

struct ProviderPluginRuntimeTests {
    @Test
    func `automatic engine defaults to QuickJS`() {
        #expect(ProviderPluginRuntime.resolveEngineKind(
            .automatic,
            environment: [:],
            useJavaScriptCoreRollback: false) == .quickJS)
    }

    @Test
    func `explicit engine selection bypasses automatic policy`() {
        #expect(ProviderPluginRuntime.resolveEngineKind(
            .quickJS,
            environment: [ProviderPluginRuntime.engineEnvironmentKey: "jsc"],
            useJavaScriptCoreRollback: true) == .quickJS)
    }

    #if canImport(JavaScriptCore)
    @Test
    func `JavaScriptCore rollback supports environment and debug defaults`() {
        #expect(ProviderPluginRuntime.resolveEngineKind(
            .automatic,
            environment: [ProviderPluginRuntime.engineEnvironmentKey: "jsc"],
            useJavaScriptCoreRollback: false) == .javaScriptCore)
        #expect(ProviderPluginRuntime.resolveEngineKind(
            .automatic,
            environment: [:],
            useJavaScriptCoreRollback: true) == .javaScriptCore)
        #expect(ProviderPluginRuntime.resolveEngineKind(
            .automatic,
            environment: [ProviderPluginRuntime.engineEnvironmentKey: "quickjs"],
            useJavaScriptCoreRollback: true) == .quickJS)
    }
    #endif

    @Test
    func `missing resource bundle throws a provider load error`() {
        #expect(throws: ProviderPluginError.load(CodexBarCoreResources.missingBundleMessage)) {
            _ = try ProviderPluginRuntime(bundledPlugin: "openrouter", resourceBundle: nil)
        }
    }

    @Test
    func `date now uses the injected fetch clock`() async throws {
        let expected = Date(timeIntervalSince1970: 1_800_000_000)
        let runtime = try ProviderPluginRuntime(source: Self.plugin(fetchBody: """
        return { primary: { usedPercent: 1, resetsAt: ctx.date.now() } };
        """))

        let snapshot = try await runtime.fetchUsage(secrets: ["TEST_KEY": "test-key"], now: expected)

        #expect(snapshot.primary?.resetsAt == expected)
    }

    @Test
    func `date nowMillis uses the injected fetch clock`() async throws {
        let expected = Date(timeIntervalSince1970: 1_800_000_000)
        let runtime = try ProviderPluginRuntime(source: Self.plugin(fetchBody: """
        return { primary: { usedPercent: 1, resetDescription: String(ctx.date.nowMillis()) } };
        """))

        let snapshot = try await runtime.fetchUsage(secrets: ["TEST_KEY": "test-key"], now: expected)

        #expect(snapshot.primary?.resetDescription == "1800000000000")
    }

    @Test
    func `context exposes no browser or timer globals`() throws {
        let runtime = try ProviderPluginRuntime(source: Self.plugin())

        #expect(try runtime.globalType(of: "fetch") == "undefined")
        #expect(try runtime.globalType(of: "XMLHttpRequest") == "undefined")
        #expect(try runtime.globalType(of: "setTimeout") == "undefined")
        #expect(try runtime.globalType(of: "setInterval") == "undefined")
        #expect(try runtime.globalType(of: "ctx") == "undefined")
    }

    @Test
    func `origin allowlist rejects before issuing request`() async throws {
        let requests = RequestRecorder()
        let runtime = try ProviderPluginRuntime(
            source: Self.plugin(fetchBody: """
            const response = await ctx.http.getJSON("https://other.example/usage");
            return { primary: { usedPercent: response.status } };
            """),
            transport: Self.transport(recorder: requests))

        await #expect(throws: ProviderPluginError.self) {
            _ = try await runtime.fetchUsage(secrets: ["TEST_KEY": "secret"])
        }
        #expect(await requests.isEmpty)
    }

    @Test
    func `HTTP broker injects auth and returns JSON`() async throws {
        let requests = RequestRecorder()
        let runtime = try ProviderPluginRuntime(
            source: Self.plugin(fetchBody: """
            const response = await ctx.http.getJSON("https://api.example.test/usage", {
              headers: { "X-Client": "plugin-test" },
            });
            return { primary: { usedPercent: response.json.used } };
            """),
            transport: Self.transport(recorder: requests, body: #"{"used":42}"#))

        let snapshot = try await runtime.fetchUsage(secrets: ["TEST_KEY": "secret-value"])

        #expect(snapshot.primary?.usedPercent == 42)
        let request = try #require(await requests.first)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer secret-value")
        #expect(request.value(forHTTPHeaderField: "X-Client") == "plugin-test")
    }

    @Test
    func `HTTP request deadline defaults to fifteen seconds and accepts bounded override`() async throws {
        let requests = RequestRecorder()
        let runtime = try ProviderPluginRuntime(
            source: Self.plugin(fetchBody: """
            await ctx.http.getJSON("https://api.example.test/default");
            const response = await ctx.http.getJSON("https://api.example.test/override", { timeoutSeconds: 7.5 });
            return { primary: { usedPercent: response.json.used } };
            """),
            transport: Self.transport(recorder: requests, body: #"{"used":11}"#))

        let snapshot = try await runtime.fetchUsage(secrets: ["TEST_KEY": "secret-value"])

        #expect(snapshot.primary?.usedPercent == 11)
        let recorded = await requests.all
        #expect(recorded.map(\.timeoutInterval) == [15, 7.5])
    }

    @Test(arguments: ["0", "0.5", "31", #""slow""#])
    func `HTTP request deadline rejects values outside one through thirty seconds`(value: String) async throws {
        let requests = RequestRecorder()
        let runtime = try ProviderPluginRuntime(
            source: Self.plugin(fetchBody: """
            await ctx.http.getJSON("https://api.example.test/usage", { timeoutSeconds: \(value) });
            return { primary: { usedPercent: 1 } };
            """),
            transport: Self.transport(recorder: requests))

        await #expect(throws: ProviderPluginError.self) {
            _ = try await runtime.fetchUsage(secrets: ["TEST_KEY": "secret-value"])
        }
        #expect(await requests.isEmpty)
    }

    @Test
    func `HTTP request deadline cancels a transport that exceeds it`() async throws {
        let cancellation = TransportCancellationProbe()
        let runtime = try ProviderPluginRuntime(
            source: Self.plugin(fetchBody: """
            await ctx.http.getJSON("https://api.example.test/slow", { timeoutSeconds: 1 });
            return { primary: { usedPercent: 1 } };
            """),
            transport: ProviderHTTPTransportHandler { request in
                do {
                    try await Task.sleep(for: .seconds(5))
                } catch is CancellationError {
                    await cancellation.markCancelled()
                    throw CancellationError()
                }
                let response = try #require(HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]))
                return (Data(#"{"used":1}"#.utf8), response)
            })

        do {
            _ = try await runtime.fetchUsage(secrets: ["TEST_KEY": "secret-value"])
            Issue.record("Expected the request deadline to reject the plugin fetch")
        } catch let error as ProviderPluginError {
            guard case .script = error else {
                Issue.record("Expected a request deadline failure, received \(error)")
                return
            }
            await cancellation.waitUntilCancelled()
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test
    func `settings split enforces kind and only secrets are redacted`() async throws {
        let runtime = try ProviderPluginRuntime(source: Self.plugin(
            settings: """
            { key: "TEST_KEY", title: "API key", type: "secure" },
            { key: "PLAIN_VALUE", title: "Plain value", type: "plain" }
            """,
            fetchBody: """
            const plain = ctx.settings.get("PLAIN_VALUE");
            const secret = ctx.settings.getSecret("TEST_KEY");
            throw new Error(`${plain}:${secret}`);
            """))

        do {
            _ = try await runtime.fetchUsage(
                settings: ["PLAIN_VALUE": "visible-setting"],
                secrets: ["TEST_KEY": "hidden-secret"])
            Issue.record("Expected rejection")
        } catch {
            #expect(error.localizedDescription.contains("visible-setting"))
            #expect(!error.localizedDescription.contains("hidden-secret"))
            #expect(error.localizedDescription.contains("<redacted>"))
        }
    }

    @Test
    func `authorization scheme injects bounded token prefix`() async throws {
        let requests = RequestRecorder()
        let runtime = try ProviderPluginRuntime(
            source: Self.plugin(
                auth: #"{ type: "authorization-scheme", scheme: "Token", secret: "TEST_KEY" }"#,
                fetchBody: """
                const response = await ctx.http.getJSON("https://api.example.test/usage");
                return { primary: { usedPercent: response.status } };
                """),
            transport: Self.transport(recorder: requests))

        _ = try await runtime.fetchUsage(secrets: ["TEST_KEY": "fixture-key"])

        #expect(await requests.first?.value(forHTTPHeaderField: "Authorization") == "Token fixture-key")
        #expect(throws: ProviderPluginError.self) {
            _ = try ProviderPluginRuntime(source: Self.plugin(
                auth: #"{ type: "authorization-scheme", scheme: "bad scheme", secret: "TEST_KEY" }"#))
        }
    }

    @Test
    func `postJSON sends serialized body without relaxing headers`() async throws {
        let requests = RequestRecorder()
        let runtime = try ProviderPluginRuntime(
            source: Self.plugin(fetchBody: """
            const response = await ctx.http.postJSON("https://api.example.test/usage", {
              body: { team: "fixture", count: 2 },
              headers: { "X-Client": "plugin-test" },
            });
            return { primary: { usedPercent: response.json.used } };
            """),
            transport: Self.transport(recorder: requests, body: #"{"used":17}"#))

        let snapshot = try await runtime.fetchUsage(secrets: ["TEST_KEY": "fixture-key"])
        let request = try #require(await requests.first)
        #expect(snapshot.primary?.usedPercent == 17)
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        let body = try #require(request.httpBody)
        let object = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(object["team"] as? String == "fixture")
        #expect(object["count"] as? Int == 2)
    }

    @Test
    func `setting endpoint resolves at fetch time and permits loopback HTTP only by policy`() async throws {
        let requests = RequestRecorder()
        let runtime = try ProviderPluginRuntime(
            source: Self.plugin(
                endpoints: #"[{ setting: "BASE_URL", policy: "https-or-loopback-http" }]"#,
                settings: """
                { key: "TEST_KEY", title: "API key", type: "secure" },
                { key: "BASE_URL", title: "Base URL", type: "plain" }
                """,
                fetchBody: """
                const base = ctx.settings.get("BASE_URL");
                const response = await ctx.http.getJSON(`${base}/usage`);
                return { primary: { usedPercent: response.json.used } };
                """),
            transport: Self.transport(recorder: requests, body: #"{"used":23}"#))

        let snapshot = try await runtime.fetchUsage(
            settings: ["BASE_URL": "http://127.0.0.1:8787"],
            secrets: ["TEST_KEY": "fixture-key"])
        #expect(snapshot.primary?.usedPercent == 23)
        #expect(await requests.first?.url?.absoluteString == "http://127.0.0.1:8787/usage")

        let rejectedRequests = RequestRecorder()
        let rejected = try ProviderPluginRuntime(
            source: Self.plugin(
                endpoints: #"[{ setting: "BASE_URL", policy: "https-or-loopback-http" }]"#,
                settings: """
                { key: "TEST_KEY", title: "API key", type: "secure" },
                { key: "BASE_URL", title: "Base URL", type: "plain" }
                """,
                fetchBody: """
                await ctx.http.getJSON(`${ctx.settings.get("BASE_URL")}/usage`);
                return { primary: { usedPercent: 1 } };
                """),
            transport: Self.transport(recorder: rejectedRequests))
        await #expect(throws: ProviderPluginError.self) {
            _ = try await rejected.fetchUsage(
                settings: ["BASE_URL": "http://example.test"],
                secrets: ["TEST_KEY": "fixture-key"])
        }
        #expect(await rejectedRequests.isEmpty)
    }

    @Test
    func `browser cookie access is declared domain only and cookie values are redacted`() async throws {
        let access = CookieAccessRecorder(header: "session=secret-cookie-value")
        let runtime = try ProviderPluginRuntime(source: Self.plugin(
            capabilities: #"capabilities: ["browser-cookies"], cookieDomains: ["example.test"],"#,
            fetchBody: """
            const cookie = await ctx.browser.cookieHeader("example.test");
            throw new Error(`cookie was ${cookie}`);
            """))

        do {
            _ = try await runtime.fetchUsage(
                secrets: ["TEST_KEY": "fixture-key"],
                cookieResolver: { provider, domain in try await access.resolve(provider: provider, domain: domain) })
            Issue.record("Expected rejection")
        } catch {
            #expect(!error.localizedDescription.contains("secret-cookie-value"))
            #expect(error.localizedDescription.contains("<redacted>"))
        }
        #expect(await access.domains == ["example.test"])

        let rejected = try ProviderPluginRuntime(source: Self.plugin(
            capabilities: #"capabilities: ["browser-cookies"], cookieDomains: ["example.test"],"#,
            fetchBody: """
            await ctx.browser.cookieHeader("other.test");
            return { primary: { usedPercent: 1 } };
            """))
        await #expect(throws: ProviderPluginError.self) {
            _ = try await rejected.fetchUsage(
                secrets: ["TEST_KEY": "fixture-key"],
                cookieResolver: { provider, domain in try await access.resolve(provider: provider, domain: domain) })
        }
        #expect(await access.domains == ["example.test"])
    }

    @Test
    func `HTML helpers extract meta content and first regex capture`() async throws {
        let runtime = try ProviderPluginRuntime(source: Self.plugin(fetchBody: """
        const html = '<meta content="fixture-token" name="csrf"><div>credits: 37</div>';
        const meta = ctx.html.metaContent(html, "csrf");
        const credits = ctx.html.matchFirst(html, "credits:\\\\s*(\\\\d+)", "i");
        return { primary: { usedPercent: meta === "fixture-token" ? Number(credits) : 0 } };
        """))

        let snapshot = try await runtime.fetchUsage(secrets: ["TEST_KEY": "fixture-key"])
        #expect(snapshot.primary?.usedPercent == 37)
    }

    @Test
    func `undeclared secret access fails`() async throws {
        let runtime = try ProviderPluginRuntime(source: Self.plugin(fetchBody: """
        ctx.settings.getSecret("OTHER_KEY");
        return { primary: { usedPercent: 1 } };
        """))

        await #expect(throws: ProviderPluginError.self) {
            _ = try await runtime.fetchUsage(secrets: ["TEST_KEY": "secret"])
        }
    }

    @Test(arguments: [
        "defineProvider({",
        "defineProvider({ id: 'synthetic' });",
        """
        defineProvider({
          id: "not-a-provider",
          name: "Bad",
          endpoints: ["https://api.example.test"],
          auth: { type: "bearer", secret: "TEST_KEY" },
          settings: [{ key: "TEST_KEY", title: "Key" }],
          fetchUsage: async () => ({ primary: { usedPercent: 0 } }),
        });
        """,
    ])
    func `malformed plugins have descriptive load errors`(source: String) {
        #expect(throws: ProviderPluginError.self) {
            _ = try ProviderPluginRuntime(source: source)
        }
    }

    @Test
    func `wrong typed snapshot field fails`() async throws {
        let runtime = try ProviderPluginRuntime(source: Self.plugin(fetchBody: """
        return { primary: { usedPercent: "42" } };
        """))

        await #expect(throws: ProviderPluginError.self) {
            _ = try await runtime.fetchUsage(secrets: ["TEST_KEY": "secret"])
        }
    }

    @Test(arguments: [
        ("exact", UsageDataConfidence.exact),
        ("estimated", .estimated),
        ("percentOnly", .percentOnly),
        ("unknown", .unknown),
    ])
    func `data confidence maps validated values`(rawValue: String, expected: UsageDataConfidence) async throws {
        let runtime = try ProviderPluginRuntime(source: Self.plugin(fetchBody: """
        return { primary: { usedPercent: 1 }, dataConfidence: "\(rawValue)" };
        """))

        let snapshot = try await runtime.fetchUsage(secrets: ["TEST_KEY": "secret"])

        #expect(snapshot.dataConfidence == expected)
    }

    @Test(arguments: [#""certain""#, "42"])
    func `invalid data confidence fails the snapshot`(value: String) async throws {
        let runtime = try ProviderPluginRuntime(source: Self.plugin(fetchBody: """
        return { primary: { usedPercent: 1 }, dataConfidence: \(value) };
        """))

        await #expect(throws: ProviderPluginError.self) {
            _ = try await runtime.fetchUsage(secrets: ["TEST_KEY": "secret"])
        }
    }

    @Test
    func `identity only snapshot preserves a successful sparse provider state`() async throws {
        let runtime = try ProviderPluginRuntime(source: Self.plugin(fetchBody: """
        return { identity: { organization: "Moonshot", loginMethod: "Balance: $0.00" } };
        """))

        let snapshot = try await runtime.fetchUsage(secrets: ["TEST_KEY": "secret"])

        #expect(snapshot.primary == nil)
        #expect(snapshot.providerCost == nil)
        #expect(snapshot.identity?.accountOrganization == "Moonshot")
        #expect(snapshot.identity?.loginMethod == "Balance: $0.00")
    }

    @Test(arguments: [
        #"return {};"#,
        #"return { identity: {} };"#,
        #"return { identity: { email: "  " } };"#,
        #"return { dataConfidence: "exact" };"#,
        #"return { subscriptionRenewsAt: "2026-09-01T00:00:00Z" };"#,
    ])
    func `empty and metadata only snapshots remain invalid`(fetchBody: String) async throws {
        let runtime = try ProviderPluginRuntime(source: Self.plugin(fetchBody: fetchBody))

        await #expect(throws: ProviderPluginError.self) {
            _ = try await runtime.fetchUsage(secrets: ["TEST_KEY": "secret"])
        }
    }

    @Test
    func `details map strictly and trim display strings`() async throws {
        let runtime = try ProviderPluginRuntime(source: Self.plugin(fetchBody: """
        return {
          details: [{
            title: " Summary ",
            rows: [{ label: " Requests ", value: " 42 ", secondaryValue: " Today " }],
            chart: {
              kind: "line",
              title: " Daily ",
              unit: " tokens ",
              points: [{ label: " Mon ", value: 12.5 }],
            },
          }],
        };
        """))

        let snapshot = try await runtime.fetchUsage(secrets: ["TEST_KEY": "secret"])

        let section = try #require(snapshot.details.first)
        #expect(section.title == "Summary")
        #expect(try section.rows == [ProviderDetailSection.Row(
            label: "Requests",
            value: "42",
            secondaryValue: "Today")])
        let expectedChart = try ProviderDetailSection.Chart(
            kind: .line,
            title: "Daily",
            unit: "tokens",
            points: [ProviderDetailSection.Chart.Point(label: "Mon", value: 12.5)])
        #expect(section.chart == expectedChart)
    }

    @Test(arguments: [
        #"details: {}"#,
        #"details: [{ rows: [{ label: "ok", value: 1 }] }]"#,
        #"details: [{ rows: [], chart: { kind: "pie", points: [] } }]"#,
        #"details: [{ rows: [], chart: { kind: "bars", points: [{ label: "x", value: NaN }] } }]"#,
        #"""
        details: [{
          rows: [],
          chart: { kind: "bars", points: Array.from({length: 121}, (_, i) => ({label: String(i), value: i})) },
        }]
        """#,
    ])
    func `present invalid details fail the fetch`(body: String) async throws {
        let runtime = try ProviderPluginRuntime(source: Self.plugin(fetchBody: "return { \(body) };"))

        await #expect(throws: ProviderPluginError.self) {
            _ = try await runtime.fetchUsage(secrets: ["TEST_KEY": "secret"])
        }
    }

    @Test
    func `promise rejection preserves message`() async throws {
        let runtime = try ProviderPluginRuntime(source: Self.plugin(fetchBody: """
        throw new Error("fixture rejected");
        """))

        do {
            _ = try await runtime.fetchUsage(secrets: ["TEST_KEY": "secret"])
            Issue.record("Expected rejection")
        } catch {
            #expect(error.localizedDescription.contains("fixture rejected"))
        }
    }

    @Test(arguments: ProviderFetchClassifiedError.Kind.allCases)
    func `classified failures preserve kind and message`(kind: ProviderFetchClassifiedError.Kind) async throws {
        let apiName = switch kind {
        case .authenticationExpired: "authenticationExpired"
        case .missingCredential: "missingCredential"
        case .permissionDenied: "permissionDenied"
        case .rateLimited: "rateLimited"
        case .providerUnavailable: "providerUnavailable"
        case .parseFailure: "parseFailure"
        case .networkFailure: "networkFailure"
        case .apiFailure: "apiFailure"
        }
        let runtime = try ProviderPluginRuntime(source: Self.plugin(fetchBody: """
        throw ctx.fail.\(apiName)("classified fixture");
        """))

        do {
            _ = try await runtime.fetchUsage(secrets: ["TEST_KEY": "secret"])
            Issue.record("Expected classified failure")
        } catch let error as ProviderFetchClassifiedError {
            #expect(error.kind == kind)
            #expect(error.message == "classified fixture")
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test
    func `transient classified failure preserves capped retry delay`() async throws {
        let runtime = try ProviderPluginRuntime(source: Self.plugin(fetchBody: """
        throw ctx.fail.rateLimited("retry later", { retryAfterSeconds: 30 });
        """))

        do {
            _ = try await runtime.fetchUsage(secrets: ["TEST_KEY": "secret"])
            Issue.record("Expected classified failure")
        } catch let error as ProviderFetchClassifiedError {
            #expect(error.kind == .rateLimited)
            #expect(error.message == "retry later")
            #expect(error.retryAfterSeconds == 10)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test
    func `non transient classified failure rejects retry options`() async throws {
        let runtime = try ProviderPluginRuntime(source: Self.plugin(fetchBody: """
        throw ctx.fail.parseFailure("bad payload", { retryAfterSeconds: 1 });
        """))

        do {
            _ = try await runtime.fetchUsage(secrets: ["TEST_KEY": "secret"])
            Issue.record("Expected script failure")
        } catch let error as ProviderPluginError {
            #expect(error.localizedDescription.contains("retry options are supported only for transient failures"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test
    func `unclassified failures retain generic script mapping`() async throws {
        let runtime = try ProviderPluginRuntime(source: Self.plugin(fetchBody: """
        throw new Error("ordinary fixture");
        """))

        do {
            _ = try await runtime.fetchUsage(secrets: ["TEST_KEY": "secret"])
            Issue.record("Expected script failure")
        } catch let error as ProviderPluginError {
            #expect(error == .script("ordinary fixture"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test
    func `script errors redact known secrets`() async throws {
        let secret = "super-secret-fixture-value"
        let runtime = try ProviderPluginRuntime(source: Self.plugin(fetchBody: """
        throw new Error(`leaked: ${ctx.settings.getSecret("TEST_KEY")}`);
        """))

        do {
            _ = try await runtime.fetchUsage(secrets: ["TEST_KEY": secret])
            Issue.record("Expected rejection")
        } catch {
            #expect(!error.localizedDescription.contains(secret))
            #expect(error.localizedDescription.contains("<redacted>"))
        }
    }

    @Test
    func `QuickJS engine supports bounded recursion on its dedicated stack`() async throws {
        let runtime = try ProviderPluginRuntime(
            source: Self.plugin(fetchBody: """
            function recurse(depth) {
              return depth <= 0 ? 0 : 1 + recurse(depth - 1);
            }
            return { primary: { usedPercent: recurse(100) } };
            """),
            engine: .quickJS)

        let snapshot = try await runtime.fetchUsage(secrets: ["TEST_KEY": "secret"])

        #expect(snapshot.primary?.usedPercent == 100)
    }

    @Test
    func `QuickJS engine reports recursion beyond its JavaScript stack limit`() async throws {
        // Deliberately starved worker geometry: with a fixed JS stack limit this crashed the process
        // (guard fires with too little native left to build the RangeError — the quickjs-ng/zipline#1130
        // class). The derived limit (a quarter of the worker stack) makes the invariant hold at any size,
        // so even a 512 KiB thread throws a clean script error instead of overrunning the guard page.
        let engine = try Self.quickJSEngine(
            source: Self.plugin(fetchBody: """
            function recurse(depth) {
              return depth <= 0 ? 0 : 1 + recurse(depth - 1);
            }
            return { primary: { usedPercent: recurse(100000) } };
            """),
            workerStackSizeBytes: 512 * 1024)

        do {
            _ = try await Self.fetchUsage(engine: engine)
            Issue.record("Expected stack overflow")
        } catch let error as ProviderPluginError {
            guard case let .script(message) = error else {
                Issue.record("Unexpected plugin error: \(error)")
                return
            }
            let normalizedMessage = message.lowercased()
            #expect(normalizedMessage.contains("stack"))
            #expect(normalizedMessage.contains("overflow") || normalizedMessage.contains("exceeded"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test
    func `hung script times out and next fetch uses a fresh context`() async throws {
        let runtime = try ProviderPluginRuntime(
            source: Self.plugin(fetchBody: """
            if (ctx.settings.getSecret("TEST_KEY") === "hang") while (true) {}
            return { primary: { usedPercent: 7 } };
            """),
            timeout: 5)
        let start = Date()

        await #expect(throws: ProviderPluginError.self) {
            _ = try await runtime.fetchUsage(secrets: ["TEST_KEY": "hang"])
        }
        // This ceiling only proves the watchdog interrupted the infinite loop instead of hanging
        // forever. The runtime timeout itself leaves fresh-worker compilation ample scheduler headroom.
        #expect(Date().timeIntervalSince(start) < 30)

        let recovered = try await runtime.fetchUsage(secrets: ["TEST_KEY": "ok"])
        #expect(recovered.primary?.usedPercent == 7)
    }

    private static func plugin(
        endpoints: String = #"["https://api.example.test"]"#,
        auth: String = #"{ type: "bearer", secret: "TEST_KEY" }"#,
        settings: String = #"{ key: "TEST_KEY", title: "API key", type: "secure" }"#,
        capabilities: String = "",
        fetchBody: String = "return { primary: { usedPercent: 1 } };") -> String
    {
        """
        defineProvider({
          id: "synthetic",
          name: "Fixture",
          endpoints: \(endpoints),
          auth: \(auth),
          settings: [\(settings)],
          \(capabilities)
          async fetchUsage(ctx) {
            \(fetchBody)
          },
        });
        """
    }

    private static func quickJSEngine(
        source: String,
        workerStackSizeBytes: Int) throws -> QuickJSProviderPluginEngine
    {
        let bundle = try #require(CodexBarCoreResources.bundle)
        let preludeURL = try #require(bundle.url(
            forResource: "provider-plugin-prelude",
            withExtension: "js"))
        let preludeSource = try String(contentsOf: preludeURL, encoding: .utf8)
        return try QuickJSProviderPluginEngine.make(
            source: source,
            preludeSource: preludeSource,
            transport: ProviderHTTPTransportHandler { _ in throw URLError(.unsupportedURL) },
            timeout: ProviderPluginRuntime.defaultTimeout,
            responseSizeLimit: ProviderPluginRuntime.maximumResponseBytes,
            rejectsNonSuccessResponses: false,
            allowsDynamicID: false,
            workerStackSizeBytes: workerStackSizeBytes)
    }

    private static func fetchUsage(engine: QuickJSProviderPluginEngine) async throws -> UsageSnapshot {
        let result = await withCheckedContinuation { continuation in
            engine.fetch(
                settings: [:],
                secrets: ["TEST_KEY": "secret"],
                now: Date(),
                timeZone: .current,
                contextOptions: .production,
                cookieResolver: nil,
                instanceCookieResolver: nil)
            { continuation.resume(returning: $0) }
        }
        return try result.get()
    }

    private static func transport(
        recorder: RequestRecorder,
        body: String = #"{"ok":true}"#) -> ProviderHTTPTransportHandler
    {
        ProviderHTTPTransportHandler { request in
            await recorder.append(request)
            let response = try #require(HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]))
            return (Data(body.utf8), response)
        }
    }
}

private actor TransportCancellationProbe {
    private var cancelled = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func markCancelled() {
        self.cancelled = true
        for waiter in self.waiters {
            waiter.resume()
        }
        self.waiters.removeAll()
    }

    func waitUntilCancelled() async {
        if self.cancelled { return }
        await withCheckedContinuation { continuation in
            self.waiters.append(continuation)
        }
    }
}

private actor CookieAccessRecorder {
    let header: String
    private(set) var domains: [String] = []

    init(header: String) {
        self.header = header
    }

    func resolve(provider _: UsageProvider, domain: String) throws -> String {
        self.domains.append(domain)
        return self.header
    }
}

private actor RequestRecorder {
    private var requests: [URLRequest] = []

    var isEmpty: Bool {
        self.requests.isEmpty
    }

    var first: URLRequest? {
        self.requests.first
    }

    var all: [URLRequest] {
        self.requests
    }

    func append(_ request: URLRequest) {
        self.requests.append(request)
    }
}
