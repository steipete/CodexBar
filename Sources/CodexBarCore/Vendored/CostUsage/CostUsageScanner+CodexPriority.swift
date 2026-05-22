import Foundation
#if canImport(SQLite3)
import SQLite3
#endif

extension CostUsageScanner {
    struct CodexPriorityTurnMetadata: Codable, Equatable {
        var threadID: String?
        var turnID: String
        var model: String?
        var timestamp: String?
    }

    private static let requestMarker = "websocket request:"

    static func defaultCodexPriorityDatabaseURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex", isDirectory: true)
            .appendingPathComponent("logs_2.sqlite", isDirectory: false)
    }

    static func codexPriorityTurns(
        databaseURL: URL? = nil,
        sinceDayKey: String? = nil,
        untilDayKey: String? = nil) -> [String: CodexPriorityTurnMetadata]
    {
        let url = databaseURL ?? self.defaultCodexPriorityDatabaseURL()
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }

        #if canImport(SQLite3)
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return [:]
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 250)

        let query = if sinceDayKey != nil || untilDayKey != nil {
            """
            select ts, feedback_log_body
            from logs
            where ts >= ? and ts < ?
              and (feedback_log_body like '%websocket request:%'
                   or feedback_log_body like '%response.completed%')
            """
        } else {
            """
            select ts, feedback_log_body
            from logs
            where feedback_log_body like '%websocket request:%'
               or feedback_log_body like '%response.completed%'
            """
        }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK else { return [:] }
        defer { sqlite3_finalize(stmt) }

        if sinceDayKey != nil || untilDayKey != nil {
            let start = self.epochSeconds(forDayKey: sinceDayKey ?? "0000-01-01") ?? 0
            let end = self.epochSeconds(forDayKey: self.nextDayKey(after: untilDayKey ?? "9999-12-30"))
                ?? Int64.max
            sqlite3_bind_int64(stmt, 1, start)
            sqlite3_bind_int64(stmt, 2, end)
        }

        var turns: [String: CodexPriorityTurnMetadata] = [:]
        var completedModelsByTurnID: [String: String] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            let timestamp = self.timestamp(stmt: stmt, index: 0)
            guard self.timestamp(timestamp, isInRangeSince: sinceDayKey, until: untilDayKey),
                  let body = self.text(stmt: stmt, index: 1)
            else { continue }
            if let completed = self.parseCodexCompletedTraceRow(body: body) {
                completedModelsByTurnID[completed.turnID] = completed.model
                if var existing = turns[completed.turnID] {
                    existing.model = completed.model
                    turns[completed.turnID] = existing
                }
                continue
            }
            guard var parsed = self.parseCodexPriorityTraceRow(timestamp: timestamp, body: body)
            else { continue }
            if let completedModel = completedModelsByTurnID[parsed.turnID] {
                parsed.model = completedModel
            }
            turns[parsed.turnID] = parsed
        }
        return turns
        #else
        return [:]
        #endif
    }

    static func parseCodexPriorityTraceRow(timestamp: String?, body: String) -> CodexPriorityTurnMetadata? {
        guard let markerRange = body.range(of: self.requestMarker) else { return nil }
        let prefix = String(body[..<markerRange.lowerBound])
        let jsonText = body[markerRange.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = jsonText.data(using: .utf8),
              let request = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              request["type"] as? String == "response.create",
              request["service_tier"] as? String == "priority"
        else { return nil }

        let turnID = self.value(named: "turn.id", in: prefix)
            ?? self.value(named: "turn_id", in: prefix)
            ?? request["turn_id"] as? String
        guard let turnID, !turnID.isEmpty else { return nil }

        return CodexPriorityTurnMetadata(
            threadID: self.value(named: "thread_id", in: prefix),
            turnID: turnID,
            model: request["model"] as? String,
            timestamp: timestamp)
    }

    static func parseCodexCompletedTraceRow(body: String) -> (turnID: String, model: String)? {
        let marker = "websocket event:"
        guard let markerRange = body.range(of: marker) else { return nil }
        let prefix = String(body[..<markerRange.lowerBound])
        let jsonText = body[markerRange.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = jsonText.data(using: .utf8),
              let event = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              event["type"] as? String == "response.completed",
              let response = event["response"] as? [String: Any],
              let model = response["model"] as? String,
              !model.isEmpty
        else { return nil }

        let turnID = self.value(named: "turn.id", in: prefix)
            ?? self.value(named: "turn_id", in: prefix)
        guard let turnID, !turnID.isEmpty else { return nil }

        return (turnID: turnID, model: model)
    }

    private static func value(named name: String, in text: String) -> String? {
        guard let range = text.range(of: "\(name)=") else { return nil }
        let tail = text[range.upperBound...]
        let value = tail.prefix { char in
            !char.isWhitespace && char != "," && char != "]" && char != ")"
        }
        return value.isEmpty ? nil : String(value)
    }

    #if canImport(SQLite3)
    private static func text(stmt: OpaquePointer?, index: Int32) -> String? {
        guard sqlite3_column_type(stmt, index) != SQLITE_NULL,
              let cString = sqlite3_column_text(stmt, index)
        else { return nil }
        return String(cString: cString)
    }

    private static func timestamp(stmt: OpaquePointer?, index: Int32) -> String? {
        guard sqlite3_column_type(stmt, index) != SQLITE_NULL else { return nil }
        if sqlite3_column_type(stmt, index) == SQLITE_INTEGER {
            return String(sqlite3_column_int64(stmt, index))
        }
        return self.text(stmt: stmt, index: index)
    }
    #endif

    private static func timestamp(_ timestamp: String?, isInRangeSince since: String?, until: String?) -> Bool {
        guard since != nil || until != nil else { return true }
        guard let dayKey = self.dayKey(fromTimestamp: timestamp) else { return false }
        if let since, dayKey < since { return false }
        if let until, dayKey > until { return false }
        return true
    }

    private static func dayKey(fromTimestamp timestamp: String?) -> String? {
        guard let timestamp else { return nil }
        if let seconds = Int64(timestamp) {
            return CostUsageScanner.CostUsageDayRange.dayKey(
                from: Date(timeIntervalSince1970: TimeInterval(seconds)))
        }
        let dayKey = timestamp.prefix(10)
        return dayKey.count == 10 ? String(dayKey) : nil
    }

    private static func nextDayKey(after dayKey: String) -> String {
        guard let date = self.localDate(forDayKey: dayKey),
              let next = Calendar.current.date(byAdding: .day, value: 1, to: date)
        else { return dayKey }
        return CostUsageScanner.CostUsageDayRange.dayKey(from: next)
    }

    private static func epochSeconds(forDayKey dayKey: String) -> Int64? {
        guard let date = self.localDate(forDayKey: dayKey) else { return nil }
        return Int64(date.timeIntervalSince1970)
    }

    private static func localDate(forDayKey dayKey: String) -> Date? {
        let parts = dayKey.split(separator: "-")
        guard parts.count == 3,
              let year = Int(parts[0]),
              let month = Int(parts[1]),
              let day = Int(parts[2])
        else { return nil }
        var components = DateComponents()
        components.calendar = Calendar.current
        components.year = year
        components.month = month
        components.day = day
        return components.date
    }
}
