import CodexBarCore
import Foundation
import SQLite3
import Testing

struct WindsurfStatusProbeTests {
    // MARK: - Helper

    private static func decode(_ json: String) throws -> WindsurfCachedPlanInfo {
        try JSONDecoder().decode(WindsurfCachedPlanInfo.self, from: Data(json.utf8))
    }

    // MARK: - JSON Decoding

    @Test
    func `decodes full plan info`() throws {
        let info = try Self.decode("""
        {
          "planName": "Pro",
          "startTimestamp": 1771610750000,
          "endTimestamp": 1774029950000,
          "usage": {
            "messages": 50000,
            "usedMessages": 35650,
            "remainingMessages": 14350,
            "flowActions": 150000,
            "usedFlowActions": 0,
            "remainingFlowActions": 150000
          },
          "quotaUsage": {
            "dailyRemainingPercent": 9,
            "weeklyRemainingPercent": 54,
            "dailyResetAtUnix": 1774080000,
            "weeklyResetAtUnix": 1774166400
          }
        }
        """)

        #expect(info.planName == "Pro")
        #expect(info.startTimestamp == 1_771_610_750_000)
        #expect(info.endTimestamp == 1_774_029_950_000)
        #expect(info.usage?.messages == 50000)
        #expect(info.usage?.usedMessages == 35650)
        #expect(info.usage?.remainingMessages == 14350)
        #expect(info.usage?.flowActions == 150_000)
        #expect(info.usage?.usedFlowActions == 0)
        #expect(info.usage?.remainingFlowActions == 150_000)
        #expect(info.quotaUsage?.dailyRemainingPercent == 9)
        #expect(info.quotaUsage?.weeklyRemainingPercent == 54)
        #expect(info.quotaUsage?.dailyResetAtUnix == 1_774_080_000)
        #expect(info.quotaUsage?.weeklyResetAtUnix == 1_774_166_400)
    }

    @Test
    func `decodes minimal plan info`() throws {
        let info = try Self.decode("""
        {"planName": "Free"}
        """)

        #expect(info.planName == "Free")
        #expect(info.usage == nil)
        #expect(info.quotaUsage == nil)
        #expect(info.endTimestamp == nil)
    }

    @Test
    func `decodes empty object`() throws {
        let info = try Self.decode("{}")

        #expect(info.planName == nil)
        #expect(info.usage == nil)
        #expect(info.quotaUsage == nil)
    }

    // MARK: - toUsageSnapshot Conversion

    @Test
    func `converts full plan to usage snapshot`() throws {
        let info = try Self.decode("""
        {
          "planName": "Pro",
          "startTimestamp": 1771610750000,
          "endTimestamp": 1774029950000,
          "usage": {
            "messages": 50000, "usedMessages": 35650, "remainingMessages": 14350,
            "flowActions": 150000, "usedFlowActions": 0, "remainingFlowActions": 150000
          },
          "quotaUsage": {
            "dailyRemainingPercent": 9, "weeklyRemainingPercent": 54,
            "dailyResetAtUnix": 1774080000, "weeklyResetAtUnix": 1774166400
          }
        }
        """)

        let snapshot = info.toUsageSnapshot()

        // Primary = daily: usedPercent = 100 - 9 = 91
        #expect(snapshot.primary?.usedPercent == 91)
        #expect(snapshot.primary?.resetsAt != nil)

        // Secondary = weekly: usedPercent = 100 - 54 = 46
        #expect(snapshot.secondary?.usedPercent == 46)
        #expect(snapshot.secondary?.resetsAt != nil)

        // Identity
        #expect(snapshot.identity?.providerID == .windsurf)
        #expect(snapshot.identity?.loginMethod == "Pro")
        #expect(snapshot.identity?.accountOrganization != nil)
    }

    @Test
    func `converts minimal plan to usage snapshot`() throws {
        let info = try Self.decode("""
        {"planName": "Free"}
        """)

        let snapshot = info.toUsageSnapshot()

        // Without quotaUsage, primary and secondary should be nil
        #expect(snapshot.primary == nil)
        #expect(snapshot.secondary == nil)
        #expect(snapshot.identity?.loginMethod == "Free")
        #expect(snapshot.identity?.accountOrganization == nil)
    }

    @Test
    func `converts usage counts when quota usage is absent`() throws {
        let info = try Self.decode("""
        {
          "planName": "Pro",
          "usage": {
            "messages": 50000,
            "usedMessages": 1200,
            "remainingMessages": 48800,
            "flowActions": 150000,
            "usedFlowActions": 0,
            "remainingFlowActions": 150000,
            "flexCredits": 123700,
            "usedFlexCredits": 0,
            "remainingFlexCredits": 123700
          }
        }
        """)

        let snapshot = info.toUsageSnapshot()

        #expect(snapshot.primary?.usedPercent == 2.4)
        #expect(snapshot.primary?.resetDescription == "1200 / 50000 messages")
        #expect(snapshot.secondary?.usedPercent == 0)
        #expect(snapshot.secondary?.resetDescription == "0 / 150000 flow actions")
    }

    @Test
    func `usage counts infer used amount from remaining`() throws {
        let info = try Self.decode("""
        {
          "planName": "Pro",
          "usage": {
            "messages": 100,
            "remainingMessages": 25
          }
        }
        """)

        let snapshot = info.toUsageSnapshot()

        #expect(snapshot.primary?.usedPercent == 75)
        #expect(snapshot.primary?.resetDescription == "75 / 100 messages")
        #expect(snapshot.secondary == nil)
    }

    @Test
    func `daily at zero remaining shows 100 percent used`() throws {
        let info = try Self.decode("""
        {
          "planName": "Pro",
          "quotaUsage": {"dailyRemainingPercent": 0, "weeklyRemainingPercent": 100}
        }
        """)

        let snapshot = info.toUsageSnapshot()

        #expect(snapshot.primary?.usedPercent == 100)
        #expect(snapshot.secondary?.usedPercent == 0)
    }

    @Test
    func `weekly at full remaining shows 0 percent used`() throws {
        let info = try Self.decode("""
        {
          "planName": "Pro",
          "quotaUsage": {"dailyRemainingPercent": 100, "weeklyRemainingPercent": 100}
        }
        """)

        let snapshot = info.toUsageSnapshot()

        #expect(snapshot.primary?.usedPercent == 0)
        #expect(snapshot.secondary?.usedPercent == 0)
    }

    @Test
    func `reset dates are correctly converted from unix timestamps`() throws {
        let info = try Self.decode("""
        {
          "planName": "Pro",
          "quotaUsage": {
            "dailyRemainingPercent": 50, "weeklyRemainingPercent": 50,
            "dailyResetAtUnix": 1774080000, "weeklyResetAtUnix": 1774166400
          }
        }
        """)

        let snapshot = info.toUsageSnapshot()

        #expect(snapshot.primary?.resetsAt == Date(timeIntervalSince1970: 1_774_080_000))
        #expect(snapshot.secondary?.resetsAt == Date(timeIntervalSince1970: 1_774_166_400))
    }

    @Test
    func `end timestamp converts to expiry description`() throws {
        let futureMs = Int64(Date().addingTimeInterval(86400 * 30).timeIntervalSince1970 * 1000)
        let info = try Self.decode("""
        {"planName": "Pro", "endTimestamp": \(futureMs)}
        """)

        let snapshot = info.toUsageSnapshot()

        #expect(snapshot.identity?.accountOrganization?.hasPrefix("Expires ") == true)
    }

    // MARK: - Probe Database Decoding

    @Test
    func `probe decodes UTF-8 JSON blob`() throws {
        let dbURL = try Self.makeTemporaryDatabase(
            jsonData: Data(#"{"planName":"UTF-8 Pro"}"#.utf8))
        defer { try? FileManager.default.removeItem(at: dbURL.deletingLastPathComponent()) }

        let info = try WindsurfStatusProbe(dbPath: dbURL.path).fetch()

        #expect(info.planName == "UTF-8 Pro")
    }

    @Test
    func `probe decodes UTF-16LE JSON blob`() throws {
        let jsonData = try #require(#"{"planName":"UTF-16 Pro"}"#.data(using: .utf16LittleEndian))
        let dbURL = try Self.makeTemporaryDatabase(jsonData: jsonData)
        defer { try? FileManager.default.removeItem(at: dbURL.deletingLastPathComponent()) }

        let info = try WindsurfStatusProbe(dbPath: dbURL.path).fetch()

        #expect(info.planName == "UTF-16 Pro")
    }

    // MARK: - Probe Error Cases

    @Test
    func `probe throws dbNotFound for missing file`() {
        let probe = WindsurfStatusProbe(dbPath: "/nonexistent/path/state.vscdb")

        #expect(throws: WindsurfStatusProbeError.self) {
            _ = try probe.fetch()
        }
    }

    private static func makeTemporaryDatabase(jsonData: Data) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("windsurf-status-probe-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let dbURL = directory.appendingPathComponent("state.vscdb")

        var db: OpaquePointer?
        guard sqlite3_open(dbURL.path, &db) == SQLITE_OK else {
            throw TestSQLiteError.openFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_close(db) }

        try self.execute(
            """
            CREATE TABLE ItemTable(
                key TEXT PRIMARY KEY,
                value BLOB
            );
            """,
            db: db)

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(
            db,
            "INSERT INTO ItemTable(key, value) VALUES('windsurf.settings.cachedPlanInfo', ?);",
            -1,
            &stmt,
            nil) == SQLITE_OK
        else {
            throw TestSQLiteError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        let bindResult = jsonData.withUnsafeBytes { buffer in
            sqlite3_bind_blob(stmt, 1, buffer.baseAddress, Int32(jsonData.count), transient)
        }
        guard bindResult == SQLITE_OK else {
            throw TestSQLiteError.bindFailed(String(cString: sqlite3_errmsg(db)))
        }
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw TestSQLiteError.stepFailed(String(cString: sqlite3_errmsg(db)))
        }

        return dbURL
    }

    private static func execute(_ sql: String, db: OpaquePointer?) throws {
        var errorMessage: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &errorMessage) == SQLITE_OK else {
            defer { sqlite3_free(errorMessage) }
            let message = errorMessage.map { String(cString: $0) } ?? "unknown error"
            throw TestSQLiteError.execFailed(message)
        }
    }

    private enum TestSQLiteError: Error {
        case openFailed(String)
        case execFailed(String)
        case prepareFailed(String)
        case bindFailed(String)
        case stepFailed(String)
    }
}
