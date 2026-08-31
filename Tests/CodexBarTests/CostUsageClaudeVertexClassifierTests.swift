import Foundation
import Testing
@testable import CodexBarCore

struct CostUsageClaudeVertexClassifierTests {
    private static func fixtures() throws -> [[String: Any]] {
        var fixtures: [[String: Any]] = [
            [:], ["vertex": false], ["GCP": 0], ["vertex_enabled": NSNull()],
            ["metadata": ["provider": "anthropic"]],
            ["request": ["API_PROVIDER": "Google-Vertex-AI"]],
            ["context": ["client": ["backend": "vertex"]]],
            ["client": ["nested": [["platform": "vertexai"]]]],
            ["message": ["metadata": ["source": "VERTEX"]]],
            ["message": ["request": ["vendor": "vertex"]]],
            ["message": ["content": [["type": "tool_use", "input": ["gcp_project": false]]]]],
            ["message": ["content": [["type": "text", "text": "vertex"]]]],
            ["metadata": ["provider": false]], ["metadata": ["provider": 1]],
            ["metadata": ["provider": NSNull()]], ["metadata": ["provider": ["vertex"]]],
            ["metadata": ["provider": [["provider": "vertex"]]]],
            ["metadata": ["provider": [[["provider": "vertex"]]]]],
            ["metadata": ["provider": "gcp"]], ["not_provider": "vertex"],
            ["message": ["id": "msg_vrtx_123"]], ["requestId": "req_vrtx_123"],
            ["message": ["id": "msg_VRTX_123"]], ["requestId": "req_vrtx"],
            ["message": ["model": "claude-sonnet-4-6@20260217"]],
            ["message": ["model": "Claude-sonnet-4-6@20260217"]],
            ["message": ["model": "other@20260217"]],
        ]
        let markers = [
            "", "v", "verte", "vertex", "VERTEX", "VeRtEx", "prevertexpost", "vertices", "ver tex",
            "gcp", "GCP", "prefixGCPsuffix", "gc", "gc_p", "vertex\0", "\0vertex", "\r\nvertex",
            "vértex", "ve\u{301}rtex", "verteｘ", "ｖｅｒｔｅｘ", "vertex\u{301}", "gcp\u{301}",
            "日本vertex", "vertex🦞", "İVERTEX", "VERTEXİ", "ver\u{200D}tex", "\u{FEFF}vertex",
        ]
        let providerKeys = [
            "provider", "platform", "backend", "api_provider", "apiprovider", "api_type", "apitype",
            "source", "vendor", "client", "PROVIDER", "Api_Provider", "provider_suffix", "proviDERİ",
        ]
        for marker in markers {
            fixtures.append([marker: false])
            for key in providerKeys {
                fixtures.append(["metadata": [key: marker]])
            }
        }
        for body in [
            String(repeating: "synthetic text 123. ", count: 2048),
            String(repeating: "synthetic café 日本 🦞. ", count: 2048),
        ] {
            fixtures.append(["message": ["content": [["type": "text", "text": body + "vertex"]]]])
            fixtures.append(["metadata": ["provider": body]])
            fixtures.append(["metadata": ["provider": body + "VERTEX"]])
            fixtures.append([body + "GCP": 0])
        }
        // Decode escaped keys/values first, exactly as the JSONL ingestion path does.
        for json in [
            #"{"metadata":{"pro\u0076ider":"\u0076ertex"}}"#,
            #"{"metadata":{"\u0067cp":false}}"#,
            #"{"metadata":{"provider":"vertex\u0301"}}"#,
            #"{"metadata":{"provider":"\u65e5\u672cVERTEX"}}"#,
        ] {
            try fixtures.append(#require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]))
        }
        return try fixtures.map {
            try #require(JSONSerialization.jsonObject(
                with: JSONSerialization.data(withJSONObject: $0)) as? [String: Any])
        }
    }

    @Test
    func `decoded metadata preserves historical classification`() throws {
        for (index, fixture) in try Self.fixtures().enumerated() {
            #expect(
                CostUsageScanner.isVertexAIUsageEntry(obj: fixture)
                    == LegacyClaudeVertexClassifier.isVertexAIUsageEntry(obj: fixture),
                "fixture \(index)")
        }
        // Lock down surprising existing rules independently of the differential oracle.
        #expect(CostUsageScanner.isVertexAIUsageEntry(obj: ["vertex": false]))
        #expect(CostUsageScanner.isVertexAIUsageEntry(obj: ["GCP": 0]))
        #expect(!CostUsageScanner.isVertexAIUsageEntry(obj: ["provider": "gcp"]))
        #expect(!CostUsageScanner.isVertexAIUsageEntry(obj: ["nested": [[["provider": "vertex"]]]]))
        #expect(!CostUsageScanner.isVertexAIUsageEntry(obj: ["text": "vertex"]))
    }

    @Test
    func `Claude and Vertex ingestion preserve historical rows days tokens and costs`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "America/Los_Angeles"))
        let timestamps = ["2026-08-29T06:59:59.123Z", "2026-08-29T07:00:00Z", "2026-08-30T07:00:00Z"]
        let since = Date(timeIntervalSince1970: 1_787_875_200)
        let until = Date(timeIntervalSince1970: 1_788_130_800)
        let range = CostUsageScanner.CostUsageDayRange(since: since, until: until, calendar: calendar)
        let entries = try Self.fixtures().enumerated().map { index, fixture in
            var entry = fixture
            entry["type"] = "assistant"
            entry["timestamp"] = timestamps[index % timestamps.count]
            entry["requestId"] = entry["requestId"] ?? "request-\(index)"
            var message = entry["message"] as? [String: Any] ?? [:]
            message["id"] = message["id"] ?? "message-\(index)"
            message["model"] = message["model"] ?? "claude-sonnet-4-6"
            message["usage"] = [
                "input_tokens": 200 + index, "output_tokens": 80,
                "cache_creation_input_tokens": 50, "cache_read_input_tokens": 25,
                "cache_creation": ["ephemeral_1h_input_tokens": 20],
            ] as [String: Any]
            entry["message"] = message
            return entry
        }
        let vertex = entries.filter { LegacyClaudeVertexClassifier.isVertexAIUsageEntry(obj: $0) }
        let claude = entries.filter { !LegacyClaudeVertexClassifier.isVertexAIUsageEntry(obj: $0) }
        #expect(!vertex.isEmpty && !claude.isEmpty)
        let malformed = "{invalid json}\n{\"type\":\"assistant\",\"usage\":null}\n"
        let allFile = try env.writeClaudeProjectFile(
            relativePath: "all/session.jsonl", contents: env.jsonl(entries) + malformed)
        for (name, filter, expectedEntries, provider) in [
            ("claude", CostUsageScanner.ClaudeLogProviderFilter.excludeVertexAI, claude, UsageProvider.claude),
            ("vertex", .vertexAIOnly, vertex, .vertexai),
        ] {
            let expectedFile = try env.writeClaudeProjectFile(
                relativePath: "\(name)/session.jsonl", contents: env.jsonl(expectedEntries))
            let expected = CostUsageScanner.parseClaudeFile(
                fileURL: expectedFile,
                range: range,
                providerFilter: .all,
                modelsDevCatalog: ModelsDevCatalog(providers: [:]),
                modelsDevCacheRoot: env.cacheRoot)
            let actual = CostUsageScanner.parseClaudeFile(
                fileURL: allFile,
                range: range,
                providerFilter: filter,
                modelsDevCatalog: ModelsDevCatalog(providers: [:]),
                modelsDevCacheRoot: env.cacheRoot)
            #expect(actual.rows == expected.rows)
            #expect(actual.rows.count == expectedEntries.count)
            #expect(actual.days == expected.days)
            #expect(actual.days.count == 3)
            #expect(actual.rows.contains { $0.costNanos > 0 })
            #expect(try actual.parsedBytes == Int64(Data(((env.jsonl(entries)) + malformed).utf8).count))

            var options = CostUsageScanner.Options(
                claudeProjectsRoots: [allFile.deletingLastPathComponent()],
                cacheRoot: env.cacheRoot.appendingPathComponent(name),
                calendar: calendar)
            options.claudeLogProviderFilter = filter
            options.refreshMinIntervalSeconds = 0
            let actualReport = CostUsageScanner.loadDailyReport(
                provider: provider, since: since, until: until, now: until, options: options)
            options.claudeProjectsRoots = [expectedFile.deletingLastPathComponent()]
            options.cacheRoot = env.cacheRoot.appendingPathComponent("expected-\(name)")
            options.claudeLogProviderFilter = .all
            let expectedReport = CostUsageScanner.loadDailyReport(
                provider: .claude, since: since, until: until, now: until, options: options)
            #expect(actualReport.data == expectedReport.data)
            #expect(actualReport.summary == expectedReport.summary)
        }
    }
}

/// Frozen pre-optimization predicate: keep traversal and Foundation string semantics independent.
private enum LegacyClaudeVertexClassifier {
    private static let vertexProviderKeys: Set<String> = [
        "provider",
        "platform",
        "backend",
        "api_provider",
        "apiprovider",
        "api_type",
        "apitype",
        "source",
        "vendor",
        "client",
    ]

    static func isVertexAIUsageEntry(obj: [String: Any]) -> Bool {
        // Primary detection: Vertex AI message IDs and request IDs have "vrtx" prefix
        // e.g., "msg_vrtx_0154LUXjFVzQGUca3yK2RUeo", "req_vrtx_011CWjK86SWeFuXqZKUtgB1H"
        if let message = obj["message"] as? [String: Any],
           let messageId = message["id"] as? String,
           messageId.contains("_vrtx_")
        {
            return true
        }
        if let requestId = obj["requestId"] as? String,
           requestId.contains("_vrtx_")
        {
            return true
        }

        // Secondary detection: model name with @ version separator (Vertex AI format)
        // e.g., "claude-opus-4-5@20251101" vs "claude-opus-4-5-20251101"
        if let message = obj["message"] as? [String: Any],
           let model = message["model"] as? String,
           Self.modelNameLooksVertex(model)
        {
            return true
        }

        // Fallback: check for explicit Vertex AI metadata fields
        var candidates: [[String: Any]] = [obj]
        if let metadata = obj["metadata"] as? [String: Any] {
            candidates.append(metadata)
        }
        if let request = obj["request"] as? [String: Any] {
            candidates.append(request)
        }
        if let context = obj["context"] as? [String: Any] {
            candidates.append(context)
        }
        if let client = obj["client"] as? [String: Any] {
            candidates.append(client)
        }
        if let message = obj["message"] as? [String: Any] {
            if let metadata = message["metadata"] as? [String: Any] {
                candidates.append(metadata)
            }
            if let request = message["request"] as? [String: Any] {
                candidates.append(request)
            }
        }

        return candidates.contains { Self.containsVertexAIMetadata(in: $0) }
    }

    /// Detects Vertex AI model names by format.
    /// Vertex AI uses @ for version separator: claude-opus-4-5@20251101
    /// Anthropic API uses -: claude-opus-4-5-20251101
    private static func modelNameLooksVertex(_ model: String) -> Bool {
        // Vertex AI model format: claude-{variant}@{version}
        // Examples: claude-opus-4-5@20251101, claude-sonnet-4-5@20250514
        guard model.hasPrefix("claude-") else { return false }
        return model.contains("@")
    }

    private static func containsVertexAIMetadata(in dict: [String: Any]) -> Bool {
        for (key, value) in dict {
            let lowerKey = key.lowercased()
            if lowerKey.contains("vertex") || lowerKey.contains("gcp") {
                return true
            }
            if Self.vertexProviderKeys.contains(lowerKey),
               let text = value as? String,
               Self.stringLooksVertex(text)
            {
                return true
            }
            if let nested = value as? [String: Any] {
                if Self.containsVertexAIMetadata(in: nested) {
                    return true
                }
            } else if let array = value as? [Any] {
                if Self.containsVertexAIMetadata(in: array) {
                    return true
                }
            }
        }

        return false
    }

    private static func containsVertexAIMetadata(in array: [Any]) -> Bool {
        for entry in array {
            if let dict = entry as? [String: Any] {
                if self.containsVertexAIMetadata(in: dict) {
                    return true
                }
            }
        }

        return false
    }

    private static func stringLooksVertex(_ value: String) -> Bool {
        value.lowercased().contains("vertex")
    }
}
