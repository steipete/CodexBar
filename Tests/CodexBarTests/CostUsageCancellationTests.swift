import Foundation
import Testing
@testable import CodexBarCore

struct CostUsageCancellationTests {
    @Test
    func `fetcher honors cancellation before token scan`() async throws {
        let gate = AsyncCancellationGate()
        let task = Task {
            await gate.wait()
            _ = try await CostUsageFetcher.loadTokenSnapshot(
                provider: .codex,
                scannerOptions: CostUsageScanner.Options())
        }
        await gate.waitUntilBlocked()
        task.cancel()
        await gate.open()

        await #expect(throws: CancellationError.self) {
            _ = try await task.value
        }
    }

    @Test
    func `codex scanner cancellation preserves existing cache`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let day = try env.makeLocalNoon(year: 2026, month: 1, day: 2)
        let iso = env.isoString(for: day)
        let fileURL = try env.writeCodexSessionFile(
            day: day,
            filename: "session.jsonl",
            contents: self.codexSessionContents(iso: iso, tokenLineCount: 1))

        var options = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            cacheRoot: env.cacheRoot)
        options.refreshMinIntervalSeconds = 0

        let report = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day,
            options: options)
        #expect(report.data.count == 1)

        let cacheURL = CostUsageCacheIO.cacheFileURL(provider: .codex, cacheRoot: env.cacheRoot)
        let cacheBefore = try Data(contentsOf: cacheURL)

        try self.codexSessionContents(iso: iso, tokenLineCount: 20000)
            .write(to: fileURL, atomically: true, encoding: .utf8)

        var checks = 0
        let checkCancellation: CostUsageScanner.CancellationCheck = {
            checks += 1
            if checks >= 8 {
                throw CancellationError()
            }
        }

        #expect(throws: CancellationError.self) {
            _ = try CostUsageScanner.loadDailyReportCancellable(
                provider: .codex,
                since: day,
                until: day,
                now: day,
                options: options,
                checkCancellation: checkCancellation)
        }
        #expect(checks >= 8)
        #expect(try Data(contentsOf: cacheURL) == cacheBefore)
    }

    @Test
    func `codex metadata pre scan honors cancellation`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let day = try env.makeLocalNoon(year: 2026, month: 1, day: 2)
        let iso = env.isoString(for: day)
        let fileURL = try env.writeCodexSessionFile(
            day: day,
            filename: "session-without-metadata.jsonl",
            contents: Array(repeating: self.codexTokenLine(iso: iso), count: 20000).joined(separator: "\n") + "\n")

        var checks = 0
        let checkCancellation: CostUsageScanner.CancellationCheck = {
            checks += 1
            if checks >= 3 {
                throw CancellationError()
            }
        }

        #expect(throws: CancellationError.self) {
            _ = try CostUsageScanner.parseCodexFileCancellable(
                fileURL: fileURL,
                range: CostUsageScanner.CostUsageDayRange(since: day, until: day),
                checkCancellation: checkCancellation)
        }
        #expect(checks >= 3)
    }

    private func codexSessionContents(iso: String, tokenLineCount: Int) -> String {
        let session = #"{"type":"session_meta","payload":{"session_id":"session-1"}}"#
        let context = #"{"type":"turn_context","timestamp":"\#(iso)","payload":{"model":"gpt-5"}}"#
        return ([session, context] + Array(repeating: self.codexTokenLine(iso: iso), count: tokenLineCount))
            .joined(separator: "\n") + "\n"
    }

    private func codexTokenLine(iso: String) -> String {
        #"{"type":"event_msg","timestamp":"\#(iso)","payload":{"#
            + #""type":"token_count","info":{"last_token_usage":{"#
            + #""input_tokens":10,"cached_input_tokens":2,"output_tokens":4}}}}"#
    }
}

private actor AsyncCancellationGate {
    private var blockedContinuation: CheckedContinuation<Void, Never>?
    private var openContinuation: CheckedContinuation<Void, Never>?
    private var isBlocked = false
    private var isOpen = false

    func wait() async {
        self.isBlocked = true
        self.blockedContinuation?.resume()
        self.blockedContinuation = nil
        if self.isOpen { return }
        await withCheckedContinuation { continuation in
            self.openContinuation = continuation
        }
    }

    func waitUntilBlocked() async {
        if self.isBlocked { return }
        await withCheckedContinuation { continuation in
            self.blockedContinuation = continuation
        }
    }

    func open() {
        self.isOpen = true
        self.openContinuation?.resume()
        self.openContinuation = nil
    }
}
