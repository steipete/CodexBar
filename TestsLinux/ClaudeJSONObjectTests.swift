import Foundation
import Testing
@testable import CodexBarCore

struct ClaudeJSONObjectTests {
    @Test
    func `container view rejects whole mixed objects and unsupported scalars`() throws {
        for value: Any in [NSNumber(value: 2), true, NSNull(), "vertex", [], NSObject()] {
            #expect(ClaudeJSONObject(value) == nil)
            #expect(!CostUsageScanner.isVertexAIUsageEntry(obj: value))
        }
        let mixed: NSDictionary = ["vertex": false, 1: "bad"]
        #expect((mixed as? [String: Any]) == nil)
        #expect(ClaudeJSONObject(mixed) == nil)
        for root: [String: Any] in [
            ["metadata": mixed], ["nested": [mixed]],
            ["message": NSDictionary(dictionary: ["id": "msg_vrtx_1", 1: true])],
            ["nested": [[["vertex": false]]]],
            ["scalar": NSObject()], ["scalar": Date(timeIntervalSince1970: 0)],
        ] {
            #expect(!CostUsageScanner.isVertexAIUsageEntry(obj: root))
        }
        #expect(CostUsageScanner.isVertexAIUsageEntry(obj: ["nested": [["vertex": false]]]))
        #expect(try #require(ClaudeJSONObject([:])).contains { _, _ in true } == false)
    }

    @Test
    func `Unicode objects expose only entries surviving Swift shallow coercion`() throws {
        let raw = #"{"café":{"provider":"vertex"},"cafe\u0301":{"provider":"anthropic"},"K":1,"\u212a":2}"#
        let decoded = try JSONSerialization.jsonObject(with: Data(raw.utf8))
        let legacy = try #require(decoded as? [String: Any])
        #expect(legacy.count == 2)
        let view = try #require(try ClaudeJSONObject.decode(Data(raw.utf8)))
        var visited: [String: ClaudeJSONValue] = [:]
        var visits = 0
        _ = view.contains { key, value in
            visits += 1
            visited[key] = value
            return false
        }
        // Collision winners can vary between independent Swift bridges; assert the resolved view itself.
        #expect(visits == legacy.count)
        #expect(visited.count == visits)
        #expect((view["K"] as? NSNumber)?.intValue == 1 || (view["K"] as? NSNumber)?.intValue == 2)
        let nested = try #require(view.dictionary("café"))
        let visitedNested = try #require(visited["café"]?.dictionary)
        #expect(nested["provider"] as? String == visitedNested["provider"] as? String)
        #expect(try ["vertex", "anthropic"].contains(#require(nested["provider"] as? String)))
        #expect(CostUsageScanner.isVertexAIUsageEntry(obj: view) == (nested["provider"] as? String == "vertex"))
        #expect((view["cafe\u{301}"] as? NSDictionary) == (view["café"] as? NSDictionary))
    }

    @Test
    func `decoded fields retain bytes and Foundation scalar coercions`() throws {
        let raw = #"{"message":{"model":"claude-test-cafe\u0301","usage":{"input_tokens":true,"output_tokens":"2","cache_creation_input_tokens":2,"cache_creation":{"ephemeral_1h_input_tokens":false}}},"isSidechain":2,"empty":[],"object":{}}"#
        let view = try #require(try ClaudeJSONObject.decode(Data(raw.utf8)))
        let message = try #require(view.dictionary("message"))
        let usage = try #require(message.dictionary("usage"))
        #expect(try Array(#require(message["model"] as? String).utf8) == Array("claude-test-cafe\u{301}".utf8))
        #expect((usage["input_tokens"] as? NSNumber)?.intValue == 1)
        #expect((usage["output_tokens"] as? NSNumber) == nil)
        #expect((view["isSidechain"] as? NSNumber)?.boolValue == true)
        #expect((usage.dictionary("cache_creation")?["ephemeral_1h_input_tokens"] as? NSNumber)?.intValue == 0)
        #expect(try !ClaudeJSONValue(#require(view["empty"])).arrayContainsDictionary { _ in true })
        #expect(try #require(view.dictionary("object")).contains { _, _ in true } == false)
    }
}
