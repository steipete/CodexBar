import Foundation
import Testing
@testable import CodexBarCore

struct GrokLocalSessionScannerFixture {
    let root: URL
    let session: URL
}

protocol GrokLocalSessionScannerTestSupport {}

extension GrokLocalSessionScannerTestSupport {
    func makeFixture() throws -> GrokLocalSessionScannerFixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("grok-session-scan-\(UUID().uuidString)", isDirectory: true)
        let session = root.appendingPathComponent(
            "sessions/%2Ftmp%2Fdemo/session-a",
            isDirectory: true)
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
        return GrokLocalSessionScannerFixture(root: root, session: session)
    }

    func summarize(fixture: GrokLocalSessionScannerFixture, now: Date) throws -> GrokLocalSessionSummary {
        try GrokLocalSessionScanner.summarize(
            env: ["GROK_HOME": fixture.root.path],
            lookbackDays: 7,
            now: now,
            modelsDevCatalog: Self.catalog())
    }

    func localDate(day: Int, hour: Int, minute: Int = 0) throws -> Date {
        try #require(Calendar.current.date(from: DateComponents(
            year: 2026,
            month: 8,
            day: day,
            hour: hour,
            minute: minute)))
    }

    func turn(
        timestamp: Date,
        usage: [String: Any],
        method: String = "_x.ai/session/update") -> [String: Any]
    {
        [
            "timestamp": Int(timestamp.timeIntervalSince1970),
            "method": method,
            "params": [
                "sessionId": "fixture-session",
                "update": [
                    "sessionUpdate": "turn_completed",
                    "stop_reason": "end_turn",
                    "usage": usage,
                ],
            ],
        ]
    }

    func singleModelUsage(input: Int, output: Int, costUsdTicks: Int? = nil) -> [String: Any] {
        self.usage(
            input: input,
            output: output,
            modelCalls: 1,
            costUsdTicks: costUsdTicks,
            modelUsage: [
                "grok-4.6-build": self.modelUsage(
                    input: input,
                    output: output,
                    modelCalls: 1,
                    costUsdTicks: costUsdTicks),
            ])
    }

    func usage(
        input: Int,
        output: Int,
        cachedRead: Int = 0,
        cacheCreation: Int = 0,
        reasoning: Int = 0,
        modelCalls: Int?,
        costUsdTicks: Int? = nil,
        modelUsage: [String: [String: Any]]) -> [String: Any]
    {
        var result: [String: Any] = [
            "inputTokens": input,
            "outputTokens": output,
            "totalTokens": input + output,
            "cachedReadTokens": cachedRead,
            "cacheCreationTokens": cacheCreation,
            "reasoningTokens": reasoning,
            "modelUsage": modelUsage,
            "numTurns": modelCalls ?? 1,
        ]
        if let modelCalls {
            result["modelCalls"] = modelCalls
        }
        // Omitted by default so the existing suites keep exercising the public-card fallback; a test that
        // wants the recorded-spend path asks for it explicitly.
        if let costUsdTicks {
            result["costUsdTicks"] = costUsdTicks
        }
        return result
    }

    func modelUsage(
        input: Int,
        output: Int,
        cachedRead: Int = 0,
        cacheCreation: Int = 0,
        reasoning: Int = 0,
        modelCalls: Int?,
        costUsdTicks: Int? = nil) -> [String: Any]
    {
        var result: [String: Any] = [
            "inputTokens": input,
            "outputTokens": output,
            "totalTokens": input + output,
            "cachedReadTokens": cachedRead,
            "cacheCreationTokens": cacheCreation,
            "reasoningTokens": reasoning,
        ]
        if let modelCalls {
            result["modelCalls"] = modelCalls
        }
        if let costUsdTicks {
            result["costUsdTicks"] = costUsdTicks
        }
        return result
    }

    func writeUpdates(
        _ objects: [[String: Any]],
        rawLines: [String] = [],
        to url: URL,
        modificationDate: Date) throws
    {
        let encoded = try objects.map { object -> String in
            let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            return try #require(String(data: data, encoding: .utf8))
        }
        let contents = (encoded + rawLines).joined(separator: "\n") + "\n"
        try Data(contents.utf8).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: modificationDate], ofItemAtPath: url.path)
    }

    func writeSignals(model: String, tokens: Int, to url: URL, modificationDate: Date) throws {
        let payload: [String: Any] = [
            "contextTokensUsed": tokens,
            "totalTokensBeforeCompaction": tokens,
            "primaryModelId": model,
            "modelsUsed": [model],
        ]
        try JSONSerialization.data(withJSONObject: payload).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: modificationDate], ofItemAtPath: url.path)
    }

    func expectedStandardCost(
        input: Int,
        output: Int,
        cachedRead: Int,
        cacheCreation: Int) -> Double
    {
        let uncached = input - cachedRead - cacheCreation
        return (Double(uncached) * 2e-6)
            + (Double(cachedRead) * 0.5e-6)
            + (Double(cacheCreation) * 2e-6)
            + (Double(output) * 6e-6)
    }

    func expectedLongContextCost(
        input: Int,
        output: Int,
        cachedRead: Int,
        cacheCreation: Int) -> Double
    {
        let uncached = input - cachedRead - cacheCreation
        return (Double(uncached) * 4e-6)
            + (Double(cachedRead) * 1e-6)
            + (Double(cacheCreation) * 4e-6)
            + (Double(output) * 12e-6)
    }

    static func catalog() throws -> ModelsDevCatalog {
        let json = """
        {
          "xai": {
            "id": "xai",
            "models": {
              "grok-4.6": {
                "id": "grok-4.6",
                "cost": {
                  "input": 2,
                  "output": 6,
                  "cache_read": 0.5,
                  "context_over_200k": {
                    "input": 4,
                    "output": 12,
                    "cache_read": 1
                  }
                }
              },
              "grok-build-0.1": {
                "id": "grok-build-0.1",
                "cost": {
                  "input": 10,
                  "output": 20,
                  "cache_read": 2
                }
              }
            }
          }
        }
        """
        return try JSONDecoder().decode(ModelsDevCatalog.self, from: Data(json.utf8))
    }
}
