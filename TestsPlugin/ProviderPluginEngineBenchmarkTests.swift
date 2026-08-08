#if os(macOS)
import Darwin
import Foundation
import Testing
@testable import CodexBarCore

struct ProviderPluginEngineBenchmarkTests {
    private static let bundledPlugins = [
        "clawrouter", "crof", "deepgram", "manus", "openai", "openrouter", "perplexity", "poe", "qoder",
        "sub2api", "synthetic", "t3chat", "venice", "xai", "zai",
    ]
    private static let creationSamples = 5
    private static let fetchIterations = 50
    private static let now = Date(timeIntervalSince1970: 1_785_816_000)

    @Test
    func `compare provider plugin engines`() async throws {
        guard ProcessInfo.processInfo.environment["CODEXBAR_PLUGIN_BENCHMARK"] == "1" else { return }

        let javaScriptCore = try await self.measure(engine: .javaScriptCore, label: "JavaScriptCore")
        let quickJS = try await self.measure(engine: .quickJS, label: "QuickJS")
        Self.printCreationTable([javaScriptCore, quickJS])
        Self.printFetchTable([javaScriptCore, quickJS])
    }

    private func measure(engine: ProviderPluginEngineKind, label: String) async throws -> EngineResult {
        var creationMilliseconds: [String: Double] = [:]
        for plugin in Self.bundledPlugins {
            var samples: [Double] = []
            for _ in 0..<Self.creationSamples {
                let started = ContinuousClock.now
                let runtime = try Self.runtime(plugin: plugin, engine: engine, transport: Self.fixtureTransport())
                samples.append(Self.milliseconds(since: started))
                withExtendedLifetime(runtime) {}
            }
            creationMilliseconds[plugin] = samples.sorted()[samples.count / 2]
        }

        let memoryBefore = Self.physicalFootprintBytes()
        var peakMemory = memoryBefore
        var retainedContexts: [ProviderPluginRuntime] = []
        for plugin in Self.bundledPlugins {
            try retainedContexts.append(Self.runtime(
                plugin: plugin,
                engine: engine,
                transport: Self.fixtureTransport()))
            peakMemory = max(peakMemory, Self.physicalFootprintBytes())
        }
        let memoryDeltaPerContext = Double(peakMemory - memoryBefore) / Double(retainedContexts.count)
        withExtendedLifetime(retainedContexts) {}

        var fetchMilliseconds: [String: Double] = [:]
        for plugin in ["poe", "openrouter", "crof"] {
            let runtime = try Self.runtime(plugin: plugin, engine: engine, transport: Self.fixtureTransport())
            _ = try await Self.fetch(plugin: plugin, runtime: runtime)
            let started = ContinuousClock.now
            for _ in 0..<Self.fetchIterations {
                _ = try await Self.fetch(plugin: plugin, runtime: runtime)
            }
            fetchMilliseconds[plugin] = Self.milliseconds(since: started)
        }

        return EngineResult(
            label: label,
            creationMilliseconds: creationMilliseconds,
            fetchMilliseconds: fetchMilliseconds,
            memoryDeltaPerContextBytes: memoryDeltaPerContext)
    }

    private static func runtime(
        plugin: String,
        engine: ProviderPluginEngineKind,
        transport: any ProviderHTTPTransport) throws -> ProviderPluginRuntime
    {
        let bundle = try #require(CodexBarCoreResources.bundle)
        let sourceURL = try #require(bundle.url(forResource: plugin, withExtension: "js"))
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        try ProviderPluginSourceLint.validateBundled(source, name: plugin)
        return try ProviderPluginRuntime(source: source, transport: transport, engine: engine)
    }

    private static func fetch(plugin: String, runtime: ProviderPluginRuntime) async throws -> UsageSnapshot {
        let secretKey = switch plugin {
        case "poe": "POE_API_KEY"
        case "openrouter": "OPENROUTER_API_KEY"
        case "crof": "CROF_API_KEY"
        default: preconditionFailure("missing benchmark secret for \(plugin)")
        }
        return try await runtime.fetchUsage(secrets: [secretKey: "fixture-key"], now: Self.now)
    }

    private static func fixtureTransport() -> ProviderHTTPTransportHandler {
        ProviderHTTPTransportHandler { request in
            let body: String
            switch request.url?.path {
            case "/usage/current_balance":
                body = #"{"current_point_balance":2500}"#
            case "/usage/points_history":
                body = Self.poeHistoryPage(request.url)
            case "/api/v1/credits":
                body = #"{"data":{"total_credits":100,"total_usage":40}}"#
            case "/api/v1/key":
                body = #"{"data":{"limit":20,"limit_remaining":15,"limit_reset":"monthly","usage":5,"usage_daily":1,"usage_weekly":2,"usage_monthly":4,"rate_limit":{"requests":120,"interval":"10s"}}}"#
            case "/usage_api", "/usage_api/":
                body = #"{"credits":9.9999,"requests_plan":1000,"usable_requests":998}"#
            default:
                throw BenchmarkError.unexpectedURL(request.url)
            }
            let response = try #require(HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]))
            return (Data(body.utf8), response)
        }
    }

    private static func poeHistoryPage(_ url: URL?) -> String {
        let components = url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }
        let cursor = components?.queryItems?.first(where: { $0.name == "starting_after" })?.value
        let page = cursor.flatMap { Int($0.replacingOccurrences(of: "page-", with: "")) } ?? 0
        let entries = (0..<100).map { index in
            let queryID = "entry-\(page)-\(index)"
            let points = Double((page * 100) + index + 1) / 10
            return #"{"query_id":"\#(queryID)","creation_time":1785772800000000,"bot_name":"fixture-model","usage_type":"API","cost_points":\#(points),"cost_usd":0.01}"#
        }.joined(separator: ",")
        let nextCursor = page < 4 ? #""page-\#(page + 1)""# : "null"
        return #"{"data":[\#(entries)],"next_cursor":\#(nextCursor)}"#
    }

    private static func physicalFootprintBytes() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : 0
    }

    private static func milliseconds(since started: ContinuousClock.Instant) -> Double {
        let duration = started.duration(to: .now)
        return Double(duration.components.seconds) * 1000
            + Double(duration.components.attoseconds) / 1_000_000_000_000_000
    }

    private static func printCreationTable(_ results: [EngineResult]) {
        print("\nProvider plugin creation + manifest load (median of \(self.creationSamples), milliseconds)")
        print("| Plugin | JavaScriptCore | QuickJS |")
        print("| --- | ---: | ---: |")
        for plugin in self.bundledPlugins {
            let values = results.map { $0.creationMilliseconds[plugin, default: 0] }
            print(String(format: "| %@ | %.3f | %.3f |", plugin, values[0], values[1]))
        }
    }

    private static func printFetchTable(_ results: [EngineResult]) {
        print("\nProvider plugin fetch benchmark (\(self.fetchIterations) iterations, milliseconds)")
        print("| Engine | Poe | OpenRouter | Crof | Rough peak memory delta/context |")
        print("| --- | ---: | ---: | ---: | ---: |")
        for result in results {
            print(String(
                format: "| %@ | %.3f | %.3f | %.3f | %.1f KiB |",
                result.label,
                result.fetchMilliseconds["poe", default: 0],
                result.fetchMilliseconds["openrouter", default: 0],
                result.fetchMilliseconds["crof", default: 0],
                result.memoryDeltaPerContextBytes / 1024))
        }
    }
}

private struct EngineResult {
    let label: String
    let creationMilliseconds: [String: Double]
    let fetchMilliseconds: [String: Double]
    let memoryDeltaPerContextBytes: Double
}

private enum BenchmarkError: LocalizedError {
    case unexpectedURL(URL?)

    var errorDescription: String? {
        switch self {
        case let .unexpectedURL(url): "unexpected benchmark URL: \(url?.absoluteString ?? "nil")"
        }
    }
}
#endif
