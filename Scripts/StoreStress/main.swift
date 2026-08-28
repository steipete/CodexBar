// Adversarial stress/crash/perf harness for CostUsageStore (SQLite).
// Not shipped; used by review/store-stress verification runs.
//
// Subcommands:
//   writer <cacheRoot> <seconds>          realistic store writes + periodic retention/vacuum
//   read <dbPath> <seconds>               read-only connection hammering report reads, checks invariants
//   crashwriter <cacheRoot>               writes forever in known pattern (killed externally)
//   vacuumcrasher <cacheRoot> [marker]    grow + retention + enforceBudgets loop (killed externally)
//   verify <dbPath>                       raw integrity_check + invariant verification after crash
//   rebuild <cacheRoot> [passes] [root]   full cold rebuild from a real sessions corpus
//   incremental <cacheRoot> [root]        one incremental pass over unchanged corpus
//   fdcycles <cacheRoot> [cycles]         repeatedly open/close the store and report descriptor counts

import Foundation

#if canImport(SQLite3)
import SQLite3
#elseif canImport(CSQLite3)
import CSQLite3
#endif
@testable import CodexBarCore

let transientDestructor = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("FATAL: \(message)\n".utf8))
    exit(70)
}

func nowMs() -> Int64 {
    Int64(Date().timeIntervalSince1970 * 1000)
}

// MARK: - Writer workload helpers

func makeFile(path: String, day: String, size: Int64, updatedAt: Int64) -> CostUsageStoreFile {
    CostUsageStoreFile(
        path: path,
        inode: Int64(abs(path.hashValue % 1_000_000)),
        mtimeUnixMs: updatedAt,
        size: size,
        parsedBytes: size,
        anchor: nil,
        scanState: CostUsageStoreScanState(
            targetSize: size,
            isComplete: true,
            resumePayload: nil,
            tokenTimestampsMonotonic: true,
            nextUsageRowIndex: nil,
            lastModel: "gpt-test",
            lastTurnID: nil,
            fileIdentity: "fnv:\(path.hashValue)",
            detailsPayload: Data("{}".utf8)),
        sessionID: "sess-\(path.hashValue)",
        coverageSinceDay: day,
        coverageUntilDay: day,
        updatedAtUnixMs: updatedAt)
}

func delta(day: String, model: String, amount: Int64) -> CostUsageStoreDayAggregate {
    // Invariant: input == output in every committed transaction.
    var value = CostUsageStoreDayAggregate.zero(day: day, model: model)
    value.inputTokens = amount
    value.outputTokens = amount
    value.cachedTokens = amount / 2
    value.requestCount = 1
    value.authoritativeCostNanos = amount * 10
    return value
}

let days = (1...14).map { String(format: "2026-08-%02d", $0) }
let models = ["model-alpha", "model-beta", "model-gamma"]

// MARK: - writer

func runWriter(cacheRoot: URL, seconds: Double) async {
    let store = CostUsageStore(cacheRoot: cacheRoot)
    let deadline = Date().addingTimeInterval(seconds)
    var iteration = 0
    var writeErrors = 0
    var retentionRuns = 0
    var budgetRuns = 0
    var walPeakBytes: Int64 = 0
    while Date() < deadline {
        iteration += 1
        let day = days[iteration % days.count]
        let path = "/synthetic/session-\(iteration % 400).jsonl"
        let ok1 = await store.upsertFile(makeFile(
            path: path,
            day: day,
            size: Int64(iteration) * 128,
            updatedAt: nowMs()))
        let snapshots = (0..<8).map { index in
            CostUsageStoreTokenSnapshot(
                path: path,
                eventIndex: iteration * 8 + index,
                timestamp: "2026-08-08T12:00:00Z",
                timestampUnixMs: nowMs(),
                day: day,
                last: CostUsageStoreTotals(input: 10, cached: 5, output: 10, reasoning: 2),
                total: CostUsageStoreTotals(input: 100, cached: 50, output: 100, reasoning: 20),
                endOffset: Int64(iteration * 8 + index) * 512)
        }
        let ok2 = await store.appendTokenSnapshots(snapshots)
        let rows = (0..<4).map { index in
            CostUsageStoreUsageRow(
                path: path,
                rowIndex: iteration * 4 + index,
                payload: Data(repeating: UInt8(truncatingIfNeeded: iteration), count: 256))
        }
        let ok3 = await store.appendUsageRows(rows)
        let deltas = models.map { delta(day: day, model: $0, amount: Int64(1 + iteration % 97)) }
        let ok4 = await store.mergeDayAggregates(deltas)
        let ok5 = await store.replaceFileDayAggregates(
            path: path,
            aggregates: [delta(day: day, model: "gpt-5.6", amount: Int64(iteration % 50))])
        if !(ok1 && ok2 && ok3 && ok4 && ok5) {
            writeErrors += 1
        }

        if iteration % 200 == 0 {
            retentionRuns += 1
            _ = await store.retainDayWindow(sinceDay: days.first!, untilDay: days.last!)
        }
        if iteration % 500 == 0 {
            budgetRuns += 1
            _ = await store.enforceBudgets(maxRows: 25000, maxFileBytes: 256 * 1024 * 1024)
        }
        if iteration % 10 == 0 {
            walPeakBytes = max(walPeakBytes, fileSize(atPath: store.databaseURL.path + "-wal"))
        }
    }
    let rebuilds = await store.rebuildCount
    let walFinalBytes = fileSize(atPath: store.databaseURL.path + "-wal")
    print("WRITER done iterations=\(iteration) writeErrors=\(writeErrors) retentionRuns=\(retentionRuns) "
        + "budgetRuns=\(budgetRuns) storeRebuilds=\(rebuilds) walPeakBytes=\(walPeakBytes) "
        + "walFinalBytes=\(walFinalBytes)")
    if writeErrors > 0 || rebuilds > 0 {
        exit(1)
    }
}

// MARK: - reader

func runReader(dbPath: String, seconds: Double) {
    var db: OpaquePointer?
    // Wait for the writer to create the database.
    let openDeadline = Date().addingTimeInterval(10)
    while Date() < openDeadline {
        if sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK {
            var probe: OpaquePointer?
            if sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM day_aggregates", -1, &probe, nil) == SQLITE_OK {
                sqlite3_finalize(probe)
                break
            }
            sqlite3_close_v2(db)
            db = nil
        }
        Thread.sleep(forTimeInterval: 0.1)
    }
    guard let db else { fail("reader could not open \(dbPath)") }
    sqlite3_busy_timeout(db, 5000)

    var latencies: [Double] = []
    var reads = 0
    var errors = 0
    var invariantFailures = 0
    let deadline = Date().addingTimeInterval(seconds)
    let sql = "SELECT day, SUM(input_tokens), SUM(output_tokens), SUM(request_count) FROM day_aggregates GROUP BY day"
    while Date() < deadline {
        let start = DispatchTime.now()
        var statement: OpaquePointer?
        if sqlite3_exec(db, "BEGIN", nil, nil, nil) != SQLITE_OK {
            errors += 1; continue
        }
        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            var stepResult = sqlite3_step(statement)
            while stepResult == SQLITE_ROW {
                let input = sqlite3_column_int64(statement, 1)
                let output = sqlite3_column_int64(statement, 2)
                if input != output {
                    invariantFailures += 1
                }
                stepResult = sqlite3_step(statement)
            }
            if stepResult != SQLITE_DONE {
                errors += 1
            }
            sqlite3_finalize(statement)
        } else {
            errors += 1
        }
        sqlite3_exec(db, "COMMIT", nil, nil, nil)
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
        latencies.append(elapsed)
        reads += 1
    }
    sqlite3_close_v2(db)
    latencies.sort()
    func pct(_ p: Double) -> Double {
        latencies.isEmpty ? 0 : latencies[min(
            latencies.count - 1,
            Int(Double(latencies.count) * p))]
    }
    print(String(
        format: "READER done reads=%d errors=%d invariantFailures=%d p50=%.3fms p95=%.3fms p99=%.3fms max=%.3fms",
        reads, errors, invariantFailures, pct(0.5), pct(0.95), pct(0.99), latencies.last ?? 0))
    if errors > 0 || invariantFailures > 0 {
        exit(1)
    }
}

// MARK: - crash writer

func runCrashWriter(cacheRoot: URL) async {
    let store = CostUsageStore(cacheRoot: cacheRoot)
    // Deterministic pattern: iteration i merges +i into 2026-08-01/gpt-crash (input == output).
    // After SIGKILL, the committed total must be a triangular number: k*(k+1)/2.
    var iteration: Int64 = 0
    while true {
        iteration += 1
        _ = await store.upsertFile(makeFile(
            path: "/crash/session-\(iteration % 64).jsonl",
            day: "2026-08-01",
            size: iteration * 64,
            updatedAt: nowMs()))
        _ = await store.appendTokenSnapshots([
            CostUsageStoreTokenSnapshot(
                path: "/crash/session-\(iteration % 64).jsonl",
                eventIndex: Int(iteration),
                timestamp: "2026-08-01T00:00:00Z",
                timestampUnixMs: nowMs(),
                day: "2026-08-01",
                last: CostUsageStoreTotals(input: iteration, cached: 0, output: iteration, reasoning: nil),
                total: nil,
                endOffset: iteration),
        ])
        _ = await store.mergeDayAggregates([delta(day: "2026-08-01", model: "gpt-crash", amount: iteration)])
    }
}

// MARK: - vacuum crasher

func runVacuumCrasher(cacheRoot: URL, marker: URL?) async {
    let store = CostUsageStore(cacheRoot: cacheRoot)
    var iteration: Int64 = 0
    while true {
        iteration += 1
        for fileIndex in 0..<20 {
            let path = "/vac/session-\(iteration)-\(fileIndex).jsonl"
            _ = await store.upsertFile(makeFile(
                path: path,
                day: "2026-08-01",
                size: 4096,
                updatedAt: nowMs() - 100_000))
            let rows = (0..<16).map {
                CostUsageStoreUsageRow(path: path, rowIndex: $0, payload: Data(repeating: 7, count: 2048))
            }
            _ = await store.appendUsageRows(rows)
            _ = await store.mergeDayAggregates([delta(day: "2026-08-01", model: "gpt-vac", amount: 3)])
        }
        if let marker {
            try? Data("retention-vacuum\n".utf8).write(to: marker, options: .atomic)
        }
        _ = await store.retainDayWindow(sinceDay: "2026-08-01", untilDay: "2026-08-02")
        // Tight budget forces deleteOldestRetainedFile + incremental_vacuum + wal_checkpoint churn.
        _ = await store.enforceBudgets(maxRows: 150, maxFileBytes: 2 * 1024 * 1024)
        if let marker {
            try? FileManager.default.removeItem(at: marker)
        }
    }
}

// MARK: - verify (raw sqlite; deliberately avoids CostUsageStore's rebuild-on-error)

func runVerify(dbPath: String, mode: String) {
    var db: OpaquePointer?
    guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let db else {
        fail("verify could not open \(dbPath)")
    }
    sqlite3_busy_timeout(db, 5000)
    func scalarText(_ sql: String) -> String? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        guard let text = sqlite3_column_text(statement, 0) else { return nil }
        return String(cString: text)
    }
    func scalarInt(_ sql: String) -> Int64? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return sqlite3_column_int64(statement, 0)
    }
    let integrity = scalarText("PRAGMA integrity_check") ?? "FAILED-TO-RUN"
    var verdictOK = integrity == "ok"
    var detail = ""
    if mode == "crash" {
        let input = scalarInt("SELECT COALESCE(SUM(input_tokens),0) FROM day_aggregates WHERE model='gpt-crash'") ?? -1
        let output = scalarInt("SELECT COALESCE(SUM(output_tokens),0) FROM day_aggregates WHERE model='gpt-crash'") ??
            -1
        let count = scalarInt("SELECT COALESCE(SUM(request_count),0) FROM day_aggregates WHERE model='gpt-crash'") ?? -1
        // total must equal k*(k+1)/2 where k = request_count (committed merges)
        let expected = count * (count + 1) / 2
        let patternOK = input == output && input == expected
        if !patternOK {
            verdictOK = false
        }
        detail = " committedMerges=\(count) total=\(input) expected=\(expected) patternOK=\(patternOK)"
    }
    let files = scalarInt("SELECT COUNT(*) FROM files") ?? -1
    print("VERIFY integrity=\(integrity) files=\(files)\(detail) verdict=\(verdictOK ? "OK" : "CORRUPT")")
    sqlite3_close_v2(db)
    exit(verdictOK ? 0 : 1)
}

// MARK: - real corpus rebuild

func runRebuild(cacheRoot: URL, maxPasses: Int, sessionsRoot: URL?) {
    let recorder = CostUsageScanner.CodexScanWorkRecorder()
    var options = CostUsageScanner.Options(
        codexSessionsRoot: sessionsRoot,
        cacheRoot: cacheRoot,
        codexScanWorkRecorderForTesting: recorder)
    options.refreshMinIntervalSeconds = 0
    let calendar = Calendar.current
    let until = Date()
    let since = calendar.date(byAdding: .day, value: -420, to: until)!
    var pass = 0
    let overallStart = DispatchTime.now()
    while pass < maxPasses {
        pass += 1
        let start = DispatchTime.now()
        let report = CostUsageScanner.loadDailyReport(
            provider: .codex, since: since, until: until, options: options)
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1e9
        let store = CostUsageStore(cacheRoot: cacheRoot)
        let metadata = store.syncLoadCodexCache(calendar: calendar)
        let processed = metadata.codexScanProcessedBytes ?? 0
        let total = metadata.codexScanTotalBytes ?? 0
        let pending = metadata.codexScanCatchUpPending == true
        let work = recorder.snapshot()
        let wall = String(format: "%.2f", elapsed)
        print("PASS \(pass) wall=\(wall)s days=\(report.data.count) processedBytes=\(processed) "
            + "totalBytes=\(total) usageRowsProcessed=\(work.usageRowsProcessed) "
            + "usageRowsRepriced=\(work.usageRowsRepriced) catchUpPending=\(pending)")
        if !pending, processed >= total, total > 0 {
            break
        }
    }
    let overall = Double(DispatchTime.now().uptimeNanoseconds - overallStart.uptimeNanoseconds) / 1e9
    print(String(format: "REBUILD done passes=%d totalWall=%.2fs", pass, overall))
}

func runIncremental(cacheRoot: URL, sessionsRoot: URL?) {
    let recorder = CostUsageScanner.CodexScanWorkRecorder()
    var options = CostUsageScanner.Options(
        codexSessionsRoot: sessionsRoot,
        cacheRoot: cacheRoot,
        codexScanWorkRecorderForTesting: recorder)
    options.refreshMinIntervalSeconds = 0
    let calendar = Calendar.current
    let until = Date()
    let since = calendar.date(byAdding: .day, value: -420, to: until)!
    let start = DispatchTime.now()
    let report = CostUsageScanner.loadDailyReport(provider: .codex, since: since, until: until, options: options)
    let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1e9
    let store = CostUsageStore(cacheRoot: cacheRoot)
    let metadata = store.syncLoadCodexCache(calendar: calendar)
    let work = recorder.snapshot()
    let wall = String(format: "%.2f", elapsed)
    print("INCREMENTAL wall=\(wall)s days=\(report.data.count) "
        + "totalTokens=\(report.data.reduce(0) { $0 + ($1.totalTokens ?? 0) }) "
        + "processedBytes=\(metadata.codexScanProcessedBytes ?? 0) "
        + "totalBytes=\(metadata.codexScanTotalBytes ?? 0) "
        + "usageRowsProcessed=\(work.usageRowsProcessed) usageRowsRepriced=\(work.usageRowsRepriced) "
        + "catchUpPending=\(metadata.codexScanCatchUpPending == true)")
}

// MARK: - descriptor hygiene

func fileSize(atPath path: String) -> Int64 {
    let attributes = try? FileManager.default.attributesOfItem(atPath: path)
    return (attributes?[.size] as? NSNumber)?.int64Value ?? 0
}

func descriptorCount() -> Int {
    (try? FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count) ?? -1
}

func openAndCloseStore(cacheRoot: URL) async {
    let store = CostUsageStore(cacheRoot: cacheRoot)
    _ = await store.configuration()
}

func runFDCycles(cacheRoot: URL, cycles: Int) async {
    await openAndCloseStore(cacheRoot: cacheRoot)
    let baseline = descriptorCount()
    var peak = baseline
    for _ in 0..<cycles {
        await openAndCloseStore(cacheRoot: cacheRoot)
        peak = max(peak, descriptorCount())
    }
    let final = descriptorCount()
    print("FDCYCLES done cycles=\(cycles) baseline=\(baseline) peak=\(peak) final=\(final) delta=\(final - baseline)")
    if final != baseline {
        exit(1)
    }
}

// MARK: - lock holder (simulates a second CodexBar process mid-save)

func runHolder(dbPath: String, seconds: Double) {
    var db: OpaquePointer?
    guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let db else {
        fail("holder could not open \(dbPath)")
    }
    sqlite3_busy_timeout(db, 10000)
    guard sqlite3_exec(db, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK else {
        fail("holder could not BEGIN IMMEDIATE")
    }
    sqlite3_exec(db, "INSERT OR REPLACE INTO meta(key,value) VALUES('holder','1')", nil, nil, nil)
    print("HOLDER acquired write lock for \(seconds)s")
    Thread.sleep(forTimeInterval: seconds)
    sqlite3_exec(db, "COMMIT", nil, nil, nil)
    sqlite3_close_v2(db)
    print("HOLDER released")
}

// MARK: - main

let arguments = CommandLine.arguments
guard arguments.count >= 3 else {
    fail("usage: storestress <writer|read|crashwriter|vacuumcrasher|verify|rebuild|incremental> <path> [args]")
}

let command = arguments[1]
let target = arguments[2]

switch command {
case "writer":
    let seconds = Double(arguments.count > 3 ? arguments[3] : "60") ?? 60
    await runWriter(cacheRoot: URL(fileURLWithPath: target), seconds: seconds)
case "read":
    runReader(dbPath: target, seconds: Double(arguments.count > 3 ? arguments[3] : "60") ?? 60)
case "crashwriter":
    await runCrashWriter(cacheRoot: URL(fileURLWithPath: target))
case "vacuumcrasher":
    let marker = arguments.count > 3 ? URL(fileURLWithPath: arguments[3]) : nil
    await runVacuumCrasher(cacheRoot: URL(fileURLWithPath: target), marker: marker)
case "verify":
    runVerify(dbPath: target, mode: arguments.count > 3 ? arguments[3] : "crash")
case "rebuild":
    runRebuild(
        cacheRoot: URL(fileURLWithPath: target),
        maxPasses: Int(arguments.count > 3 ? arguments[3] : "12") ?? 12,
        sessionsRoot: arguments.count > 4 ? URL(fileURLWithPath: arguments[4]) : nil)
case "holder":
    runHolder(dbPath: target, seconds: Double(arguments.count > 3 ? arguments[3] : "8") ?? 8)
case "incremental":
    runIncremental(
        cacheRoot: URL(fileURLWithPath: target),
        sessionsRoot: arguments.count > 3 ? URL(fileURLWithPath: arguments[3]) : nil)
case "fdcycles":
    await runFDCycles(
        cacheRoot: URL(fileURLWithPath: target),
        cycles: Int(arguments.count > 3 ? arguments[3] : "100") ?? 100)
default:
    fail("unknown command \(command)")
}
