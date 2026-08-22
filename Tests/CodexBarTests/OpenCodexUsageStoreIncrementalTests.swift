import Foundation
import SQLite3
import Testing
@testable import CodexBarCore

struct OpenCodexUsageStoreIncrementalTests {
    @Test
    func `incremental load matches a full parse after appended lines`() throws {
        let harness = try Harness.make()
        defer { harness.tearDown() }

        try harness.writeLines(
            Harness.line(id: "req-1", input: 10),
            Harness.line(id: "req-10", input: 4),
            Harness.line(id: "req-ä", input: 7))
        let first = try harness.store.loadEntries(logURL: harness.log)
        let firstExpected = try harness.referenceEntries()
        #expect(first == firstExpected)

        try harness.appendLines(
            Harness.line(id: "req-2", input: 3),
            Harness.line(id: "req-b", input: 8),
            Harness.line(id: "req-c", input: 1))
        let second = try harness.store.loadEntries(logURL: harness.log)
        let secondExpected = try harness.referenceEntries()
        #expect(second == secondExpected)
    }

    @Test
    func `appended lines parse only the tail and an unchanged file reads zero bytes`() throws {
        let harness = try Harness.make()
        defer { harness.tearDown() }

        try harness.writeLines(
            Harness.line(id: "seed-1", input: 1),
            Harness.line(id: "seed-2", input: 2))
        _ = try harness.store.loadEntries(logURL: harness.log)

        let appended = [
            Harness.line(id: "tail-1", input: 3),
            Harness.line(id: "tail-2", input: 4),
            Harness.line(id: "tail-3", input: 5),
        ]
        try harness.appendLines(appended)

        let tailRecorder = OpenCodexUsageParser.LogReadRecorder()
        let afterAppend = try OpenCodexUsageStore.withLogReadRecorderForTesting(tailRecorder) {
            try harness.store.loadEntries(logURL: harness.log)
        }
        let afterAppendExpected = try harness.referenceEntries()
        #expect(afterAppend == afterAppendExpected)
        #expect(tailRecorder.snapshot().completeLines == appended.count)

        let unchangedRecorder = OpenCodexUsageParser.LogReadRecorder()
        let unchanged = try OpenCodexUsageStore.withLogReadRecorderForTesting(unchangedRecorder) {
            try harness.store.loadEntries(logURL: harness.log)
        }
        #expect(unchanged == afterAppend)
        #expect(unchangedRecorder.snapshot().bytesRead == 0)
        #expect(unchangedRecorder.snapshot().completeLines == 0)
    }

    @Test
    func `partial trailing line is ignored until the newline arrives`() throws {
        let harness = try Harness.make()
        defer { harness.tearDown() }

        let complete = Harness.line(id: "complete", input: 4) + "\n"
        try Data(complete.utf8).write(to: harness.log)
        _ = try harness.store.loadEntries(logURL: harness.log)
        let completeOffset = try #require(harness.store.parseCursorForTesting()?.parsedOffset)
        #expect(completeOffset == Int64(complete.utf8.count))

        let pending = Harness.line(id: "pending", input: 9)
        let pendingBytes = Data(pending.utf8)
        let splitIndex = pendingBytes.count / 2
        let head = String(data: pendingBytes.prefix(splitIndex), encoding: .utf8) ?? ""
        let tail = String(data: pendingBytes.dropFirst(splitIndex), encoding: .utf8) ?? ""
        try harness.append(head)

        let partial = try harness.store.loadEntries(logURL: harness.log)
        #expect(partial.map(\.requestID) == ["complete"])
        #expect(harness.store.parseCursorForTesting()?.parsedOffset == completeOffset)

        try harness.append(tail + "\n")
        let completed = try harness.store.loadEntries(logURL: harness.log)
        #expect(completed.map(\.requestID) == ["complete", "pending"])
        let completedExpected = try harness.referenceEntries()
        #expect(completed == completedExpected)
        #expect(completed.count(where: { $0.requestID == "pending" }) == 1)
    }

    @Test
    func `later duplicate request ids win like a full parse`() throws {
        let harness = try Harness.make()
        defer { harness.tearDown() }

        try harness.writeLines(Harness.line(id: "dup", input: 1), Harness.line(id: "other", input: 2))
        _ = try harness.store.loadEntries(logURL: harness.log)
        try harness.appendLines(Harness.line(id: "dup", input: 9))

        let incremental = try harness.store.loadEntries(logURL: harness.log)
        let incrementalExpected = try harness.referenceEntries()
        #expect(incremental == incrementalExpected)
        let duplicate = try #require(incremental.first { $0.requestID == "dup" })
        #expect(duplicate.usage?.inputTokens == 9)
        #expect(incremental.count == 2)
    }

    @Test
    func `truncation and in-place rewrite fall back to a full parse`() throws {
        let harness = try Harness.make()
        defer { harness.tearDown() }

        let first = Harness.line(id: "id-A", input: 1)
        let rewritten = Harness.line(id: "id-B", input: 9)
        let width = max(first.utf8.count, rewritten.utf8.count)
        let firstPadded = first.padding(toLength: width, withPad: " ", startingAt: 0)
        let rewrittenPadded = rewritten.padding(toLength: width, withPad: " ", startingAt: 0)
        #expect(Array(firstPadded.utf8) != Array(rewrittenPadded.utf8))
        #expect(firstPadded.utf8.count == rewrittenPadded.utf8.count)
        let extra = Harness.line(id: "keep", input: 3)
        try harness.writeLines(firstPadded, extra)
        _ = try harness.store.loadEntries(logURL: harness.log)

        try harness.rewriteFirstLine(rewrittenPadded)
        let afterRewrite = try harness.store.loadEntries(logURL: harness.log)
        let rewriteExpected = try harness.referenceEntries()
        #expect(afterRewrite == rewriteExpected)
        #expect(afterRewrite.map(\.requestID) == ["id-B", "keep"])

        let prefix = rewrittenPadded + "\n"
        try harness.truncate(to: prefix.utf8.count)
        let afterTruncate = try harness.store.loadEntries(logURL: harness.log)
        let truncateExpected = try harness.referenceEntries()
        #expect(afterTruncate == truncateExpected)
        #expect(afterTruncate.map(\.requestID) == ["id-B"])
    }

    @Test
    func `rotation with a shared 64 kib prefix falls back to a full parse`() throws {
        let harness = try Harness.make()
        defer { harness.tearDown() }

        let prefixLine = Harness.paddedLine(id: "pad", input: 1, padByteCount: Harness.prefixDigestByteLimit)
        let firstTail = Harness.line(id: "id-A", input: 1)
        let rotatedTail = Harness.line(id: "rotated", input: 6)
        let width = max(firstTail.utf8.count, rotatedTail.utf8.count)
        let firstPadded = firstTail.padding(toLength: width, withPad: " ", startingAt: 0)
        let rotatedPadded = rotatedTail.padding(toLength: width, withPad: " ", startingAt: 0)
        try harness.writeLines(prefixLine, firstPadded)
        _ = try harness.store.loadEntries(logURL: harness.log)
        let oldOffset = try #require(harness.store.parseCursorForTesting()?.parsedOffset)

        try FileManager.default.removeItem(at: harness.log)
        try harness.writeLines(prefixLine, rotatedPadded)
        let newSize = try FileManager.default.attributesOfItem(atPath: harness.log.path)[.size] as? Int64
        #expect(newSize ?? 0 >= oldOffset)

        let afterRotation = try harness.store.loadEntries(logURL: harness.log)
        let rotationExpected = try harness.referenceEntries()
        #expect(afterRotation == rotationExpected)
        #expect(afterRotation.map(\.requestID) == ["pad", "rotated"])
    }

    @Test
    func `in-place rewrite past the 64 kib digest window is not detected`() throws {
        // The prefix digest only covers min(64 KiB, parsedOffset). An in-place rewrite past that
        // window that preserves size and inode is invisible; the log is append-only.
        let harness = try Harness.make()
        defer { harness.tearDown() }

        let prefixLine = Harness.paddedLine(id: "pad", input: 1, padByteCount: Harness.prefixDigestByteLimit)
        let firstTail = Harness.line(id: "id-A", input: 1)
        let rewrittenTail = Harness.line(id: "id-B", input: 9)
        let width = max(firstTail.utf8.count, rewrittenTail.utf8.count)
        let firstPadded = firstTail.padding(toLength: width, withPad: " ", startingAt: 0)
        let rewrittenPadded = rewrittenTail.padding(toLength: width, withPad: " ", startingAt: 0)
        try harness.writeLines(prefixLine, firstPadded)
        _ = try harness.store.loadEntries(logURL: harness.log)

        let prefixByteCount = prefixLine.utf8.count + 1
        try harness.rewriteLine(atByteOffset: prefixByteCount, rewrittenPadded)
        let afterRewrite = try harness.store.loadEntries(logURL: harness.log)
        #expect(afterRewrite.map(\.requestID) == ["id-A", "pad"])
        let full = try OpenCodexUsageParser.parse(fileURL: harness.log)
        #expect(full.map(\.requestID) == ["pad", "id-B"])
    }

    @Test
    func `schema v1 payload caches rebuild from the log`() throws {
        let harness = try Harness.make()
        defer { harness.tearDown() }

        try harness.writeLines(Harness.line(id: "live", input: 9, output: 2, total: 11))
        try Harness.writeV1Database(
            at: harness.cacheRoot.appendingPathComponent(OpenCodexUsageStore.databaseFilename),
            staleRequestID: "stale-v1")

        let entries = try harness.store.loadEntries(logURL: harness.log)
        let schemaExpected = try harness.referenceEntries()
        #expect(entries == schemaExpected)
        #expect(entries.map(\.requestID) == ["live"])
        #expect(entries.contains { $0.requestID == "stale-v1" } == false)
        #expect(entries[0].usage?.inputTokens == 9)
        #expect(entries[0].usage?.outputTokens == 2)
        #expect(entries[0].totalTokens == 11)
    }

    @Test
    func `CRLF file parse matches parseLines and offset parse skips a trailing partial line`() throws {
        let harness = try Harness.make()
        defer { harness.tearDown() }

        let text = """
        \(Harness.line(id: "one", input: 1))\r
        \(Harness.line(id: "two", input: 2))

        not-json
        \(Harness.line(id: "three", input: 3))
        """
        try Data(text.utf8).write(to: harness.log)

        let fromFile = try OpenCodexUsageParser.parse(fileURL: harness.log)
        #expect(fromFile.map(\.requestID) == OpenCodexUsageParser.parseLines(text).map(\.requestID))
        #expect(fromFile.map(\.requestID) == ["one", "two", "three"])

        let complete = Harness.line(id: "full", input: 4) + "\n"
        let partial = String(data: Data(Harness.line(id: "half", input: 5).utf8).prefix(12), encoding: .utf8) ?? ""
        try Data((complete + partial).utf8).write(to: harness.log)
        let sliced = try OpenCodexUsageParser.parse(fileURL: harness.log, from: 0)
        #expect(sliced.entries.map(\.requestID) == ["full"])
        #expect(sliced.nextOffset == Int64(complete.utf8.count))
    }

    @Test
    func `complete newline-less trailing record does not advance the cursor`() throws {
        let harness = try Harness.make()
        defer { harness.tearDown() }

        let complete = Harness.line(id: "head", input: 1) + "\n"
        let trailing = Harness.line(id: "tail", input: 2)
        try Data((complete + trailing).utf8).write(to: harness.log)

        let sliced = try OpenCodexUsageParser.parse(fileURL: harness.log, from: 0)
        #expect(sliced.entries.map(\.requestID) == ["head", "tail"])
        #expect(sliced.nextOffset == Int64(complete.utf8.count))

        let loaded = try harness.store.loadEntries(logURL: harness.log)
        #expect(loaded.map(\.requestID) == ["head", "tail"])
        #expect(harness.store.parseCursorForTesting()?.parsedOffset == Int64(complete.utf8.count))
    }

    @Test
    func `gluing bytes onto a newline-less trailing record matches a full parse`() throws {
        let harness = try Harness.make()
        defer { harness.tearDown() }

        let recordA = Harness.line(id: "a", input: 1)
        let recordB = Harness.line(id: "b", input: 2)
        try Data(recordA.utf8).write(to: harness.log)
        let first = try harness.store.loadEntries(logURL: harness.log)
        #expect(first.map(\.requestID) == ["a"])
        #expect(harness.store.parseCursorForTesting()?.parsedOffset == 0)

        try harness.append(recordB + "\n")
        let incremental = try harness.store.loadEntries(logURL: harness.log)
        let full = try harness.referenceEntries()
        #expect(incremental == full)
        #expect(full.isEmpty)
    }

    @Test
    func `schema v2 round trip preserves nil usage zero fields and mismatched totals`() throws {
        let harness = try Harness.make()
        defer { harness.tearDown() }

        try harness.writeLines(
            Harness.lineWithoutUsage(id: "no-usage"),
            Harness.lineWithZeroInputUsage(id: "zero-field"),
            Harness.line(id: "mismatch", input: 10, output: 2, total: 99, usageTotal: 12))
        _ = try harness.store.loadEntries(logURL: harness.log)
        let second = try harness.store.loadEntries(logURL: harness.log)
        let expected = try harness.referenceEntries()
        #expect(second == expected)

        let noUsage = try #require(second.first { $0.requestID == "no-usage" })
        #expect(noUsage.usage == nil)
        let zeroField = try #require(second.first { $0.requestID == "zero-field" })
        #expect(zeroField.usage?.inputTokens == 0)
        #expect(zeroField.usage?.outputTokens == nil)
        #expect(zeroField.usage?.totalTokens == nil)
        let mismatch = try #require(second.first { $0.requestID == "mismatch" })
        #expect(mismatch.totalTokens == 99)
        #expect(mismatch.usage?.totalTokens == 12)
        #expect(mismatch.usage?.inputTokens == 10)
    }

    @Test
    func `failed begin immediate leaves rows and cursor untouched`() throws {
        let harness = try Harness.make()
        defer { harness.tearDown() }

        try harness.writeLines(Harness.line(id: "keep", input: 1))
        _ = try harness.store.loadEntries(logURL: harness.log)
        let cursorBefore = try #require(harness.store.parseCursorForTesting())
        let rowsBefore = try harness.sqliteRequestIDs()
        #expect(rowsBefore == ["keep"])

        try harness.appendLines(Harness.line(id: "new", input: 2))
        try harness.withExclusiveSQLiteWriteLock {
            _ = try harness.store.loadEntries(logURL: harness.log)
            let cursorAfter = try #require(harness.store.parseCursorForTesting())
            #expect(cursorAfter.parsedOffset == cursorBefore.parsedOffset)
            #expect(cursorAfter.prefixDigest == cursorBefore.prefixDigest)
            #expect(cursorAfter.fileIdentity == cursorBefore.fileIdentity)
            #expect(try harness.sqliteRequestIDs() == rowsBefore)
        }
    }

    @Test
    func `stale incremental write does not regress a newer durable cursor`() throws {
        // Deterministic: commit a newer cursor, then force the write path with the older
        // snapshot. No thread interleaving.
        let harness = try Harness.make()
        defer { harness.tearDown() }

        try harness.writeLines(Harness.line(id: "req-1", input: 1), Harness.line(id: "req-2", input: 2))
        let first = try harness.store.loadEntries(logURL: harness.log)
        let firstCursor = try #require(harness.store.parseCursorForTesting())

        try harness.appendLines(Harness.line(id: "req-3", input: 3), Harness.line(id: "req-4", input: 4))
        _ = try harness.store.loadEntries(logURL: harness.log)
        let newerCursor = try #require(harness.store.parseCursorForTesting())
        #expect(newerCursor.parsedOffset > firstCursor.parsedOffset)

        harness.store.writeIncrementalEntriesForTesting(
            first,
            path: firstCursor.path,
            fileIdentity: firstCursor.fileIdentity,
            parsedOffset: firstCursor.parsedOffset,
            prefixDigest: firstCursor.prefixDigest)

        let afterStale = try #require(harness.store.parseCursorForTesting())
        #expect(afterStale.parsedOffset == newerCursor.parsedOffset)
        #expect(afterStale.prefixDigest == newerCursor.prefixDigest)
        #expect(afterStale.fileIdentity == newerCursor.fileIdentity)
        #expect(afterStale.path == newerCursor.path)

        let expected = try harness.referenceEntries()
        #expect(try harness.sqliteEntryCount() == expected.count)
        #expect(try harness.sqliteRequestIDs() == expected.map(\.requestID).sorted())

        let loaded = try harness.store.loadEntries(logURL: harness.log)
        #expect(loaded == expected)
    }

    @Test
    func `incremental reload falls back to a full parse when the cached rows cannot be read`() throws {
        let harness = try Harness.make()
        defer { harness.tearDown() }

        try harness.writeLines(Harness.line(id: "seed", input: 1))
        _ = try harness.store.loadEntries(logURL: harness.log)
        try harness.dropEntriesTable()
        try harness.appendLines(Harness.line(id: "tail", input: 2))

        let recovered = try harness.store.loadEntries(logURL: harness.log)
        let expected = try harness.referenceEntries()
        #expect(recovered == expected)
        #expect(recovered.map(\.requestID) == ["seed", "tail"])
    }
}

private struct Harness {
    let root: URL
    let cacheRoot: URL
    let log: URL
    let store: OpenCodexUsageStore

    static func make() throws -> Harness {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenCodexUsageStoreIncremental-\(UUID().uuidString)", isDirectory: true)
        let cacheRoot = root.appendingPathComponent("cache", isDirectory: true)
        try FileManager.default.createDirectory(at: cacheRoot, withIntermediateDirectories: true)
        return Harness(
            root: root,
            cacheRoot: cacheRoot,
            log: root.appendingPathComponent("usage.jsonl"),
            store: OpenCodexUsageStore(cacheRoot: cacheRoot))
    }

    func tearDown() {
        try? FileManager.default.removeItem(at: self.root)
    }

    static let prefixDigestByteLimit = 64 * 1024

    static func line(
        id: String,
        input: Int,
        output: Int = 1,
        total: Int? = nil,
        usageTotal: Int? = nil) -> String
    {
        let resolvedTotal = total ?? (input + output)
        let resolvedUsageTotal = usageTotal ?? resolvedTotal
        return """
        {"requestId":"\(id)","timestamp":1784179200000,"provider":"openai","model":"gpt-5.4",\
        "usageStatus":"reported","usage":{"inputTokens":\(input),"outputTokens":\(output),\
        "totalTokens":\(resolvedUsageTotal)},"totalTokens":\(resolvedTotal)}
        """
    }

    static func lineWithoutUsage(id: String) -> String {
        """
        {"requestId":"\(id)","timestamp":1784179200000,"provider":"openai","model":"gpt-5.4",\
        "usageStatus":"unreported"}
        """
    }

    static func lineWithZeroInputUsage(id: String) -> String {
        """
        {"requestId":"\(id)","timestamp":1784179200000,"provider":"openai","model":"gpt-5.4",\
        "usageStatus":"reported","usage":{"inputTokens":0}}
        """
    }

    static func paddedLine(id: String, input: Int, padByteCount: Int) -> String {
        let pad = String(repeating: "x", count: padByteCount)
        return String(self.line(id: id, input: input).dropLast()) + ",\"pad\":\"\(pad)\"}"
    }

    func writeLines(_ lines: String...) throws {
        try self.writeLines(Array(lines))
    }

    func writeLines(_ lines: [String]) throws {
        let body = lines.map { $0.hasSuffix("\n") ? $0 : $0 + "\n" }.joined()
        try Data(body.utf8).write(to: self.log)
    }

    func appendLines(_ lines: [String]) throws {
        try self.append(lines.map { $0.hasSuffix("\n") ? $0 : $0 + "\n" }.joined())
    }

    func appendLines(_ lines: String...) throws {
        try self.appendLines(Array(lines))
    }

    func append(_ text: String) throws {
        let handle = try FileHandle(forUpdating: self.log)
        defer { try? handle.close() }
        _ = try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
    }

    func rewriteFirstLine(_ line: String) throws {
        try self.rewriteLine(atByteOffset: 0, line)
    }

    func rewriteLine(atByteOffset offset: Int, _ line: String) throws {
        let replacement = Data((line.hasSuffix("\n") ? line : line + "\n").utf8)
        let handle = try FileHandle(forUpdating: self.log)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(offset))
        try handle.write(contentsOf: replacement)
    }

    var databaseURL: URL {
        self.cacheRoot.appendingPathComponent(OpenCodexUsageStore.databaseFilename)
    }

    func sqliteEntryCount() throws -> Int {
        var db: OpaquePointer?
        guard sqlite3_open_v2(self.databaseURL.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(db)
            throw FixtureError.sqlite
        }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM entries", -1, &statement, nil) == SQLITE_OK else {
            throw FixtureError.sqlite
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw FixtureError.sqlite }
        return Int(sqlite3_column_int64(statement, 0))
    }

    func sqliteRequestIDs() throws -> [String] {
        var db: OpaquePointer?
        guard sqlite3_open_v2(self.databaseURL.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(db)
            throw FixtureError.sqlite
        }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            db,
            "SELECT request_id FROM entries ORDER BY request_id",
            -1,
            &statement,
            nil) == SQLITE_OK
        else {
            throw FixtureError.sqlite
        }
        defer { sqlite3_finalize(statement) }
        var ids: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let pointer = sqlite3_column_text(statement, 0) {
                ids.append(String(cString: pointer))
            }
        }
        return ids
    }

    func dropEntriesTable() throws {
        var db: OpaquePointer?
        guard sqlite3_open(self.databaseURL.path, &db) == SQLITE_OK else {
            sqlite3_close(db)
            throw FixtureError.sqlite
        }
        defer { sqlite3_close(db) }
        guard sqlite3_exec(db, "DROP TABLE entries", nil, nil, nil) == SQLITE_OK else {
            throw FixtureError.sqlite
        }
    }

    func withExclusiveSQLiteWriteLock(_ body: () throws -> Void) throws {
        var db: OpaquePointer?
        guard sqlite3_open_v2(self.databaseURL.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
            sqlite3_close(db)
            throw FixtureError.sqlite
        }
        defer {
            _ = sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
            sqlite3_close(db)
        }
        sqlite3_busy_timeout(db, 0)
        guard sqlite3_exec(db, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK else {
            throw FixtureError.sqlite
        }
        try body()
    }

    func truncate(to byteCount: Int) throws {
        let handle = try FileHandle(forUpdating: self.log)
        defer { try? handle.close() }
        try handle.truncate(atOffset: UInt64(byteCount))
    }

    func referenceEntries() throws -> [OpenCodexUsageEntry] {
        let parsed = try OpenCodexUsageParser.parse(fileURL: self.log)
        var unique: [String: OpenCodexUsageEntry] = [:]
        for entry in parsed {
            unique[entry.requestID] = entry
        }
        return unique.values.sorted {
            if $0.timestamp != $1.timestamp {
                return $0.timestamp < $1.timestamp
            }
            return $0.requestID < $1.requestID
        }
    }

    static func writeV1Database(at databaseURL: URL, staleRequestID: String) throws {
        try FileManager.default.createDirectory(
            at: databaseURL.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        var db: OpaquePointer?
        guard sqlite3_open(databaseURL.path, &db) == SQLITE_OK else {
            sqlite3_close(db)
            throw FixtureError.sqlite
        }
        defer { sqlite3_close(db) }
        let schema = """
        CREATE TABLE meta (
            key TEXT PRIMARY KEY,
            value TEXT NOT NULL
        );
        CREATE TABLE entries (
            request_id TEXT PRIMARY KEY,
            timestamp REAL NOT NULL,
            provider TEXT NOT NULL,
            model TEXT NOT NULL,
            usage_status TEXT NOT NULL,
            account_label TEXT,
            surface TEXT,
            conversation_id TEXT,
            payload TEXT NOT NULL
        );
        PRAGMA user_version = 1;
        """
        guard sqlite3_exec(db, schema, nil, nil, nil) == SQLITE_OK else { throw FixtureError.sqlite }

        try self.exec(
            db,
            sql: "INSERT INTO meta(key, value) VALUES(?, ?)",
            bind: { statement in
                self.bind(statement, 1, "identity")
                self.bind(statement, 2, "/tmp/stale|1|1")
            })

        let payload = """
        {"requestId":"\(staleRequestID)","timestamp":1784179200000,"provider":"openai","model":"gpt-5.4",\
        "usageStatus":"reported","usage":{"inputTokens":1,"outputTokens":1,"totalTokens":2},"totalTokens":2}
        """
        try self.exec(
            db,
            sql: """
            INSERT INTO entries(
                request_id, timestamp, provider, model, usage_status, account_label, surface, conversation_id, payload
            ) VALUES (?, ?, ?, ?, ?, NULL, NULL, NULL, ?)
            """,
            bind: { statement in
                self.bind(statement, 1, staleRequestID)
                sqlite3_bind_double(statement, 2, 1_784_179_200)
                self.bind(statement, 3, "openai")
                self.bind(statement, 4, "gpt-5.4")
                self.bind(statement, 5, "reported")
                self.bind(statement, 6, payload)
            })
    }

    private static func exec(
        _ db: OpaquePointer?,
        sql: String,
        bind: (OpaquePointer?) -> Void) throws
    {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw FixtureError.sqlite }
        defer { sqlite3_finalize(statement) }
        bind(statement)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw FixtureError.sqlite }
    }

    private static func bind(_ statement: OpaquePointer?, _ index: Int32, _ value: String) {
        sqlite3_bind_text(statement, index, value, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
    }

    private enum FixtureError: Error {
        case sqlite
    }
}
