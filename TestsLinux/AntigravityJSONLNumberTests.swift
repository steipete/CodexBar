import Foundation
import Testing
@testable import CodexBarCore

struct AntigravityJSONLNumberTests {
    @Test(arguments: [
        "-1e-400", "1e-400", "1e-999", "9.0071992547409931e15", "1.00000000000000001",
        "9223372036854775808", "1e400", "true", "\"1\"", "null", "0.0000001", "1787832000000.0000001",
    ], ["input", "output", "cacheRead", "cacheWrite", "reasoning", "timestamp"])
    func `raw fractional rounded overflowing and nonnumeric usage fields stay unavailable`(
        literal: String, field: String) throws
    {
        let report = try self.report(literal: literal, field: field)
        #expect(report.coverage == .partial)
    }

    @Test(arguments: ["9007199254740993", "9.007199254740993e15", "9007199254740993.0"])
    func `large exact input literals retain every digit`(literal: String) throws {
        let report = try self.report(literal: literal, field: "input")
        #expect(report.coverage == .complete)
        #expect(report.report.summary?.totalTokens == 9_007_199_254_740_993)
    }

    @Test(arguments: ["0", "-0", "0.0", "0e10", "100", "1e2", "10.0e1", "1000e-1", "1.00e+2"])
    func `whole finite producer compatible literals remain supported`(literal: String) throws {
        let report = try self.report(literal: literal, field: "input")
        #expect(report.coverage == .complete)
        #expect(report.report.summary?.totalTokens == (literal.hasPrefix("0") || literal == "-0" ? 0 : 100))
    }

    @Test(arguments: ["9223372036854775807", "92233720368547758070e-1", "9.223372036854775807e18"])
    func `integer boundary is accepted without a floating point round trip`(literal: String) throws {
        let report = try self.report(literal: literal, field: "input")
        #expect(report.coverage == .complete)
        #expect(report.report.summary?.totalTokens == Int.max)
    }

    @Test(arguments: ["01", "+1", ".1", "1.", "1e", "1e+", "--1", "NaN", "Infinity", "0x10"])
    func `numeric masking cannot repair invalid JSON number syntax`(literal: String) throws {
        #expect(try self.report(literal: literal, field: "input").coverage == .partial)
    }

    @Test
    func `escaped keys strings aliases and null retain their JSON types`() throws {
        let text = #"{"in\u0070ut":1e2,"cacheRead":1e1,"cache_read":10.00,"label":"1e-999\"","#
            + #""modelId":null,"ignored":[{"input":1e999}],"output":"12"}"#
        let object = try #require(try AntigravityJSONLObject.decode(Array(text.utf8), checkCancellation: {}))
        #expect((object["input"] as? AntigravityJSONLObject.Number)?.integer == 100)
        #expect((object["cacheRead"] as? AntigravityJSONLObject.Number)?.integer == 10)
        #expect((object["cache_read"] as? AntigravityJSONLObject.Number)?.integer == 10)
        #expect(object["label"] as? String == "1e-999\"")
        #expect(object["output"] as? String == "12")
        #expect(object["modelId"] is NSNull)
        #expect(try AntigravityJSONLObject.decode(
            Array(#"{"input":1,"in\u0070ut":2}"#.utf8), checkCancellation: {}) == nil)
    }

    @Test
    func `long numeric lexemes and strings propagate a one-shot cancellation unchanged`() throws {
        for value in ["1" + String(repeating: "0", count: 10000), "\"" + String(repeating: "a", count: 10000) + "\""] {
            let expected = NSError(domain: NSPOSIXErrorDomain, code: 4321)
            var checks = 0
            do {
                _ = try AntigravityJSONLObject.decode(Array("{\"input\":\(value)}".utf8)) {
                    checks += 1
                    if checks == 3 { throw expected }
                }
                Issue.record("Expected cancellation inside the bounded lexer")
            } catch {
                #expect((error as NSError) === expected)
            }
            #expect(checks == 3)
        }
    }

    private func report(literal: String, field: String) throws -> AntigravityLocalReader.DailyReportResult {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("antigravity-number-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let context = AntigravityLocalReader.Context(environment: ["HOME": root.path])
        try FileManager.default.createDirectory(at: context.cacheRoot, withIntermediateDirectories: true)
        var fields = ["input": "0", "output": "0", "timestamp": "1787832000000"]
        fields[field] = literal
        let values = fields.sorted { $0.key < $1.key }.map { "\"\($0.key)\":\($0.value)" }.joined(separator: ",")
        // Raw numeric text goes directly to the file, never through NSNumber or a JSON encoder.
        let line = #"{"type":"usage","sessionId":"numeric-fixture",\#(values)}"#
        try line.write(to: context.cacheRoot.appendingPathComponent("session.jsonl"), atomically: true, encoding: .utf8)
        return try AntigravityLocalReader.makeDailyReportWithStatus(
            context: context,
            calendar: CostUsageBucketTimeZone.calendar(identifier: "UTC"))
    }
}
