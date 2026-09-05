import Testing
import Foundation
@testable import CodexBarCore

struct MuseIncrementalCacheTests {
    private func makeSessionLine(recordedAtMicroseconds: Int64, inputTokens: Int, outputTokens: Int, model: String = "muse-spark-1.2-contributor") -> String {
        let outer: [String: Any] = [
            "recorded_at": recordedAtMicroseconds,
            "payload_type": "runtime.session",
            "payload": [
                "kind": "run",
                "event": [
                    "kind": "model_completed",
                    "usage": [
                        "input_tokens": inputTokens,
                        "output_tokens": outputTokens,
                        "cached_tokens": 0,
                        "cache_write_tokens": 0,
                        "cache_read_tokens": 0,
                        "reasoning_tokens": 0,
                    ],
                    "duration_ms": 1000,
                    "finish_reason": "tool_calls",
                    "model": model,
                ],
            ] as [String: Any],
        ]
        let data = try! JSONSerialization.data(withJSONObject: outer, options: [])
        return String(data: data, encoding: .utf8)!
    }

    private func makeWrappedLine(recordedAtMicroseconds: Int64, inputTokens: Int, outputTokens: Int) -> String {
        let inner: [String: Any] = [
            "recorded_at": recordedAtMicroseconds,
            "payload_type": "runtime.session",
            "payload": [
                "kind": "run",
                "event": [
                    "kind": "model_completed",
                    "usage": [
                        "input_tokens": inputTokens,
                        "output_tokens": outputTokens,
                        "cached_tokens": 0,
                        "cache_write_tokens": 0,
                        "cache_read_tokens": 0,
                        "reasoning_tokens": 0,
                    ],
                    "duration_ms": 1000,
                    "finish_reason": "tool_calls",
                    "model": "muse-spark-1.2-contributor",
                ],
            ] as [String: Any],
        ]
        let innerData = try! JSONSerialization.data(withJSONObject: inner, options: [])
        let innerString = String(data: innerData, encoding: .utf8)!
        let outer: [String: Any] = [
            "recorded_at": recordedAtMicroseconds,
            "payload_type": "retained_frame",
            "record_json": innerString,
        ]
        let outerData = try! JSONSerialization.data(withJSONObject: outer, options: [])
        return String(data: outerData, encoding: .utf8)!
    }

    private func microseconds(for date: Date) -> Int64 { Int64(date.timeIntervalSince1970 * 1_000_000) }

    @Test func unchangedSecondScanOpensZeroFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("muse-inc-unchanged-\(UUID().uuidString)", isDirectory: true)
        let localCalendar = Calendar.current
        let now = localCalendar.date(from: DateComponents(year: 2026, month: 8, day: 27, hour: 12))!
        let dayKey = MuseLocalSessionScanner.dayKey(for: now, calendar: localCalendar)!
        let sessionDir = root.appendingPathComponent("sessions/\(dayKey.replacingOccurrences(of: "-", with: "/"))/sess", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
        let line = makeSessionLine(recordedAtMicroseconds: microseconds(for: now), inputTokens: 100, outputTokens: 10)
        try line.write(to: sessionDir.appendingPathComponent("session.jsonl"), atomically: true, encoding: .utf8)

        var firstScanned: [URL] = []
        let first = MuseLocalSessionScanner.summarize(env: ["MUSE_HOME": root.path], lookbackDays: 30, now: now, fileScanObserver: { firstScanned.append($0) })
        #expect(first.requestCount == 1)
        #expect(firstScanned.count == 1)

        var secondScanned: [URL] = []
        let second = MuseLocalSessionScanner.summarize(env: ["MUSE_HOME": root.path], lookbackDays: 30, now: now, fileScanObserver: { secondScanned.append($0) })
        #expect(second.requestCount == 1)
        #expect(secondScanned.count == 0) // unchanged file not reopened
        #expect(second.totalTokens == first.totalTokens)
    }

    @Test func appendedFileParsesOnlyNewContent() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("muse-inc-append-\(UUID().uuidString)", isDirectory: true)
        let localCalendar = Calendar.current
        let now = localCalendar.date(from: DateComponents(year: 2026, month: 8, day: 27, hour: 12))!
        let dayKey = MuseLocalSessionScanner.dayKey(for: now, calendar: localCalendar)!
        let sessionDir = root.appendingPathComponent("sessions/\(dayKey.replacingOccurrences(of: "-", with: "/"))/sess", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
        let fileURL = sessionDir.appendingPathComponent("session.jsonl")
        let line1 = makeSessionLine(recordedAtMicroseconds: microseconds(for: now), inputTokens: 100, outputTokens: 10)
        try line1.write(to: fileURL, atomically: true, encoding: .utf8)
        let first = MuseLocalSessionScanner.summarize(env: ["MUSE_HOME": root.path], lookbackDays: 30, now: now)
        #expect(first.requestCount == 1)
        #expect(first.totalTokens == 110)

        // Append second event
        let line2 = makeSessionLine(recordedAtMicroseconds: microseconds(for: now.addingTimeInterval(60)), inputTokens: 200, outputTokens: 20)
        let handle = try FileHandle(forWritingTo: fileURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: (line2 + "\n").data(using: .utf8)!)
        try handle.close()

        var appendedScanned: [URL] = []
        let second = MuseLocalSessionScanner.summarize(env: ["MUSE_HOME": root.path], lookbackDays: 30, now: now, fileScanObserver: { appendedScanned.append($0) })
        #expect(appendedScanned.count == 1) // file was reopened for delta
        #expect(second.requestCount == 2)
        #expect(second.totalTokens == 330)
    }

    @Test func newFileAddsUsage() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("muse-inc-new-\(UUID().uuidString)", isDirectory: true)
        let localCalendar = Calendar.current
        let now = localCalendar.date(from: DateComponents(year: 2026, month: 8, day: 27, hour: 12))!
        let dayKey = MuseLocalSessionScanner.dayKey(for: now, calendar: localCalendar)!
        let dir1 = root.appendingPathComponent("sessions/\(dayKey.replacingOccurrences(of: "-", with: "/"))/sess1", isDirectory: true)
        try FileManager.default.createDirectory(at: dir1, withIntermediateDirectories: true)
        let line1 = makeSessionLine(recordedAtMicroseconds: microseconds(for: now), inputTokens: 100, outputTokens: 10)
        try line1.write(to: dir1.appendingPathComponent("session.jsonl"), atomically: true, encoding: .utf8)
        let first = MuseLocalSessionScanner.summarize(env: ["MUSE_HOME": root.path], lookbackDays: 30, now: now)
        #expect(first.requestCount == 1)

        let dir2 = root.appendingPathComponent("sessions/\(dayKey.replacingOccurrences(of: "-", with: "/"))/sess2", isDirectory: true)
        try FileManager.default.createDirectory(at: dir2, withIntermediateDirectories: true)
        let line2 = makeSessionLine(recordedAtMicroseconds: microseconds(for: now), inputTokens: 200, outputTokens: 20)
        try line2.write(to: dir2.appendingPathComponent("session.jsonl"), atomically: true, encoding: .utf8)

        var secondScanned: [URL] = []
        let second = MuseLocalSessionScanner.summarize(env: ["MUSE_HOME": root.path], lookbackDays: 30, now: now, fileScanObserver: { secondScanned.append($0) })
        #expect(secondScanned.count == 1) // only new file opened
        #expect(second.requestCount == 2)
        #expect(second.totalTokens == 330)
    }

    @Test func truncatedFileReparsesCorrectly() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("muse-inc-trunc-\(UUID().uuidString)", isDirectory: true)
        let localCalendar = Calendar.current
        let now = localCalendar.date(from: DateComponents(year: 2026, month: 8, day: 27, hour: 12))!
        let dayKey = MuseLocalSessionScanner.dayKey(for: now, calendar: localCalendar)!
        let sessionDir = root.appendingPathComponent("sessions/\(dayKey.replacingOccurrences(of: "-", with: "/"))/sess", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
        let fileURL = sessionDir.appendingPathComponent("session.jsonl")
        let line1 = makeSessionLine(recordedAtMicroseconds: microseconds(for: now), inputTokens: 100, outputTokens: 10)
        let line2 = makeSessionLine(recordedAtMicroseconds: microseconds(for: now.addingTimeInterval(60)), inputTokens: 200, outputTokens: 20)
        try (line1 + "\n" + line2).write(to: fileURL, atomically: true, encoding: .utf8)
        let first = MuseLocalSessionScanner.summarize(env: ["MUSE_HOME": root.path], lookbackDays: 30, now: now)
        #expect(first.requestCount == 2)
        #expect(first.totalTokens == 330)

        // Truncate to single event (replace)
        let line3 = makeSessionLine(recordedAtMicroseconds: microseconds(for: now), inputTokens: 999, outputTokens: 99)
        try line3.write(to: fileURL, atomically: true, encoding: .utf8)

        let second = MuseLocalSessionScanner.summarize(env: ["MUSE_HOME": root.path], lookbackDays: 30, now: now)
        #expect(second.requestCount == 1)
        #expect(second.totalTokens == 1098)
    }

    @Test func deletedFileRemovesContribution() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("muse-inc-delete-\(UUID().uuidString)", isDirectory: true)
        let localCalendar = Calendar.current
        let now = localCalendar.date(from: DateComponents(year: 2026, month: 8, day: 27, hour: 12))!
        let dayKey = MuseLocalSessionScanner.dayKey(for: now, calendar: localCalendar)!
        let dir1 = root.appendingPathComponent("sessions/\(dayKey.replacingOccurrences(of: "-", with: "/"))/sess1", isDirectory: true)
        let dir2 = root.appendingPathComponent("sessions/\(dayKey.replacingOccurrences(of: "-", with: "/"))/sess2", isDirectory: true)
        try FileManager.default.createDirectory(at: dir1, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dir2, withIntermediateDirectories: true)
        let line1 = makeSessionLine(recordedAtMicroseconds: microseconds(for: now), inputTokens: 100, outputTokens: 10)
        let line2 = makeSessionLine(recordedAtMicroseconds: microseconds(for: now), inputTokens: 200, outputTokens: 20)
        try line1.write(to: dir1.appendingPathComponent("session.jsonl"), atomically: true, encoding: .utf8)
        try line2.write(to: dir2.appendingPathComponent("session.jsonl"), atomically: true, encoding: .utf8)
        let first = MuseLocalSessionScanner.summarize(env: ["MUSE_HOME": root.path], lookbackDays: 30, now: now)
        #expect(first.requestCount == 2)

        try FileManager.default.removeItem(at: dir2.appendingPathComponent("session.jsonl"))

        let second = MuseLocalSessionScanner.summarize(env: ["MUSE_HOME": root.path], lookbackDays: 30, now: now)
        #expect(second.requestCount == 1)
        #expect(second.totalTokens == 110)
    }

    @Test func lookbackExpiryAgesOut() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("muse-inc-expiry-\(UUID().uuidString)", isDirectory: true)
        let localCalendar = Calendar.current
        let now = localCalendar.date(from: DateComponents(year: 2026, month: 8, day: 27, hour: 12))!
        let oldDate = localCalendar.date(byAdding: .day, value: -10, to: now)!
        let oldKey = MuseLocalSessionScanner.dayKey(for: oldDate, calendar: localCalendar)!
        let recentKey = MuseLocalSessionScanner.dayKey(for: now, calendar: localCalendar)!
        let oldDir = root.appendingPathComponent("sessions/\(oldKey.replacingOccurrences(of: "-", with: "/"))/old", isDirectory: true)
        let recentDir = root.appendingPathComponent("sessions/\(recentKey.replacingOccurrences(of: "-", with: "/"))/recent", isDirectory: true)
        try FileManager.default.createDirectory(at: oldDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: recentDir, withIntermediateDirectories: true)
        let oldLine = makeSessionLine(recordedAtMicroseconds: microseconds(for: oldDate), inputTokens: 100, outputTokens: 10)
        let recentLine = makeSessionLine(recordedAtMicroseconds: microseconds(for: now), inputTokens: 200, outputTokens: 20)
        try oldLine.write(to: oldDir.appendingPathComponent("session.jsonl"), atomically: true, encoding: .utf8)
        try recentLine.write(to: recentDir.appendingPathComponent("session.jsonl"), atomically: true, encoding: .utf8)

        let with7 = MuseLocalSessionScanner.summarize(env: ["MUSE_HOME": root.path], lookbackDays: 7, now: now)
        #expect(with7.requestCount == 1)
        #expect(with7.totalTokens == 220)

        let with30 = MuseLocalSessionScanner.summarize(env: ["MUSE_HOME": root.path], lookbackDays: 30, now: now)
        #expect(with30.requestCount == 2)
        #expect(with30.totalTokens == 330)
    }

    @Test func wrappedRecordJsonIsSupported() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("muse-inc-wrapped-\(UUID().uuidString)", isDirectory: true)
        let localCalendar = Calendar.current
        let now = localCalendar.date(from: DateComponents(year: 2026, month: 8, day: 27, hour: 12))!
        let dayKey = MuseLocalSessionScanner.dayKey(for: now, calendar: localCalendar)!
        let sessionDir = root.appendingPathComponent("sessions/\(dayKey.replacingOccurrences(of: "-", with: "/"))/sess", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
        let wrapped = makeWrappedLine(recordedAtMicroseconds: microseconds(for: now), inputTokens: 500, outputTokens: 50)
        try wrapped.write(to: sessionDir.appendingPathComponent("session.jsonl"), atomically: true, encoding: .utf8)
        let summary = MuseLocalSessionScanner.summarize(env: ["MUSE_HOME": root.path], lookbackDays: 30, now: now)
        #expect(summary.requestCount == 1)
        #expect(summary.totalTokens == 550)
    }

    // MARK: - Audit regression tests

    @Test func largerReplacementAtSamePathReparsesInsteadOfAppending() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("muse-inc-larger-replace-\(UUID().uuidString)", isDirectory: true)
        let localCalendar = Calendar.current
        let now = localCalendar.date(from: DateComponents(year: 2026, month: 8, day: 27, hour: 12))!
        let dayKey = MuseLocalSessionScanner.dayKey(for: now, calendar: localCalendar)!
        let sessionDir = root.appendingPathComponent("sessions/\(dayKey.replacingOccurrences(of: "-", with: "/"))/sess", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
        let fileURL = sessionDir.appendingPathComponent("session.jsonl")
        let lineA = makeSessionLine(recordedAtMicroseconds: microseconds(for: now), inputTokens: 100, outputTokens: 10, model: "model-a")
        try lineA.write(to: fileURL, atomically: true, encoding: .utf8)
        let first = MuseLocalSessionScanner.summarize(env: ["MUSE_HOME": root.path], lookbackDays: 30, now: now)
        #expect(first.requestCount == 1)
        #expect(first.totalTokens == 110)

        // Replace with larger completely different content (2 events, different prefix, larger size)
        let lineB = makeSessionLine(recordedAtMicroseconds: microseconds(for: now.addingTimeInterval(10)), inputTokens: 200, outputTokens: 20, model: "model-bxxx-different-prefix-to-ensure-fingerprint-mismatch-1234567890")
        let lineC = makeSessionLine(recordedAtMicroseconds: microseconds(for: now.addingTimeInterval(20)), inputTokens: 300, outputTokens: 30, model: "model-c")
        let replacement = [lineB, lineC].joined(separator: "\n")
        // Ensure larger
        #expect(replacement.count > lineA.count)
        try replacement.write(to: fileURL, atomically: true, encoding: .utf8)

        let second = MuseLocalSessionScanner.summarize(env: ["MUSE_HOME": root.path], lookbackDays: 30, now: now)
        // Must be 2, not 3 (which would be 1 old + 2 new if mistakenly appended)
        #expect(second.requestCount == 2)
        #expect(second.totalTokens == 550)
    }

    @Test func timezoneChangeRebucketsOrInvalidates() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("muse-inc-tz-\(UUID().uuidString)", isDirectory: true)
        // Use a date near midnight to test bucket movement across timezones
        var utcCalendar = Calendar(identifier: .gregorian)
        utcCalendar.timeZone = TimeZone(identifier: "UTC")!
        let nowUTC = utcCalendar.date(from: DateComponents(year: 2026, month: 8, day: 27, hour: 23, minute: 30))!
        let dayKeyUTC = MuseLocalSessionScanner.dayKey(for: nowUTC, calendar: utcCalendar)!
        let sessionDir = root.appendingPathComponent("sessions/\(dayKeyUTC.replacingOccurrences(of: "-", with: "/"))/sess", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
        let line = makeSessionLine(recordedAtMicroseconds: microseconds(for: nowUTC), inputTokens: 100, outputTokens: 10)
        try line.write(to: sessionDir.appendingPathComponent("session.jsonl"), atomically: true, encoding: .utf8)

        // First scan with UTC calendar (simulate by setting Cache timezone to UTC)
        var cache = MuseSessionCostCache(version: 1)
        cache.timeZoneIdentifier = "UTC"
        MuseSessionCostCacheIO.save(cache: cache, cacheRoot: root, calendar: utcCalendar)
        // Now summarize with a different timezone (Asia/Tokyo) — scanner uses Calendar.current, so we simulate by
        // directly testing cache invalidation logic: save a cache with UTC identifier, then load with Tokyo calendar
        // should invalidate (tested via summarizeCancellable which checks Calendar.current)
        // Instead we test the raw cache load path: write cache with UTC, then create a calendar with Tokyo and verify
        // that a fresh summarize with Tokyo would reset.
        // We simulate by manually invoking the timezone check: cache.timeZoneIdentifier != Calendar.current
        // For deterministic test, we directly verify that MuseSessionCostCacheIO load respects version but not timezone,
        // and that summarize resets when timezone differs.

        // Create a cache with UTC day
        let firstSummary = MuseLocalSessionScanner.summarize(env: ["MUSE_HOME": root.path], lookbackDays: 30, now: nowUTC)
        #expect(firstSummary.requestCount == 1)

        // Now simulate timezone change by writing a cache with stale timezone and verifying next summarize rebuilds
        var staleCache = MuseSessionCostCacheIO.load(cacheRoot: root)
        staleCache.timeZoneIdentifier = "Etc/GMT-12" // different from current
        MuseSessionCostCacheIO.save(cache: staleCache, cacheRoot: root, calendar: utcCalendar)
        // Next summarize should detect timezone mismatch and rebuild (not double-count)
        let secondSummary = MuseLocalSessionScanner.summarize(env: ["MUSE_HOME": root.path], lookbackDays: 30, now: nowUTC)
        #expect(secondSummary.requestCount == 1)
        #expect(secondSummary.totalTokens == 110)
        // Ensure cache after second scan has current timezone identifier
        let reloaded = MuseSessionCostCacheIO.load(cacheRoot: root)
        #expect(reloaded.timeZoneIdentifier == Calendar.current.timeZone.identifier)
    }

    @Test func historicalCachePruningRemovesExpiredFilesAndDays() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("muse-inc-prune-\(UUID().uuidString)", isDirectory: true)
        let localCalendar = Calendar.current
        let now = localCalendar.date(from: DateComponents(year: 2026, month: 8, day: 27, hour: 12))!
        let oldDate = localCalendar.date(byAdding: .day, value: -60, to: now)!
        let oldKey = MuseLocalSessionScanner.dayKey(for: oldDate, calendar: localCalendar)!
        let recentKey = MuseLocalSessionScanner.dayKey(for: now, calendar: localCalendar)!
        let oldDir = root.appendingPathComponent("sessions/\(oldKey.replacingOccurrences(of: "-", with: "/"))/old", isDirectory: true)
        let recentDir = root.appendingPathComponent("sessions/\(recentKey.replacingOccurrences(of: "-", with: "/"))/recent", isDirectory: true)
        try FileManager.default.createDirectory(at: oldDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: recentDir, withIntermediateDirectories: true)
        let oldLine = makeSessionLine(recordedAtMicroseconds: microseconds(for: oldDate), inputTokens: 100, outputTokens: 10)
        let recentLine = makeSessionLine(recordedAtMicroseconds: microseconds(for: now), inputTokens: 200, outputTokens: 20)
        try oldLine.write(to: oldDir.appendingPathComponent("session.jsonl"), atomically: true, encoding: .utf8)
        try recentLine.write(to: recentDir.appendingPathComponent("session.jsonl"), atomically: true, encoding: .utf8)

        // Initial 30-day scan includes only recent, but we first do a 90-day scan to populate old entry
        let wide = MuseLocalSessionScanner.summarize(env: ["MUSE_HOME": root.path], lookbackDays: 90, now: now)
        #expect(wide.requestCount == 2)
        let cacheBefore = MuseSessionCostCacheIO.load(cacheRoot: root)
        #expect(cacheBefore.files.count == 2)
        #expect(cacheBefore.days.count >= 2)
        let sizeBefore = try Data(contentsOf: MuseSessionCostCacheIO.cacheFileURL(cacheRoot: root)).count

        // Now narrow to 7 days: old should be pruned from persisted cache, not just filtered in summary
        let narrow = MuseLocalSessionScanner.summarize(env: ["MUSE_HOME": root.path], lookbackDays: 7, now: now)
        #expect(narrow.requestCount == 1)
        let cacheAfter = MuseSessionCostCacheIO.load(cacheRoot: root)
        #expect(cacheAfter.files.count == 1)
        // Old day should be physically removed
        #expect(cacheAfter.days[oldKey] == nil)
        let sizeAfter = try Data(contentsOf: MuseSessionCostCacheIO.cacheFileURL(cacheRoot: root)).count
        #expect(sizeAfter < sizeBefore)
        #expect(sizeAfter > 0)
    }

    @Test func corruptCacheRecoveryDoesNotCrash() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("muse-inc-corrupt-\(UUID().uuidString)", isDirectory: true)
        let localCalendar = Calendar.current
        let now = localCalendar.date(from: DateComponents(year: 2026, month: 8, day: 27, hour: 12))!
        let dayKey = MuseLocalSessionScanner.dayKey(for: now, calendar: localCalendar)!
        let sessionDir = root.appendingPathComponent("sessions/\(dayKey.replacingOccurrences(of: "-", with: "/"))/sess", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
        let line = makeSessionLine(recordedAtMicroseconds: microseconds(for: now), inputTokens: 100, outputTokens: 10)
        try line.write(to: sessionDir.appendingPathComponent("session.jsonl"), atomically: true, encoding: .utf8)

        let valid = MuseLocalSessionScanner.summarize(env: ["MUSE_HOME": root.path], lookbackDays: 30, now: now)
        #expect(valid.requestCount == 1)

        let cacheURL = MuseSessionCostCacheIO.cacheFileURL(cacheRoot: root)
        // Malformed JSON
        try Data("not json at all".utf8).write(to: cacheURL)
        let afterMalformed = MuseLocalSessionScanner.summarize(env: ["MUSE_HOME": root.path], lookbackDays: 30, now: now)
        #expect(afterMalformed.requestCount == 1)

        // Truncated JSON
        let validData = try Data(contentsOf: cacheURL)
        try validData.prefix(validData.count / 2).write(to: cacheURL)
        let afterTruncated = MuseLocalSessionScanner.summarize(env: ["MUSE_HOME": root.path], lookbackDays: 30, now: now)
        #expect(afterTruncated.requestCount == 1)

        // Incompatible version
        var cache = MuseSessionCostCache(version: 999)
        cache.days = ["2099-01-01": ["m": MusePackedUsage(inputTokens: 999, outputTokens: 999, totalTokens: 1998, requestCount: 1)]]
        let badData = try JSONEncoder().encode(cache)
        try badData.write(to: cacheURL)
        let afterVersion = MuseLocalSessionScanner.summarize(env: ["MUSE_HOME": root.path], lookbackDays: 30, now: now)
        #expect(afterVersion.requestCount == 1)
        let reloaded = MuseSessionCostCacheIO.load(cacheRoot: root)
        #expect(reloaded.version == 1)
        #expect(reloaded.days["2099-01-01"] == nil)
    }

    @Test func atomicWritesProduceValidJSON() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("muse-inc-atomic-\(UUID().uuidString)", isDirectory: true)
        let localCalendar = Calendar.current
        let now = localCalendar.date(from: DateComponents(year: 2026, month: 8, day: 27, hour: 12))!
        let dayKey = MuseLocalSessionScanner.dayKey(for: now, calendar: localCalendar)!
        let sessionDir = root.appendingPathComponent("sessions/\(dayKey.replacingOccurrences(of: "-", with: "/"))/sess", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
        let line = makeSessionLine(recordedAtMicroseconds: microseconds(for: now), inputTokens: 100, outputTokens: 10)
        try line.write(to: sessionDir.appendingPathComponent("session.jsonl"), atomically: true, encoding: .utf8)

        for _ in 0..<5 {
            _ = MuseLocalSessionScanner.summarize(env: ["MUSE_HOME": root.path], lookbackDays: 30, now: now)
            let cacheURL = MuseSessionCostCacheIO.cacheFileURL(cacheRoot: root)
            let data = try Data(contentsOf: cacheURL)
            // Must be valid JSON and decode
            let decoded = try JSONDecoder().decode(MuseSessionCostCache.self, from: data)
            #expect(decoded.version == 1)
            // No partial writes: file should not be empty or truncated
            #expect(data.count > 10)
        }
    }

    @Test func cancellationDoesNotPersistPartialCache() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("muse-inc-cancel-\(UUID().uuidString)", isDirectory: true)
        let localCalendar = Calendar.current
        let now = localCalendar.date(from: DateComponents(year: 2026, month: 8, day: 27, hour: 12))!
        let dayKey = MuseLocalSessionScanner.dayKey(for: now, calendar: localCalendar)!
        let dir1 = root.appendingPathComponent("sessions/\(dayKey.replacingOccurrences(of: "-", with: "/"))/a", isDirectory: true)
        let dir2 = root.appendingPathComponent("sessions/\(dayKey.replacingOccurrences(of: "-", with: "/"))/b", isDirectory: true)
        try FileManager.default.createDirectory(at: dir1, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dir2, withIntermediateDirectories: true)
        let line1 = makeSessionLine(recordedAtMicroseconds: microseconds(for: now), inputTokens: 100, outputTokens: 10)
        let line2 = makeSessionLine(recordedAtMicroseconds: microseconds(for: now), inputTokens: 200, outputTokens: 20)
        try line1.write(to: dir1.appendingPathComponent("session.jsonl"), atomically: true, encoding: .utf8)
        try line2.write(to: dir2.appendingPathComponent("session.jsonl"), atomically: true, encoding: .utf8)

        // Prime cache with first file only
        let first = MuseLocalSessionScanner.summarize(env: ["MUSE_HOME": root.path], lookbackDays: 30, now: now)
        #expect(first.requestCount == 2)
        let cacheBefore = MuseSessionCostCacheIO.load(cacheRoot: root)
        let beforeData = try JSONEncoder().encode(cacheBefore)

        // Now append to one file and attempt cancellable scan that throws mid-way
        let line3 = makeSessionLine(recordedAtMicroseconds: microseconds(for: now.addingTimeInterval(60)), inputTokens: 300, outputTokens: 30)
        let file1URL = dir1.appendingPathComponent("session.jsonl")
        let handle = try FileHandle(forWritingTo: file1URL)
        try handle.seekToEnd()
        try handle.write(contentsOf: ("\n" + line3).data(using: .utf8)!)
        try handle.close()

        var checkCount = 0
        do {
            _ = try MuseLocalSessionScanner.summarizeCancellable(env: ["MUSE_HOME": root.path], fileManager: .default, lookbackDays: 30, now: now, fileScanObserver: nil, checkCancellation: {
                checkCount += 1
                if checkCount == 3 { throw CancellationError() } // after first file, before second — tests partial not persisted
            })
            Issue.record("Expected cancellation")
        } catch is CancellationError {
            // Expected
        }

        let cacheAfter = MuseSessionCostCacheIO.load(cacheRoot: root)
        // Cache must be unchanged (no partial delta persisted) — compare files/days, ignore lastScanUnixMs
        #expect(cacheAfter.files == cacheBefore.files)
        #expect(cacheAfter.days == cacheBefore.days)

        // A normal scan after cancellation should still correctly apply the delta exactly once
        let afterRetry = MuseLocalSessionScanner.summarize(env: ["MUSE_HOME": root.path], lookbackDays: 30, now: now)
        #expect(afterRetry.requestCount == 3)
        #expect(afterRetry.totalTokens == 660)
    }

    @Test func appendBoundaryIncompleteTrailingLineNotSkipped() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("muse-inc-boundary-\(UUID().uuidString)", isDirectory: true)
        let localCalendar = Calendar.current
        let now = localCalendar.date(from: DateComponents(year: 2026, month: 8, day: 27, hour: 12))!
        let dayKey = MuseLocalSessionScanner.dayKey(for: now, calendar: localCalendar)!
        let sessionDir = root.appendingPathComponent("sessions/\(dayKey.replacingOccurrences(of: "-", with: "/"))/sess", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
        let fileURL = sessionDir.appendingPathComponent("session.jsonl")
        let line1 = makeSessionLine(recordedAtMicroseconds: microseconds(for: now), inputTokens: 100, outputTokens: 10)
        // Write first line with newline
        try (line1 + "\n").write(to: fileURL, atomically: true, encoding: .utf8)
        let first = MuseLocalSessionScanner.summarize(env: ["MUSE_HOME": root.path], lookbackDays: 30, now: now)
        #expect(first.requestCount == 1)

        // Append incomplete line without newline (simulate crash mid-write)
        let line2 = makeSessionLine(recordedAtMicroseconds: microseconds(for: now.addingTimeInterval(10)), inputTokens: 200, outputTokens: 20)
        let partial = String(line2.prefix(line2.count / 2)) // truncated JSON
        let handle = try FileHandle(forWritingTo: fileURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: partial.data(using: .utf8)!)
        try handle.close()

        let second = MuseLocalSessionScanner.summarize(env: ["MUSE_HOME": root.path], lookbackDays: 30, now: now)
        // Incomplete line must not be counted, and must not be permanently skipped
        #expect(second.requestCount == 1)

        // Now complete the line by appending the remainder + newline
        let remainder = String(line2.suffix(line2.count - partial.count))
        let handle2 = try FileHandle(forWritingTo: fileURL)
        try handle2.seekToEnd()
        try handle2.write(contentsOf: (remainder + "\n").data(using: .utf8)!)
        try handle2.close()

        let third = MuseLocalSessionScanner.summarize(env: ["MUSE_HOME": root.path], lookbackDays: 30, now: now)
        // Must be exactly 2, not 1 and not 3 (double-count)
        #expect(third.requestCount == 2)
        #expect(third.totalTokens == 330)

        // Also verify wrapped format follows same boundary
        let wrapped = makeWrappedLine(recordedAtMicroseconds: microseconds(for: now.addingTimeInterval(20)), inputTokens: 300, outputTokens: 30)
        let partialWrapped = String(wrapped.prefix(wrapped.count / 2))
        try partialWrapped.write(to: fileURL, atomically: true, encoding: .utf8) // overwrite for isolated wrapped test
        // Instead test wrapped append correctly: create new file
        let dir2 = root.appendingPathComponent("sessions/\(dayKey.replacingOccurrences(of: "-", with: "/"))/wrapped", isDirectory: true)
        try FileManager.default.createDirectory(at: dir2, withIntermediateDirectories: true)
        let wrappedFile = dir2.appendingPathComponent("session.jsonl")
        let wrappedLine = makeWrappedLine(recordedAtMicroseconds: microseconds(for: now), inputTokens: 400, outputTokens: 40)
        // Write with newline then incomplete wrapped
        try (wrappedLine + "\n" + String(wrapped.prefix(10))).write(to: wrappedFile, atomically: true, encoding: .utf8)
        let fourth = MuseLocalSessionScanner.summarize(env: ["MUSE_HOME": root.path], lookbackDays: 30, now: now)
        // Should count the wrappedLine (1) plus previous 2 from first file = 3
        #expect(fourth.requestCount == 3)
    }

    @Test func deletedDirectoryRemovesContributions() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("muse-inc-del-dir-\(UUID().uuidString)", isDirectory: true)
        let localCalendar = Calendar.current
        let now = localCalendar.date(from: DateComponents(year: 2026, month: 8, day: 27, hour: 12))!
        let dayKey = MuseLocalSessionScanner.dayKey(for: now, calendar: localCalendar)!
        let dir = root.appendingPathComponent("sessions/\(dayKey.replacingOccurrences(of: "-", with: "/"))/todelete", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let line = makeSessionLine(recordedAtMicroseconds: microseconds(for: now), inputTokens: 100, outputTokens: 10)
        try line.write(to: dir.appendingPathComponent("session.jsonl"), atomically: true, encoding: .utf8)
        let first = MuseLocalSessionScanner.summarize(env: ["MUSE_HOME": root.path], lookbackDays: 30, now: now)
        #expect(first.requestCount == 1)

        try FileManager.default.removeItem(at: dir)

        let second = MuseLocalSessionScanner.summarize(env: ["MUSE_HOME": root.path], lookbackDays: 30, now: now)
        #expect(second.requestCount == 0)
        let cache = MuseSessionCostCacheIO.load(cacheRoot: root)
        #expect(cache.files.isEmpty)
        #expect(cache.days.isEmpty)
    }

    @Test func deletedFileNotDoubleSubtractedOnAgingOut() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("muse-inc-del-aging-\(UUID().uuidString)", isDirectory: true)
        let localCalendar = Calendar.current
        let now = localCalendar.date(from: DateComponents(year: 2026, month: 8, day: 27, hour: 12))!
        let recentKey = MuseLocalSessionScanner.dayKey(for: now, calendar: localCalendar)!
        let recentDir = root.appendingPathComponent("sessions/\(recentKey.replacingOccurrences(of: "-", with: "/"))/recent", isDirectory: true)
        try FileManager.default.createDirectory(at: recentDir, withIntermediateDirectories: true)
        let line = makeSessionLine(recordedAtMicroseconds: microseconds(for: now), inputTokens: 100, outputTokens: 10)
        try line.write(to: recentDir.appendingPathComponent("session.jsonl"), atomically: true, encoding: .utf8)
        let first = MuseLocalSessionScanner.summarize(env: ["MUSE_HOME": root.path], lookbackDays: 30, now: now)
        #expect(first.requestCount == 1)

        // Delete file
        try FileManager.default.removeItem(at: recentDir.appendingPathComponent("session.jsonl"))
        let second = MuseLocalSessionScanner.summarize(env: ["MUSE_HOME": root.path], lookbackDays: 30, now: now)
        #expect(second.requestCount == 0)

        // Aging out should not cause negative or double subtract
        let later = localCalendar.date(byAdding: .day, value: 31, to: now)!
        let third = MuseLocalSessionScanner.summarize(env: ["MUSE_HOME": root.path], lookbackDays: 30, now: later)
        #expect(third.requestCount == 0)
        let cache = MuseSessionCostCacheIO.load(cacheRoot: root)
        #expect(cache.files.isEmpty)
    }
}
