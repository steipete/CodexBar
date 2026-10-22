import Foundation
import Testing

@testable import CodexBarCore

#if canImport(SQLite3)
import SQLite3

struct OpenCodeLocalHistoryStoreTests {
    @Test
    func `selects only openai provider records`() throws {
        let env = try Self.makeEnvironment()
        defer { try? FileManager.default.removeItem(at: env.root) }
        try Self.createDatabase(at: env.databaseURL)
        let now = Date(timeIntervalSince1970: 1_772_798_400)
        try Self.insertMessage(
            databaseURL: env.databaseURL, createdMs: Self.ms(now), cost: 1.5,
            model: "gpt-5.1-codex", providerID: "openai")
        try Self.insertMessage(
            databaseURL: env.databaseURL, createdMs: Self.ms(now), cost: 9,
            model: "glm-5.3-max", providerID: "nchc")
        try Self.insertMessage(
            databaseURL: env.databaseURL, createdMs: Self.ms(now), cost: 9,
            model: "claude-sonnet-4-5", providerID: "opencode-go")
        try Self.insertMessage(
            databaseURL: env.databaseURL, createdMs: Self.ms(now), cost: 9,
            model: "gpt-5.1", providerID: "openrouter")

        let loaded = try OpenCodeLocalHistoryStore(
            databaseURL: env.databaseURL,
            cacheURL: env.cacheURL)
            .loadDailyReport(since: now.addingTimeInterval(-3600), until: now, calendar: .current)
        let result = try #require(loaded)
        let entry = try #require(result.data.first)
        #expect(result.data.count == 1)
        #expect(entry.costUSD == 1.5)
        #expect(entry.requestCount == 1)
        #expect(entry.modelsUsed == ["gpt-5.1-codex (OpenCode local)"])
    }

    @Test
    func `step finish parts win over message fallback without double counting`() throws {
        let env = try Self.makeEnvironment()
        defer { try? FileManager.default.removeItem(at: env.root) }
        try Self.createDatabase(at: env.databaseURL)
        let now = Date(timeIntervalSince1970: 1_772_798_400)
        let withParts = try Self.insertMessage(
            databaseURL: env.databaseURL, createdMs: Self.ms(now), cost: 5,
            model: "gpt-5.1-codex", providerID: "openai")
        try Self.insertStepFinishPart(
            databaseURL: env.databaseURL, messageID: withParts, createdMs: Self.ms(now), cost: 2,
            tokens: ["input": 10, "output": 5, "reasoning": 1, "cache": ["read": 4, "write": 0]])
        try Self.insertMessage(
            databaseURL: env.databaseURL, createdMs: Self.ms(now), cost: 3,
            model: "gpt-5.1-codex", providerID: "openai")

        let loaded = try OpenCodeLocalHistoryStore(
            databaseURL: env.databaseURL,
            cacheURL: env.cacheURL)
            .loadDailyReport(since: now.addingTimeInterval(-3600), until: now, calendar: .current)
        let result = try #require(loaded)
        let entry = try #require(result.data.first)
        #expect(entry.costUSD == 5)
        #expect(entry.requestCount == 2)
        #expect(entry.inputTokens == 10)
        #expect(entry.outputTokens == 5)
        #expect(entry.reasoningTokens == 1)
        #expect(entry.cacheReadTokens == 4)
        #expect(entry.cacheCreationTokens == 0)
        // The message-level fallback row has no token metadata, so the day's aggregate total
        // is conservatively unknown even though the component dimensions merge additively.
        #expect(entry.totalTokens == nil)
    }

    @Test
    func `v2 session messages add new turns without double counting migrated ones`() throws {
        let env = try Self.makeEnvironment()
        defer { try? FileManager.default.removeItem(at: env.root) }
        try Self.createDatabase(at: env.databaseURL, includeSessionMessages: true)
        let now = Date(timeIntervalSince1970: 1_772_798_400)
        let migratedID = try Self.insertMessage(
            databaseURL: env.databaseURL, createdMs: Self.ms(now), cost: 3,
            model: "gpt-5.1-codex", providerID: "openai")
        try Self.insertSessionMessage(
            databaseURL: env.databaseURL, id: migratedID, createdMs: Self.ms(now), cost: 3,
            model: "gpt-5.1-codex")
        try Self.insertSessionMessage(
            databaseURL: env.databaseURL, createdMs: Self.ms(now), cost: 2,
            model: "gpt-5.2", tokens: ["input": 7, "output": 3, "total": 10])
        try Self.insertSessionMessage(
            databaseURL: env.databaseURL, createdMs: Self.ms(now), cost: 9,
            model: "glm-5.3-max", providerID: "nchc")

        let loaded = try OpenCodeLocalHistoryStore(
            databaseURL: env.databaseURL,
            cacheURL: env.cacheURL)
            .loadDailyReport(since: now.addingTimeInterval(-3600), until: now, calendar: .current)
        let result = try #require(loaded)
        let entry = try #require(result.data.first)
        #expect(entry.costUSD == 5)
        #expect(entry.requestCount == 2)
        #expect(entry.modelsUsed?.sorted() == ["gpt-5.1-codex (OpenCode local)", "gpt-5.2 (OpenCode local)"])
    }

    @Test
    func `v2 only database without legacy tables is read`() throws {
        let env = try Self.makeEnvironment()
        defer { try? FileManager.default.removeItem(at: env.root) }
        try Self.createV2OnlyDatabase(at: env.databaseURL)
        let now = Date(timeIntervalSince1970: 1_772_798_400)
        try Self.insertSessionMessage(
            databaseURL: env.databaseURL, createdMs: Self.ms(now), cost: 1,
            model: "gpt-5.1-codex", tokens: ["input": 2, "output": 1, "total": 3])

        let loaded = try OpenCodeLocalHistoryStore(
            databaseURL: env.databaseURL,
            cacheURL: env.cacheURL)
            .loadDailyReport(since: now.addingTimeInterval(-3600), until: now, calendar: .current)
        let result = try #require(loaded)
        let entry = try #require(result.data.first)
        #expect(entry.costUSD == 1)
        #expect(entry.requestCount == 1)
        #expect(entry.totalTokens == 3)
    }

    @Test
    func `recorded zero cost keeps token history`() throws {
        let env = try Self.makeEnvironment()
        defer { try? FileManager.default.removeItem(at: env.root) }
        try Self.createDatabase(at: env.databaseURL)
        let now = Date(timeIntervalSince1970: 1_772_798_400)
        try Self.insertMessage(
            databaseURL: env.databaseURL, createdMs: Self.ms(now), cost: 0,
            model: "gpt-5.1-codex", providerID: "openai",
            tokens: ["input": 100, "output": 50, "total": 150])

        let loaded = try OpenCodeLocalHistoryStore(
            databaseURL: env.databaseURL,
            cacheURL: env.cacheURL)
            .loadDailyReport(since: now.addingTimeInterval(-3600), until: now, calendar: .current)
        let result = try #require(loaded)
        let entry = try #require(result.data.first)
        #expect(entry.costUSD == 0)
        #expect(entry.totalTokens == 150)
    }

    @Test
    func `missing and non numeric cost rows are skipped`() throws {
        let env = try Self.makeEnvironment()
        defer { try? FileManager.default.removeItem(at: env.root) }
        try Self.createDatabase(at: env.databaseURL)
        let now = Date(timeIntervalSince1970: 1_772_798_400)
        try Self.insertMessage(
            databaseURL: env.databaseURL, createdMs: Self.ms(now), cost: 1,
            model: "gpt-5.1-codex", providerID: "openai")
        try Self.insertMessage(
            databaseURL: env.databaseURL, createdMs: Self.ms(now), cost: nil,
            model: "gpt-5.1-codex", providerID: "openai")
        try Self.insertRawMessage(
            databaseURL: env.databaseURL,
            json: "{\"providerID\":\"openai\",\"role\":\"assistant\",\"cost\":\"free\"}")

        let result = try OpenCodeLocalHistoryStore(
            databaseURL: env.databaseURL,
            cacheURL: env.cacheURL)
            .loadDailyReport(since: now.addingTimeInterval(-3600), until: now, calendar: .current)
        let entry = try #require(result?.data.first)
        #expect(entry.requestCount == 1)
        #expect(entry.costUSD == 1)
    }

    @Test
    func `negative or overflowing token counts are dropped`() throws {
        let env = try Self.makeEnvironment()
        defer { try? FileManager.default.removeItem(at: env.root) }
        try Self.createDatabase(at: env.databaseURL)
        let now = Date(timeIntervalSince1970: 1_772_798_400)
        try Self.insertMessage(
            databaseURL: env.databaseURL, createdMs: Self.ms(now), cost: 1,
            model: "negative", providerID: "openai",
            tokens: ["input": -5, "output": 1, "total": -4])
        try Self.insertMessage(
            databaseURL: env.databaseURL, createdMs: Self.ms(now), cost: 1,
            model: "overflow", providerID: "openai",
            tokens: ["input": Int.max, "output": 1, "total": Int.max])

        let result = try OpenCodeLocalHistoryStore(
            databaseURL: env.databaseURL,
            cacheURL: env.cacheURL)
            .loadDailyReport(since: now.addingTimeInterval(-3600), until: now, calendar: .current)
        let entry = try #require(result?.data.first)
        #expect(entry.requestCount == 2)
        #expect(entry.totalTokens == nil)
        #expect(entry.modelsUsed?.sorted() == ["negative (OpenCode local)", "overflow (OpenCode local)"])
    }

    @Test
    func `rows outside the requested window are excluded`() throws {
        let env = try Self.makeEnvironment()
        defer { try? FileManager.default.removeItem(at: env.root) }
        try Self.createDatabase(at: env.databaseURL)
        let now = Date(timeIntervalSince1970: 1_772_798_400)
        try Self.insertMessage(
            databaseURL: env.databaseURL, createdMs: Self.ms(now), cost: 1,
            model: "gpt-5.1-codex", providerID: "openai")
        try Self.insertMessage(
            databaseURL: env.databaseURL,
            createdMs: Self.ms(now.addingTimeInterval(-48 * 3600)), cost: 8,
            model: "gpt-5.1-codex", providerID: "openai")

        let result = try OpenCodeLocalHistoryStore(
            databaseURL: env.databaseURL,
            cacheURL: env.cacheURL)
            .loadDailyReport(since: now.addingTimeInterval(-3600), until: now, calendar: .current)
        let entry = try #require(result?.data.first)
        #expect(entry.requestCount == 1)
        #expect(entry.costUSD == 1)
    }

    @Test
    func `missing database or empty history returns nil`() throws {
        let env = try Self.makeEnvironment()
        defer { try? FileManager.default.removeItem(at: env.root) }

        #expect(try OpenCodeLocalHistoryStore(
            databaseURL: env.databaseURL,
            cacheURL: env.cacheURL)
            .loadDailyReport(since: Date.distantPast, until: Date(), calendar: .current) == nil)

        try Self.createDatabase(at: env.databaseURL)
        try Self.insertMessage(
            databaseURL: env.databaseURL, createdMs: 1_772_798_400_000, cost: 9,
            model: "glm-5.3-max", providerID: "nchc")

        #expect(try OpenCodeLocalHistoryStore(
            databaseURL: env.databaseURL,
            cacheURL: env.cacheURL)
            .loadDailyReport(since: Date.distantPast, until: Date(), calendar: .current) == nil)
    }

    @Test
    func `idle wal database without sidecars is still read`() throws {
        let env = try Self.makeEnvironment()
        defer { try? FileManager.default.removeItem(at: env.root) }
        try Self.createDatabase(at: env.databaseURL)
        let now = Date(timeIntervalSince1970: 1_772_798_400)
        try Self.insertMessage(
            databaseURL: env.databaseURL, createdMs: Self.ms(now), cost: 4,
            model: "gpt-5.1-codex", providerID: "openai")
        try Self.configureIdleWAL(at: env.databaseURL)

        let loaded = try OpenCodeLocalHistoryStore(
            databaseURL: env.databaseURL,
            cacheURL: env.cacheURL)
            .loadDailyReport(since: now.addingTimeInterval(-3600), until: now, calendar: .current)
        let result = try #require(loaded)
        let entry = try #require(result.data.first)
        #expect(entry.costUSD == 4)
    }

    @Test
    func `active wal frames are read`() throws {
        let env = try Self.makeEnvironment()
        defer { try? FileManager.default.removeItem(at: env.root) }
        try Self.createDatabase(at: env.databaseURL)
        let now = Date(timeIntervalSince1970: 1_772_798_400)

        var writer = try Self.OpenWriter(url: env.databaseURL)
        defer { writer.close() }
        try writer.exec("PRAGMA journal_mode = WAL;")
        try writer.insertMessage(createdMs: Self.ms(now), cost: 6, model: "gpt-5.1-codex", providerID: "openai")
        // Keep the write transaction uncommitted... committed but un-checkpointed frames must be visible.
        try writer.exec("PRAGMA wal_checkpoint(PASSIVE);")

        let loaded = try OpenCodeLocalHistoryStore(
            databaseURL: env.databaseURL,
            cacheURL: env.cacheURL)
            .loadDailyReport(since: now.addingTimeInterval(-3600), until: now, calendar: .current)
        let result = try #require(loaded)
        let entry = try #require(result.data.first)
        #expect(entry.costUSD == 6)
        #expect(entry.requestCount == 1)
    }

    @Test
    func `absolute OPENCODE_DB override is honored`() throws {
        let env = try Self.makeEnvironment()
        defer { try? FileManager.default.removeItem(at: env.root) }
        try Self.createDatabase(at: env.databaseURL)
        let now = Date(timeIntervalSince1970: 1_772_798_400)
        try Self.insertMessage(
            databaseURL: env.databaseURL, createdMs: Self.ms(now), cost: 2,
            model: "gpt-5.1-codex", providerID: "openai")

        let store = OpenCodeLocalHistoryStore(
            cacheRoot: env.root.appendingPathComponent("history-cache", isDirectory: true),
            homeDirectory: env.root,
            environment: ["OPENCODE_DB": env.databaseURL.path])
        let loaded = try store.loadDailyReport(
            since: now.addingTimeInterval(-3600), until: now, calendar: .current)
        let result = try #require(loaded)
        #expect(result.data.first?.requestCount == 1)
    }

    @Test
    func `selection follows the upstream single database contract`() {
        let dataDirectory = URL(fileURLWithPath: "/tmp/opencode-data", isDirectory: true)
        // No explicit selection: the release database, regardless of environment channel
        // hints (upstream derives the channel from a build constant, not the environment).
        let plain = OpenCodeLocalHistoryStore.primaryDatabaseURL(
            dataDirectory: dataDirectory,
            environment: ["OPENCODE_UPDATE_CHANNEL": "canary"])
        #expect(plain.lastPathComponent == "opencode.db")

        let disabled = OpenCodeLocalHistoryStore.primaryDatabaseURL(
            dataDirectory: dataDirectory,
            environment: ["OPENCODE_UPDATE_CHANNEL": "canary", "OPENCODE_DISABLE_CHANNEL_DB": "1"])
        #expect(disabled.lastPathComponent == "opencode.db")

        let stable = OpenCodeLocalHistoryStore.primaryDatabaseURL(
            dataDirectory: dataDirectory,
            environment: ["OPENCODE_UPDATE_CHANNEL": "latest"])
        #expect(stable.lastPathComponent == "opencode.db")

        // Explicit selections are never substituted: one database, exactly as requested.
        let relative = OpenCodeLocalHistoryStore.primaryDatabaseURL(
            dataDirectory: dataDirectory,
            environment: ["OPENCODE_DB": "custom.db"])
        #expect(relative.lastPathComponent == "custom.db")

        let absolute = OpenCodeLocalHistoryStore.primaryDatabaseURL(
            dataDirectory: dataDirectory,
            environment: ["OPENCODE_DB": "/elsewhere/open.db"])
        #expect(absolute.path == "/elsewhere/open.db")

        // In-memory history lives off disk; an on-disk reader sees nothing and must not
        // silently substitute the stable database.
        let memory = OpenCodeLocalHistoryStore.primaryDatabaseURL(
            dataDirectory: dataDirectory,
            environment: ["OPENCODE_DB": ":memory:"])
        #expect(memory.lastPathComponent != "opencode.db")
    }

    @Test
    func `an explicit selection is never substituted with the default database`() throws {
        let env = try Self.makeEnvironment()
        defer { try? FileManager.default.removeItem(at: env.root) }
        // The default database holds rows, but the explicitly selected one does not.
        try Self.createDatabase(at: env.databaseURL)
        let now = Date(timeIntervalSince1970: 1_772_798_400)
        try Self.insertMessage(
            databaseURL: env.databaseURL, createdMs: Self.ms(now), cost: 1,
            model: "gpt-5.1-codex", providerID: "openai")
        let selectedDirectory = env.root.appendingPathComponent("selected", isDirectory: true)
        try FileManager.default.createDirectory(at: selectedDirectory, withIntermediateDirectories: true)
        let selectedURL = selectedDirectory.appendingPathComponent("opencode.db", isDirectory: false)
        try Self.createDatabase(at: selectedURL)

        let store = OpenCodeLocalHistoryStore(
            databaseURL: OpenCodeLocalHistoryStore.primaryDatabaseURL(
                dataDirectory: env.databaseURL.deletingLastPathComponent(),
                environment: ["OPENCODE_DB": selectedURL.path]),
            cacheURL: env.cacheURL)
        #expect(try store.loadDailyReport(
            since: now.addingTimeInterval(-3600), until: now, calendar: .current) == nil)
    }

    @Test
    func `earlier today rows survive a clock time lower bound`() throws {
        let env = try Self.makeEnvironment()
        defer { try? FileManager.default.removeItem(at: env.root) }
        try Self.createDatabase(at: env.databaseURL)
        // Pin the calendar so the test is independent of the host time zone: 2026-03-06
        // 15:00 UTC with the row at 10:00 UTC the same day.
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC") ?? .current
        let now = try #require(utc.date(from: DateComponents(
            year: 2026, month: 3, day: 6, hour: 15, minute: 0)))
        let morning = try #require(utc.date(from: DateComponents(
            year: 2026, month: 3, day: 6, hour: 10, minute: 0)))
        try Self.insertMessage(
            databaseURL: env.databaseURL, createdMs: Self.ms(morning), cost: 1,
            model: "gpt-5.1-codex", providerID: "openai")

        // A `now`-anchored one-hour window must still include the morning row once the
        // lower bound is normalized to the reporting day's start.
        let loaded = try OpenCodeLocalHistoryStore(
            databaseURL: env.databaseURL,
            cacheURL: env.cacheURL)
            .loadDailyReport(since: now.addingTimeInterval(-3600), until: now, calendar: utc)
        let result = try #require(loaded)
        #expect(result.data.first?.requestCount == 1)
    }

    @Test
    func `day keys follow the supplied reporting calendar`() throws {
        let env = try Self.makeEnvironment()
        defer { try? FileManager.default.removeItem(at: env.root) }
        try Self.createDatabase(at: env.databaseURL)
        var utcCalendar = Calendar(identifier: .gregorian)
        utcCalendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        // 2026-10-16 00:30 UTC: a local-time calendar would file this under October 15.
        let boundary = try #require(utcCalendar.date(
            from: DateComponents(year: 2026, month: 10, day: 16, hour: 0, minute: 30)))
        try Self.insertMessage(
            databaseURL: env.databaseURL, createdMs: Self.ms(boundary), cost: 1,
            model: "gpt-5.1-codex", providerID: "openai")

        let loaded = try OpenCodeLocalHistoryStore(
            databaseURL: env.databaseURL,
            cacheURL: env.cacheURL)
            .loadDailyReport(since: boundary.addingTimeInterval(-3600), until: boundary.addingTimeInterval(3600), calendar: utcCalendar)
        let result = try #require(loaded)
        #expect(result.data.first?.date == "2026-10-16")
    }

    @Test
    func `xdg data home relocates the database discovery`() throws {
        let env = try Self.makeEnvironment()
        defer { try? FileManager.default.removeItem(at: env.root) }
        let xdgRoot = env.root.appendingPathComponent("xdg-data", isDirectory: true)
        let xdgDirectory = xdgRoot.appendingPathComponent("opencode", isDirectory: true)
        try FileManager.default.createDirectory(at: xdgDirectory, withIntermediateDirectories: true)
        let databaseURL = xdgDirectory.appendingPathComponent("opencode.db", isDirectory: false)
        try Self.createDatabase(at: databaseURL)
        let now = Date(timeIntervalSince1970: 1_772_798_400)
        try Self.insertMessage(
            databaseURL: databaseURL, createdMs: Self.ms(now), cost: 1,
            model: "gpt-5.1-codex", providerID: "openai")

        let store = OpenCodeLocalHistoryStore(
            cacheRoot: env.root.appendingPathComponent("history-cache", isDirectory: true),
            homeDirectory: env.root,
            environment: ["XDG_DATA_HOME": xdgRoot.path])
        let loaded = try store.loadDailyReport(
            since: now.addingTimeInterval(-3600), until: now, calendar: .current)
        let result = try #require(loaded)
        #expect(result.data.first?.requestCount == 1)

        // A relative XDG_DATA_HOME is ignored per the XDG spec; discovery falls back to
        // ~/.local/share/opencode, which holds no database in this environment.
        let relativeStore = OpenCodeLocalHistoryStore(
            cacheRoot: env.root.appendingPathComponent("history-cache-2", isDirectory: true),
            homeDirectory: env.root,
            environment: ["XDG_DATA_HOME": "relative/path"])
        #expect(try relativeStore.loadDailyReport(
            since: now.addingTimeInterval(-3600), until: now, calendar: .current) == nil)
    }

    // MARK: - v2 shared-store cache behavior

    @Test
    func `cached publication reads the durable cache without the database`() throws {
        let env = try Self.makeEnvironment()
        defer { try? FileManager.default.removeItem(at: env.root) }
        try Self.createDatabase(at: env.databaseURL)
        let now = Date(timeIntervalSince1970: 1_772_798_400)
        try Self.insertMessage(
            databaseURL: env.databaseURL, createdMs: Self.ms(now), cost: 1.5,
            model: "gpt-5.1-codex", providerID: "openai")

        let store = OpenCodeLocalHistoryStore(databaseURL: env.databaseURL, cacheURL: env.cacheURL)
        let firstLoaded = try store.loadDailyReport(
            since: now.addingTimeInterval(-3600), until: now, calendar: .current)
        let first = try #require(firstLoaded)

        // The database disappears (uninstalled, or a scan merely persists first): a cached
        // publication still serves the persisted entries — it never opens the database.
        try FileManager.default.removeItem(at: env.databaseURL)
        let cached = store.cachedDailyReport(
            since: now.addingTimeInterval(-3600), until: now, calendar: .current)
        #expect(cached?.data.map(\.date) == first.data.map(\.date))
        #expect(cached?.data.first?.costUSD == 1.5)

        // The scan path sees the missing database and clears the cache instead of serving
        // rows from an installation that is gone.
        #expect(try store.loadDailyReport(
            since: now.addingTimeInterval(-3600), until: now, calendar: .current) == nil)
        #expect(store.cachedDailyReport(
            since: now.addingTimeInterval(-3600), until: now, calendar: .current) == nil)
    }

    @Test
    func `a changed database fingerprint forces one re-read`() throws {
        let env = try Self.makeEnvironment()
        defer { try? FileManager.default.removeItem(at: env.root) }
        try Self.createDatabase(at: env.databaseURL)
        let now = Date(timeIntervalSince1970: 1_772_798_400)
        try Self.insertMessage(
            databaseURL: env.databaseURL, createdMs: Self.ms(now), cost: 1,
            model: "gpt-5.1-codex", providerID: "openai")

        let store = OpenCodeLocalHistoryStore(databaseURL: env.databaseURL, cacheURL: env.cacheURL)
        let firstLoaded = try store.loadDailyReport(
            since: now.addingTimeInterval(-3600), until: now, calendar: .current)
        let first = try #require(firstLoaded)
        #expect(first.data.first?.requestCount == 1)

        // A new row changes the fingerprint; the next scan re-reads and sees it.
        try Self.insertMessage(
            databaseURL: env.databaseURL, createdMs: Self.ms(now), cost: 2,
            model: "gpt-5.1-codex", providerID: "openai")
        let secondLoaded = try store.loadDailyReport(
            since: now.addingTimeInterval(-3600), until: now, calendar: .current)
        let second = try #require(secondLoaded)
        #expect(second.data.first?.requestCount == 2)
        #expect(second.data.first?.costUSD == 3)
    }

    @Test
    func `removing the cache empties cached publications`() throws {
        let env = try Self.makeEnvironment()
        defer { try? FileManager.default.removeItem(at: env.root) }
        try Self.createDatabase(at: env.databaseURL)
        let now = Date(timeIntervalSince1970: 1_772_798_400)
        try Self.insertMessage(
            databaseURL: env.databaseURL, createdMs: Self.ms(now), cost: 1,
            model: "gpt-5.1-codex", providerID: "openai")

        let store = OpenCodeLocalHistoryStore(databaseURL: env.databaseURL, cacheURL: env.cacheURL)
        _ = try store.loadDailyReport(
            since: now.addingTimeInterval(-3600), until: now, calendar: .current)
        #expect(store.cachedDailyReport(
            since: now.addingTimeInterval(-3600), until: now, calendar: .current) != nil)

        try store.removeAllCachedEntries()
        #expect(store.cachedDailyReport(
            since: now.addingTimeInterval(-3600), until: now, calendar: .current) == nil)
    }
}

extension OpenCodeLocalHistoryStoreTests {
    private struct Environment {
        let root: URL
        let databaseURL: URL
        let cacheURL: URL
    }

    private static func makeEnvironment() throws -> Environment {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenCodeLocalHistoryStoreTests-\(UUID().uuidString)", isDirectory: true)
        let directory = root
            .appendingPathComponent(".local", isDirectory: true)
            .appendingPathComponent("share", isDirectory: true)
            .appendingPathComponent("opencode", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let cacheURL = root.appendingPathComponent("history-cache", isDirectory: true)
            .appendingPathComponent("opencode-local-history-v1.sqlite", isDirectory: false)
        return Environment(
            root: root,
            databaseURL: directory.appendingPathComponent("opencode.db", isDirectory: false),
            cacheURL: cacheURL)
    }

    private static func createDatabase(
        at url: URL,
        includeParts: Bool = true,
        includeSessionMessages: Bool = false) throws
    {
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK else { throw SQLiteTestError.open }
        defer { sqlite3_close(db) }
        try Self.exec(
            db: db,
            sql: """
                CREATE TABLE message (
                  id TEXT PRIMARY KEY,
                  session_id TEXT NOT NULL,
                  data TEXT NOT NULL,
                  time_created INTEGER,
                  time_updated INTEGER
                );
                CREATE TABLE part (
                  id TEXT PRIMARY KEY,
                  message_id TEXT NOT NULL,
                  session_id TEXT NOT NULL,
                  data TEXT NOT NULL,
                  time_created INTEGER,
                  time_updated INTEGER
                );
            """)
        if !includeParts {
            try Self.exec(db: db, sql: "DROP TABLE part")
        }
        if includeSessionMessages {
            try Self.exec(
                db: db,
                sql: """
                    CREATE TABLE session_message (
                      id TEXT PRIMARY KEY,
                      session_id TEXT NOT NULL,
                      type TEXT NOT NULL,
                      seq INTEGER NOT NULL,
                      time_created INTEGER NOT NULL,
                      time_updated INTEGER NOT NULL,
                      data TEXT NOT NULL
                    );
                """)
        }
    }

    private static func createV2OnlyDatabase(at url: URL) throws {
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK else { throw SQLiteTestError.open }
        defer { sqlite3_close(db) }
        try Self.exec(
            db: db,
            sql: """
                CREATE TABLE session_message (
                  id TEXT PRIMARY KEY,
                  session_id TEXT NOT NULL,
                  type TEXT NOT NULL,
                  seq INTEGER NOT NULL,
                  time_created INTEGER NOT NULL,
                  time_updated INTEGER NOT NULL,
                  data TEXT NOT NULL
                );
            """)
    }

    private static func configureIdleWAL(at url: URL) throws {
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK else { throw SQLiteTestError.open }
        do {
            try Self.exec(db: db, sql: "PRAGMA journal_mode = WAL; PRAGMA wal_checkpoint(TRUNCATE);")
        } catch {
            sqlite3_close(db)
            throw error
        }
        guard sqlite3_close(db) == SQLITE_OK else { throw SQLiteTestError.close }

        for suffix in ["-wal", "-shm"] {
            let sidecarURL = URL(fileURLWithPath: url.path + suffix)
            if FileManager.default.fileExists(atPath: sidecarURL.path) {
                try FileManager.default.removeItem(at: sidecarURL)
            }
        }
    }

    @discardableResult
    private static func insertMessage(
        databaseURL: URL,
        createdMs: Int64,
        cost: Double?,
        model: String? = nil,
        providerID: String = "openai",
        tokens: Any? = nil) throws -> String
    {
        let messageID = UUID().uuidString
        var payload: [String: Any] = [
            "providerID": providerID,
            "role": "assistant",
            "time": ["created": createdMs],
        ]
        if let cost {
            payload["cost"] = cost
        }
        if let model {
            payload["modelID"] = model
        }
        if let tokens {
            payload["tokens"] = tokens
        }
        try Self.insertRawMessage(databaseURL: databaseURL, id: messageID, createdMs: createdMs, json: Self.json(payload))
        return messageID
    }

    private static func insertRawMessage(
        databaseURL: URL,
        id: String = UUID().uuidString,
        createdMs: Int64 = 0,
        json: String) throws
    {
        var db: OpaquePointer?
        guard sqlite3_open(databaseURL.path, &db) == SQLITE_OK else { throw SQLiteTestError.open }
        defer { sqlite3_close(db) }

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(
            db,
            "INSERT INTO message (id, session_id, data, time_created, time_updated) VALUES (?, ?, ?, ?, ?)",
            -1,
            &stmt,
            nil) == SQLITE_OK
        else { throw SQLiteTestError.prepare }
        defer { sqlite3_finalize(stmt) }

        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(stmt, 1, id, -1, transient)
        sqlite3_bind_text(stmt, 2, "session-1", -1, transient)
        sqlite3_bind_text(stmt, 3, json, -1, transient)
        sqlite3_bind_int64(stmt, 4, createdMs)
        sqlite3_bind_int64(stmt, 5, createdMs)
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw SQLiteTestError.step }
    }

    private static func insertStepFinishPart(
        databaseURL: URL,
        messageID: String,
        createdMs: Int64,
        cost: Double,
        tokens: [String: Any] = ["input": 1, "output": 1, "total": 2]) throws
    {
        var db: OpaquePointer?
        guard sqlite3_open(databaseURL.path, &db) == SQLITE_OK else { throw SQLiteTestError.open }
        defer { sqlite3_close(db) }

        let payload: [String: Any] = [
            "type": "step-finish",
            "cost": cost,
            "tokens": tokens,
        ]

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(
            db,
            "INSERT INTO part (id, message_id, session_id, data, time_created, time_updated) VALUES (?, ?, ?, ?, ?, ?)",
            -1,
            &stmt,
            nil) == SQLITE_OK
        else { throw SQLiteTestError.prepare }
        defer { sqlite3_finalize(stmt) }

        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(stmt, 1, UUID().uuidString, -1, transient)
        sqlite3_bind_text(stmt, 2, messageID, -1, transient)
        sqlite3_bind_text(stmt, 3, "session-1", -1, transient)
        sqlite3_bind_text(stmt, 4, Self.json(payload), -1, transient)
        sqlite3_bind_int64(stmt, 5, createdMs)
        sqlite3_bind_int64(stmt, 6, createdMs)
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw SQLiteTestError.step }
    }

    private static func insertSessionMessage(
        databaseURL: URL,
        id: String = UUID().uuidString,
        createdMs: Int64,
        cost: Double,
        model: String,
        providerID: String = "openai",
        tokens: [String: Any]? = nil) throws
    {
        var db: OpaquePointer?
        guard sqlite3_open(databaseURL.path, &db) == SQLITE_OK else { throw SQLiteTestError.open }
        defer { sqlite3_close(db) }

        var payload: [String: Any] = [
            "model": ["providerID": providerID, "id": model],
            "cost": cost,
            "time": ["created": createdMs],
        ]
        if let tokens {
            payload["tokens"] = tokens
        }

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(
            db,
            """
            INSERT INTO session_message (id, session_id, type, seq, time_created, time_updated, data)
            VALUES (?, ?, 'assistant', 0, ?, ?, ?)
            """,
            -1,
            &stmt,
            nil) == SQLITE_OK
        else { throw SQLiteTestError.prepare }
        defer { sqlite3_finalize(stmt) }

        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(stmt, 1, id, -1, transient)
        sqlite3_bind_text(stmt, 2, "session-1", -1, transient)
        sqlite3_bind_int64(stmt, 3, createdMs)
        sqlite3_bind_int64(stmt, 4, createdMs)
        sqlite3_bind_text(stmt, 5, Self.json(payload), -1, transient)
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw SQLiteTestError.step }
    }

    private static func json(_ payload: [String: Any]) -> String {
        let data = try? JSONSerialization.data(withJSONObject: payload)
        return String(data: data ?? Data(), encoding: .utf8) ?? "{}"
    }

    private static func exec(db: OpaquePointer?, sql: String) throws {
        var message: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &message) == SQLITE_OK else {
            sqlite3_free(message)
            throw SQLiteTestError.exec
        }
    }

    private static func ms(_ date: Date) -> Int64 {
        Int64(date.timeIntervalSince1970 * 1000)
    }

    private enum SQLiteTestError: Error {
        case close
        case open
        case prepare
        case step
        case exec
    }

    /// A database connection that stays open across WAL writes, exercising the reader's
    /// normal (non-immutable) open path against a live WAL.
    private struct OpenWriter {
        private var db: OpaquePointer?

        init(url: URL) throws {
            guard sqlite3_open(url.path, &self.db) == SQLITE_OK else { throw SQLiteTestError.open }
        }

        func exec(_ sql: String) throws {
            try OpenCodeLocalHistoryStoreTests.exec(db: self.db, sql: sql)
        }

        func insertMessage(createdMs: Int64, cost: Double, model: String, providerID: String) throws {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(
                self.db,
                "INSERT INTO message (id, session_id, data, time_created, time_updated) VALUES (?, ?, ?, ?, ?)",
                -1,
                &stmt,
                nil) == SQLITE_OK
            else { throw SQLiteTestError.prepare }
            defer { sqlite3_finalize(stmt) }

            let payload: [String: Any] = [
                "providerID": providerID,
                "role": "assistant",
                "modelID": model,
                "cost": cost,
                "time": ["created": createdMs],
            ]
            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            sqlite3_bind_text(stmt, 1, UUID().uuidString, -1, transient)
            sqlite3_bind_text(stmt, 2, "session-1", -1, transient)
            sqlite3_bind_text(stmt, 3, OpenCodeLocalHistoryStoreTests.json(payload), -1, transient)
            sqlite3_bind_int64(stmt, 4, createdMs)
            sqlite3_bind_int64(stmt, 5, createdMs)
            guard sqlite3_step(stmt) == SQLITE_DONE else { throw SQLiteTestError.step }
        }

        mutating func close() {
            if let db {
                sqlite3_close(db)
            }
            self.db = nil
        }
    }
}

#endif
