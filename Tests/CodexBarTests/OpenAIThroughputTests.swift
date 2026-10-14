import Foundation
import Testing
@testable import CodexBarCore

struct OpenAIThroughputTests {
    #if canImport(JavaScriptCore)
    static let engines: [ProviderPluginEngineKind] = [.quickJS, .javaScriptCore]
    #else
    static let engines: [ProviderPluginEngineKind] = [.quickJS]
    #endif
    static let now = Date(timeIntervalSince1970: 120_025)
    static let model = "model-fixture"
    static let empty = #"{"data":[],"has_more":false}"#

    @Test(arguments: Self.engines)
    func `live throughput does not count audio breakdowns twice`(engine: ProviderPluginEngineKind) async throws {
        // input_tokens/output_tokens already include the audio portions reported in the breakdown fields.
        let body = #"""
        {"data":[{"start_time":119760,"end_time":119820,"results":[{
          "model":"model-fixture","input_tokens":100,"input_audio_tokens":40,"input_cached_tokens":60,
          "output_tokens":15,"output_audio_tokens":5,"num_model_requests":2
        }]}],"has_more":false}
        """#
        let result = try await Self.runtime(transport: Transport(liveBody: body), engine: engine).fetchResult(
            settings: ["OPENAI_HISTORY_DAYS": "1"],
            secrets: ["OPENAI_API_KEY": "synthetic-admin-key"],
            now: Self.now)
        let throughput = try #require(result.usage.throughput)
        #expect(throughput.peakTokensPerMinute == 115)
        #expect(throughput.models.first?.peakLimitCountedTokens == 115)
        let swift = try await OpenAILiveUsageFetcher(transport: Transport(liveBody: body))
            .fetch(environment: ["OPENAI_ADMIN_KEY": "synthetic-admin-key"], now: Self.now)
        #expect(swift.throughput == throughput)
    }

    @Test(arguments: Self.engines)
    func `plugin requests one scoped minute page and maps lagging throughput`(
        engine: ProviderPluginEngineKind) async throws
    {
        let transport = Transport(liveBody: Self.livePage)
        let runtime = try Self.runtime(
            transport: transport,
            engine: engine)
        let result = try await runtime.fetchResult(
            settings: ["OPENAI_HISTORY_DAYS": "1", "OPENAI_PROJECT_ID": "proj_fixture & scope"],
            secrets: ["OPENAI_API_KEY": "synthetic-admin-key"],
            now: Self.now)
        let requests = await transport.requests
        #expect(requests.count == 3)
        let url = try #require(requests.last?.url)
        let query = try #require(URLComponents(
            url: url,
            resolvingAgainstBaseURL: false))
        let items = query.queryItems ?? []
        #expect(items.filter { $0.name == "group_by" }.map(\.value) == ["model", "batch"])
        let values = Dictionary(uniqueKeysWithValues: items.filter { $0.name != "group_by" }
            .map { ($0.name, $0.value ?? "") })
        #expect(values == [
            "start_time": "116460", "end_time": "120025", "bucket_width": "1m",
            "limit": "60", "project_ids": "proj_fixture & scope",
        ])
        let throughput = try #require(result.usage.throughput)
        #expect(throughput.minutes.count == 60)
        #expect(throughput.frontier == Date(timeIntervalSince1970: 119_820))
        #expect(throughput.latestTokensPerMinute == 75_000_000)
        #expect(throughput.peakTokensPerMinute == 97_000_000)
        #expect(throughput.peakAt == Date(timeIntervalSince1970: 119_760))
        #expect(throughput.fiveMinuteAverageTokensPerMinute == 34_400_000)
        #expect(throughput.minutes.suffix(3).filter { !$0.isPending }.isEmpty)
        #expect(throughput.models.first?.peakLimitCountedTokens == 97_000_000)
        #expect(throughput.projectID == "proj_fixture & scope")
        #expect(result.usage.openAIAPIUsage != nil)
        let swift = try await OpenAILiveUsageFetcher(transport: Transport(liveBody: Self.livePage))
            .fetch(
                environment: ["OPENAI_ADMIN_KEY": "synthetic-admin-key", "OPENAI_PROJECT_ID": "proj_fixture & scope"],
                now: Self.now)
        #expect(swift.throughput == throughput)
        let mapped = try await Self.mappedLive(
            Self.liveSource(Self.livePayload),
            engine: engine)
        let mappedSnapshot = try OpenAIAPIProviderDescriptor.mapLiveUsage(
            JSONProviderPluginValue(Self.livePayload),
            projectID: nil,
            maximumEntries: 10000)
        #expect(mapped.throughput == mappedSnapshot.throughput)
        #expect(mappedSnapshot.throughput.projectID == nil)
        #expect(mappedSnapshot.minutes == swift.minutes)
    }

    @Test(arguments: Self.engines)
    func `live failures preserve daily data and disabled setting omits the request`(
        engine: ProviderPluginEngineKind) async throws
    {
        for (code, body) in [(500, "{}"), (429, "{}"), (200, "malformed"), (200, #"{"data":false}"#)] {
            let transport = Transport(
                liveBody: body,
                liveStatus: code)
            let runtime = try Self.runtime(
                transport: transport,
                engine: engine)
            let result = try await runtime.fetchResult(
                settings: ["OPENAI_HISTORY_DAYS": "1"],
                secrets: ["OPENAI_API_KEY": "synthetic-admin-key"],
                now: Self.now)
            #expect(result.usage.throughput == nil)
            #expect(result.usage.openAIAPIUsage != nil)
            #expect(result.sourceLabel == "admin-api")
            #expect(await transport.requests.count == 3)
        }
        let transport = Transport(liveBody: Self.livePage)
        let runtime = try Self.runtime(
            transport: transport,
            engine: engine)
        let result = try await runtime.fetchResult(
            settings: ["OPENAI_HISTORY_DAYS": "1", "OPENAI_LIVE_MINUTES": "0"],
            secrets: ["OPENAI_API_KEY": "synthetic-admin-key"],
            now: Self.now)
        #expect(result.usage.throughput == nil)
        #expect(await transport.requests.count == 2)
    }

    @Test(arguments: Self.engines)
    func `invalid live bounds discard only throughput`(engine: ProviderPluginEngineKind) async throws {
        var invalid: [[String: Any]] = []
        for (key, value) in [
            ("windowMinutes", 61), ("startTime", 1), ("fetchedAt", -1),
        ] {
            var payload = Self.livePayload
            payload[key] = value
            invalid.append(payload)
        }
        var payload = Self.livePayload
        payload["buckets"] = Array(
            repeating: ["startTime": 119_820, "models": []] as [String: Any],
            count: 61)
        invalid.append(payload)
        for (field, value) in [
            ("inputTokens", -1.0), ("outputTokens", 1.5), ("requests", 9_007_199_254_740_992.0),
            ("cachedInputTokens", 200.0),
            ("batchTokens", 103.0), ("batchRequests", 2.0),
            ("batchTokens", -1.0), ("batchRequests", -1.0),
            ("batchTokens", 1.5), ("batchRequests", 0.5),
        ] {
            var model: [String: Any] = [
                "name": Self.model,
                "inputTokens": 100,
                "cachedInputTokens": 0,
                "outputTokens": 2,
                "requests": 1,
            ]
            model[field] = value
            var payload = Self.livePayload
            payload["buckets"] = [["startTime": 119_820, "models": [model]]]
            invalid.append(payload)
        }
        for field in ["batchTokens", "batchRequests"] {
            for value in ["1", NSNull(), true] as [Any] {
                var model = Self.cardModel
                model[field] = value
                var payload = Self.livePayload
                payload["buckets"] = [["startTime": 119_820, "models": [model]]]
                invalid.append(payload)
            }
        }
        var tooMany = Self.livePayload
        tooMany["buckets"] = [["startTime": 119_820, "models": Array(
            repeating: Self.cardModel,
            count: 201)]]
        invalid.append(tooMany)
        var globalCap = Self.livePayload
        globalCap["buckets"] = (0..<51).map { index in
            ["startTime": 116_460 + index * 60, "models": Array(
                repeating: Self.cardModel,
                count: 200)] as [String: Any]
        }
        invalid.append(globalCap)
        for live in invalid {
            #expect(throws: ProviderPluginError.self) {
                try OpenAIAPIProviderDescriptor.mapLiveUsage(
                    JSONProviderPluginValue(live), projectID: nil, maximumEntries: 10000)
            }
            let result = try await Self.mappedLive(
                Self.liveSource(live),
                engine: engine)
            #expect(result.throughput == nil)
            #expect(result.openAIAPIUsage != nil)
        }
    }

    @Test(arguments: Self.engines)
    func `batch rows merge identically across plugin and Swift fetches`(engine: ProviderPluginEngineKind) async throws {
        let body = #"""
        {"data":[{"start_time":119820,"end_time":119880,"results":[
          {"model":" model-fixture ","batch":true,"input_tokens":100,"input_cached_tokens":60,
           "output_tokens":20,"num_model_requests":3,"input_audio_tokens":40,"output_audio_tokens":10},
          {"model":"model-fixture","batch":false,"input_tokens":200,"input_cached_tokens":150,
           "output_tokens":30,"num_model_requests":2},
          {"model":"model-second","batch":null,"input_tokens":40,"num_model_requests":1}
        ]}],"has_more":false}
        """#
        let transport = Transport(liveBody: body)
        let result = try await Self.runtime(transport: transport, engine: engine).fetchResult(
            settings: ["OPENAI_HISTORY_DAYS": "1"], secrets: ["OPENAI_API_KEY": "synthetic-admin-key"], now: Self.now)
        let swift = try await OpenAILiveUsageFetcher(transport: Transport(liveBody: body)).fetch(
            environment: ["OPENAI_ADMIN_KEY": "synthetic-admin-key"], now: Self.now)
        #expect(result.usage.throughput == swift.throughput)
        #expect(result.usage.throughput?.models.first?.peakTPM == 350)
        #expect(result.usage.throughput?.models.first?.peakLimitCountedTokens == 230)
        let payload: [String: Any] = [
            "windowMinutes": 60, "startTime": 116_460, "fetchedAt": 120_025,
            "buckets": [["startTime": 119_820, "models": [
                [
                    "name": "model-fixture",
                    "inputTokens": 300,
                    "cachedInputTokens": 210,
                    "outputTokens": 50,
                    "requests": 5,
                    "batchTokens": 120,
                    "batchRequests": 3,
                ],
                [
                    "name": "model-second",
                    "inputTokens": 40,
                    "cachedInputTokens": 0,
                    "outputTokens": 0,
                    "requests": 1,
                    "batchTokens": 0,
                    "batchRequests": 0,
                ],
            ]]],
        ]
        let mapped = try OpenAIAPIProviderDescriptor.mapLiveUsage(
            JSONProviderPluginValue(payload), projectID: nil, maximumEntries: 10000)
        #expect(mapped.minutes == swift.minutes)
        let pluginMapped = try await Self.mappedLive(Self.liveSource(payload), engine: engine)
        #expect(pluginMapped.throughput == swift.throughput)
        let requests = await transport.requests
        let liveURL = try #require(requests.last?.url)
        let items = try #require(URLComponents(
            url: liveURL,
            resolvingAgainstBaseURL: false)?.queryItems)
        #expect(items.filter { $0.name == "group_by" }.map(\.value) == ["model", "batch"])
        #expect(requests.prefix(2).compactMap { $0.url?.absoluteString } == [
            "https://api.openai.com/v1/organization/costs?" +
                "start_time=86400&end_time=172800&bucket_width=1d&limit=1&group_by=line_item",
            "https://api.openai.com/v1/organization/usage/completions?" +
                "start_time=86400&end_time=172800&bucket_width=1d&limit=1&group_by=model",
        ])
        for request in requests.prefix(2) {
            let dailyURL = try #require(request.url)
            let items = try #require(URLComponents(
                url: dailyURL,
                resolvingAgainstBaseURL: false)?.queryItems)
            #expect(items.filter { $0.name == "group_by" }.count == 1)
            #expect(items.first { $0.name == "bucket_width" }?.value == "1d")
        }
    }

    @Test(arguments: Self.engines)
    func `invalid batch types discard only live throughput`(engine: ProviderPluginEngineKind) async throws {
        for batch in ["\"yes\"", "1", "[]", "{}"] {
            let body = """
            {"data":[{"start_time":119820,"end_time":119880,"results":[
              {"model":"model-fixture","batch":\(batch),"input_tokens":10}
            ]}],"has_more":false}
            """
            let result = try await Self.runtime(transport: Transport(liveBody: body), engine: engine).fetchResult(
                settings: ["OPENAI_HISTORY_DAYS": "1"],
                secrets: ["OPENAI_API_KEY": "synthetic-admin-key"],
                now: Self.now)
            #expect(result.usage.throughput == nil)
            #expect(result.usage.openAIAPIUsage != nil)
        }
    }

    @Test(arguments: Self.engines)
    func `live model bounds count merged entries`(engine: ProviderPluginEngineKind) async throws {
        for count in [200, 201] {
            let rows: [[String: Any]] = (0..<count).flatMap { index in
                [true, false].map { batch in
                    ["model": "model-fixture-\(index)", "batch": batch, "input_tokens": 10] as [String: Any]
                }
            }
            // 201 unique models fit the raw cap but exceed the emitted cap.
            let raw = count == 200 ? rows : rows.enumerated().filter { $0.offset.isMultiple(of: 2) }.map(\.element)
            let data = try JSONSerialization.data(withJSONObject: ["data": [
                ["start_time": 119_820, "end_time": 119_880, "results": raw],
            ], "has_more": false])
            let body = try #require(String(data: data, encoding: .utf8))
            let result = try await Self.runtime(
                transport: Transport(liveBody: body),
                engine: engine).fetchResult(
                settings: ["OPENAI_HISTORY_DAYS": "1"],
                secrets: ["OPENAI_API_KEY": "synthetic-admin-key"],
                now: Self.now)
            if count == 200 {
                #expect(result.usage.throughput?.peakTokensPerMinute == 4000)
            } else {
                #expect(result.usage.throughput == nil)
            }
            #expect(result.usage.openAIAPIUsage != nil)
        }
    }

    @Test
    func `older card payloads default batch subsets to zero`() throws {
        let snapshot = try OpenAIAPIProviderDescriptor.mapLiveUsage(
            JSONProviderPluginValue(Self.livePayload), projectID: nil, maximumEntries: 10000)
        #expect(snapshot.minutes.flatMap(\.models).allSatisfy { $0.batchTokens == 0 && $0.batchRequests == 0 })
        #expect(snapshot.series(for: .allModels).allSatisfy {
            $0.limitCountedTokens == $0.totalTokens && $0.limitCountedRequests == $0.requests
        })
        #expect(snapshot.summary(for: .allModels).batchTokens == 0)
    }

    @Test
    func `all compact models retain aligned limit traffic including pending values`() throws {
        let models = (1...7).map { index in
            OpenAILiveUsageSnapshot.ModelUsage(
                name: "model-\(index)",
                inputTokens: index * 10_000_000,
                cachedInputTokens: index * 9_500_000,
                outputTokens: 1_000_000,
                requests: index)
        }
        let snapshot = try OpenAILiveUsageBuilder.build(
            buckets: [.init(
                start: Self.now.addingTimeInterval(-85),
                models: models), .init(
                start: Self.now.addingTimeInterval(-25),
                models: [.init(
                    name: "model-1",
                    inputTokens: 200,
                    cachedInputTokens: 0,
                    outputTokens: 0,
                    requests: 1,
                    batchTokens: 50)])],
            windowMinutes: 60,
            fetchedAt: Self.now,
            projectID: nil)
        let throughput = snapshot.throughput
        #expect(throughput.models.map(\.name) == (1...7).reversed().map { "model-\($0)" })
        for model in throughput.models {
            #expect(model.limitCountedTokensByMinute == snapshot.series(for: .model(model.name))
                .map(\.limitCountedTokens))
            #expect(model.limitCountedTokensByMinute?.count == throughput.minutes.count)
        }
        #expect(throughput.minutes.last?.isPending == true)
        #expect(throughput.models.last?.limitCountedTokensByMinute?.last == 150)
        let limits = OpenAIOrgLimitResolver(
            manual: [.init(
                model: "model-7",
                tokensPerMinute: 40_000_000)],
            projectCaps: nil)
        let utilization = try #require(snapshot.utilization(
            for: .model("model-7"),
            limits: limits))
        #expect(snapshot.summary(for: .model("model-7")).peakTPM == 71_000_000)
        // Cached input counts toward TPM: 71M of a 40M limit.
        #expect(utilization.peakTPMPercent == 177.5)
        #expect(utilization.latestTPMPercent == 177.5)
        #expect(snapshot.highestUtilization(limits: limits)?.peakTPMPercent == 177.5)
        #expect(snapshot.modelRows(limits: limits).first?.peakTPMPercent == 177.5)
    }

    @Test
    func `compact snapshots without minute limit series decode unchanged`() throws {
        let json = #"""
        {"minutes":[{"start":0,"totalTokens":60,"requests":6,"isPending":false}],
         "frontier":0,"latestTokensPerMinute":60,"peakTokensPerMinute":60,"peakAt":0,
         "fiveMinuteAverageTokensPerMinute":60,"models":[
           {"name":"gpt-5","latestTPM":60,"peakTPM":60,"totalTokens":60,"peakLimitCountedTokens":60}],
         "windowMinutes":60,"fetchedAt":60}
        """#
        let snapshot = try JSONDecoder().decode(ProviderThroughputSnapshot.self, from: Data(json.utf8))
        #expect(snapshot.models.first?.limitCountedTokensByMinute == nil)
        #expect(snapshot.models.first?.peakLimitCountedTokens == 60)
        #expect(snapshot.projectID == nil)
    }

    @Test(arguments: Self.engines)
    func `both plugin engines retain all models with aligned standard minute traffic`(
        engine: ProviderPluginEngineKind) async throws
    {
        var payload = Self.livePayload
        payload["buckets"] = [
            ["startTime": 119_820, "models": (1...7).map { index in
                [
                    "name": "model-\(index)",
                    "inputTokens": index * 100,
                    "cachedInputTokens": index * 50,
                    "outputTokens": 0,
                    "requests": index,
                    "batchTokens": index * 10,
                    "batchRequests": 0,
                ]
                    as [String: Any]
            }],
            ["startTime": 120_000, "models": [
                [
                    "name": "model-1",
                    "inputTokens": 1000,
                    "cachedInputTokens": 0,
                    "outputTokens": 0,
                    "requests": 1,
                    "batchTokens": 100,
                    "batchRequests": 0,
                ],
            ]],
        ]
        let mapped = try await Self.mappedLive(Self.liveSource(payload), engine: engine)
        let swift = try OpenAIAPIProviderDescriptor.mapLiveUsage(
            JSONProviderPluginValue(payload), projectID: nil, maximumEntries: 10000)
        let throughput = try #require(mapped.throughput)
        #expect(throughput == swift.throughput)
        #expect(throughput.models.map(\.name) == (1...7).reversed().map { "model-\($0)" })
        #expect(throughput.models.allSatisfy { $0.limitCountedTokensByMinute?.count == throughput.minutes.count })
        #expect(throughput.models.first?.limitCountedTokensByMinute?[56] == 630)
        #expect(throughput.models.last?.limitCountedTokensByMinute?.last == 900)
        #expect(throughput.models.last?.peakLimitCountedTokens == 90)
        #expect(throughput.minutes.last?.isPending == true)
    }

    @Test
    func `old snapshot JSON decodes and snapshot copies preserve throughput`() async throws {
        let snapshot = try await Self.mappedLive(
            Self.liveSource(Self.livePayload),
            engine: .quickJS)
        let encoded = try JSONEncoder().encode(snapshot)
        #expect(try JSONDecoder().decode(
            UsageSnapshot.self,
            from: encoded).throughput == snapshot.throughput)
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "throughput")
        let old = try JSONDecoder().decode(
            UsageSnapshot.self,
            from: JSONSerialization.data(withJSONObject: object))
        #expect(old.throughput == nil)
        #expect(snapshot.withIdentity(nil).throughput == snapshot.throughput)
        #expect(snapshot.with(providerCost: nil).throughput == snapshot.throughput)
        #expect(snapshot.backfillingResetTimes(from: nil).throughput == snapshot.throughput)
    }

    private static var cardModel: [String: Any] {
        [
            "name": model,
            "inputTokens": 74_000_000,
            "cachedInputTokens": 70_400_000,
            "outputTokens": 1_000_000,
            "requests": 50,
        ]
    }

    static var livePayload: [String: Any] {
        var peak = Self.cardModel
        peak["inputTokens"] = 96_000_000
        peak["cachedInputTokens"] = 92_400_000
        return ["windowMinutes": 60, "startTime": 116_460, "fetchedAt": 120_025, "buckets": [
            ["startTime": 119_760, "models": [peak]],
            ["startTime": 119_820, "models": [Self.cardModel]],
        ]]
    }

    static var livePage: String {
        #"""
        {"data":[
          {"start_time":119760,"end_time":119820,"results":[{
            "model":"model-fixture","input_tokens":96000000,"input_cached_tokens":92400000,
            "output_tokens":1000000,"num_model_requests":50
          }]},
          {"start_time":119820,"end_time":119880,"results":[{
            "model":"model-fixture","input_tokens":74000000,"input_cached_tokens":70400000,
            "output_tokens":1000000,"num_model_requests":50
          }]}
        ],"has_more":false}
        """#
    }

    private static func runtime(
        transport: any ProviderHTTPTransport,
        engine: ProviderPluginEngineKind)
        throws -> ProviderPluginRuntime
    {
        let url = try #require(CodexBarCoreResources.bundle?.url(
            forResource: "openai",
            withExtension: "js"))
        return try ProviderPluginRuntime(
            source: String(
                contentsOf: url,
                encoding: .utf8),
            transport: transport,
            engine: engine)
    }

    static func liveSource(_ live: [String: Any]) throws -> String {
        let card: [String: Any] = ["openAIAPIUsage": ["historyDays": 1, "daily": [], "live": live]]
        let encoded = try JSONSerialization.data(withJSONObject: card)
        let json = try #require(String(data: encoded, encoding: .utf8))
        return """
        defineProvider({ id: "openai",
        name: "Fixture",
        endpoints: ["https://api.openai.com"],
        settings: [],
          async fetchUsage() { return {usage: {identity: {loginMethod: "Admin API"}},
          card: \(json)}; }
        });
        """
    }

    static func mappedLive(
        _ source: String,
        engine: ProviderPluginEngineKind) async throws -> UsageSnapshot
    {
        try await ProviderPluginRuntime(
            source: source,
            engine: engine).fetchUsage(now: self.now)
    }

    private actor Transport: ProviderHTTPTransport {
        let liveBody: String
        let liveStatus: Int
        var requests: [URLRequest] = []

        init(
            liveBody: String,
            liveStatus: Int = 200)
        {
            self.liveBody = liveBody
            self.liveStatus = liveStatus
        }

        func data(for request: URLRequest) async throws -> (Data, URLResponse) {
            self.requests.append(request)
            let live = request.url?.query?.contains("bucket_width=1m") == true
            return (Data((live ? self.liveBody : OpenAIThroughputTests.empty).utf8), HTTPURLResponse(
                url: request.url!,
                statusCode: live ? self.liveStatus : 200,
                httpVersion: nil,
                headerFields: nil)!)
        }
    }
}
