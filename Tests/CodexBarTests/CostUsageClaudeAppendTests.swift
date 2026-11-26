import Foundation
import Testing
@testable import CodexBarCore

@Suite(.serialized, CostUsageClaudeCacheFixtures())
struct CostUsageClaudeAppendTests {
    private typealias Fixture = CostUsageClaudeWriteAmplificationTests.Fixture

    @Test
    func `non usage appends leave durable artifacts alone and replay exactly once after a restart`() throws {
        let fixture = try Fixture(rowCount: 3)
        defer { fixture.env.cleanup() }
        let initial = try fixture.load(context: .regular, includeBreakdowns: true)
        let before = try fixture.stamps(context: .regular)
        let source = fixture.env.claudeProjectsRoot.appendingPathComponent("session.jsonl")
        let writer = try FileHandle(forWritingTo: source)
        defer { try? writer.close() }
        try writer.seekToEnd()
        let recorder = CostUsageScanner.ClaudeScanWorkRecorder()
        try CostUsageScanner.withClaudeScanWorkRecorderForTesting(recorder) {
            for cycle in 1...3 {
                try writer.write(contentsOf: Data("{\"type\":\"user\"}\n".utf8))
                let result = try fixture.load(context: .regular, cycle: cycle, includeBreakdowns: true)
                #expect(result.data == initial.data)
                #expect(result.quotaSlices == initial.quotaSlices)
            }
        }
        #expect(recorder.snapshot().cacheDecodes == 0)
        #expect(recorder.persistenceSnapshot().writes == 0)
        #expect(try fixture.stamps(context: .regular) == before)
        CostUsageScanner.evictClaudeReportMemoForTesting(provider: .claude, cacheRoot: fixture.env.cacheRoot)
        let event = try Data(fixture.event(index: 4).utf8)
        try writer.write(contentsOf: event.prefix(17))
        #expect(try fixture.load(context: .regular).data == initial.data)
        try writer.write(contentsOf: event.dropFirst(17))
        let after = try fixture.load(context: .regular)
        #expect(after.summary?.totalInputTokens == 40)
        #expect(try fixture.load(context: .regular, forceRescan: true).data == after.data)
    }

    @Test
    func `in place truncation and regrowth invalidates the durable append boundary`() throws {
        let fixture = try Fixture(rowCount: 2)
        defer { fixture.env.cleanup() }
        _ = try fixture.load(context: .regular)
        let source = fixture.env.claudeProjectsRoot.appendingPathComponent("session.jsonl")
        let writer = try FileHandle(forWritingTo: source)
        defer { try? writer.close() }
        try writer.truncate(atOffset: 0)
        let replacement = try fixture.event(index: 10) + String(repeating: "{}\n", count: 500)
        try writer.write(contentsOf: Data(replacement.utf8))
        #expect(try fixture.load(context: .regular).summary?.totalInputTokens == 10)
        try writer.truncate(atOffset: 0)
        #expect(try fixture.load(context: .regular).data.isEmpty)
        try Data(fixture.event(index: 20).utf8).write(to: source, options: .atomic)
        #expect(try fixture.load(context: .regular).summary?.totalInputTokens == 10)
    }

    @Test
    func `rotated gzip members preserve history and failed decompression preserves the previous commit`() throws {
        let fixture = try Fixture(rowCount: 2)
        defer { fixture.env.cleanup() }
        let original = try fixture.load(context: .regular)
        let source = fixture.env.claudeProjectsRoot.appendingPathComponent("session.jsonl")
        let rotated = source.appendingPathExtension("1")
        try FileManager.default.moveItem(at: source, to: rotated)
        let gzip = Process()
        gzip.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
        gzip.arguments = [rotated.path]
        try gzip.run()
        gzip.waitUntilExit()
        try #require(gzip.terminationStatus == 0)
        let archive = rotated.appendingPathExtension("gz")
        #expect(try fixture.load(context: .regular).data == original.data)
        _ = try fixture.env.writeClaudeProjectFile(relativePath: "session.jsonl", contents: fixture.event(index: 8))
        #expect(try fixture.load(context: .regular).summary?.totalInputTokens == 30)
        let before = try fixture.stamps(context: .regular)
        let bytes = try Data(contentsOf: archive)
        try bytes.dropLast(5).write(to: archive, options: .atomic)
        #expect(throws: (any Error).self) { try fixture.load(context: .regular) }
        #expect(try fixture.stamps(context: .regular) == before)
        try bytes.write(to: archive, options: .atomic)
        #expect(try fixture.load(context: .regular).summary?.totalInputTokens == 30)
    }
}
