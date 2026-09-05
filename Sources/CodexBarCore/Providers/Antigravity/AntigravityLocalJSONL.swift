import Foundation

extension AntigravityLocalReader {
    private struct JSONLSession {
        var id: String?
        var model: String?
        var line: Int64 = 0
    }

    static func readJSONL(_ paths: [URL], budget: Budget) throws -> SourceResult {
        var result = SourceResult()
        for url in paths {
            try budget.check()
            budget.statistics.files += 1
            guard budget.statistics.files <= budget.limits.databases else { throw ScanFailure.exhausted }
            let source = try self.readJSONLFile(url, budget: budget)
            result.events.append(contentsOf: source.events)
            result.isComplete = result.isComplete && source.isComplete
        }
        return result
    }

    private static func readJSONLFile(_ url: URL, budget: Budget) throws -> SourceResult {
        let values: URLResourceValues
        do {
            values = try url.resolvingSymlinksInPath().resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        } catch {
            return SourceResult(isComplete: false)
        }
        guard values.isRegularFile == true, let size = values.fileSize else {
            return SourceResult(isComplete: false)
        }
        // Check the known size before allocation; streaming also handles a file that grows after this check.
        if size > budget.limits.databaseBytes || size > budget.limits.bytes - budget.statistics.attemptedBytes {
            try budget.chargeBytes(size)
            throw ScanFailure.exhausted
        }
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            return SourceResult(isComplete: false)
        }
        defer { try? handle.close() }
        var result = SourceResult()
        var session = JSONLSession()
        var line: [UInt8] = []
        var fileBytes = 0
        while true {
            try budget.check()
            let remaining = min(
                budget.limits.databaseBytes - fileBytes,
                budget.limits.bytes - budget.statistics.attemptedBytes)
            let chunk: Data
            do {
                chunk = try handle.read(upToCount: min(65536, remaining + 1)) ?? Data()
            } catch {
                result.isComplete = false
                break
            }
            if chunk.isEmpty { break }
            try budget.chargeBytes(chunk.count)
            fileBytes += chunk.count
            guard fileBytes <= budget.limits.databaseBytes else { throw ScanFailure.exhausted }
            for (index, byte) in chunk.enumerated() {
                if index % 4096 == 0 { try budget.check() }
                if byte == 10 {
                    try self.consumeJSONLLine(line, session: &session, result: &result, budget: budget)
                    line.removeAll(keepingCapacity: true)
                } else {
                    guard line.count < budget.limits.blobBytes else { throw ScanFailure.exhausted }
                    line.append(byte)
                }
            }
        }
        if !line.isEmpty {
            try self.consumeJSONLLine(line, session: &session, result: &result, budget: budget)
        }
        if session.id == nil { result.isComplete = false }
        return result
    }

    private static func consumeJSONLLine(
        _ line: [UInt8],
        session: inout JSONLSession,
        result: inout SourceResult,
        budget: Budget) throws
    {
        try budget.chargeRow()
        session.line += 1
        guard session.line <= budget.limits.rowsPerDatabase else { throw ScanFailure.exhausted }
        if line.allSatisfy({ $0 == 13 || $0 == 32 || $0 == 9 }) { return }
        guard let json = try AntigravityJSONLObject.decode(line, checkCancellation: budget.check) else {
            result.isComplete = false
            return
        }
        do {
            guard let type = json["type"] as? String else { throw ScanFailure.invalid }
            if type == "session_meta" {
                let id = try self.optionalString(json, keys: ["sessionId"])
                guard let id, session.id == nil || session.id == id else { throw ScanFailure.invalid }
                session.id = id
                session.model = try self.optionalString(json, keys: ["modelId", "model_id"])
                return
            }
            guard type == "usage" else { throw ScanFailure.invalid }
            let id = try self.optionalString(json, keys: ["sessionId"]) ?? session.id
            guard let id, session.id == nil || session.id == id,
                  let timestamp = try self.optionalTimestamp(json["timestamp"]) else { throw ScanFailure.invalid }
            var usage = AntigravityProtoReader.ParsedUsage()
            usage.newInput = try self.jsonCounter(json, keys: ["input"], required: true)
            usage.output = try self.jsonCounter(json, keys: ["output"], required: true)
            usage.cacheRead = try self.jsonCounter(json, keys: ["cacheRead", "cache_read"])
            usage.reasoning = try self.jsonCounter(json, keys: ["reasoning"])
            // The producer names both counters but does not establish their overlap. Do not guess an exact total.
            guard usage.reasoning == 0 else { throw ScanFailure.invalid }
            usage.responseID = try self.optionalString(json, keys: ["responseId", "response_id"])
            let write = try self.jsonCounter(json, keys: ["cacheWrite", "cache_write"])
            let model = try self.optionalString(json, keys: ["modelId", "model_id"]) ?? session.model
            let turn = AntigravityProtoReader.ParsedTurn(usage: usage, timestampMs: timestamp, model: model)
            guard let event = Event(session: id, row: session.line, turn: turn, cacheWrite: write) else {
                throw ScanFailure.invalid
            }
            session.id = id
            result.events.append(event)
        } catch {
            result.isComplete = false
        }
    }

    private static func exactInteger(_ value: Any) throws -> Int {
        guard let integer = (value as? AntigravityJSONLObject.Number)?.integer else {
            throw ScanFailure.invalid
        }
        return integer
    }

    private static func jsonCounter(_ json: [String: Any], keys: [String], required: Bool = false) throws -> Int {
        var counter: Int?
        for key in keys {
            guard let value = json[key] else { continue }
            let integer = try self.exactInteger(value)
            guard integer >= 0, counter == nil || counter == integer else { throw ScanFailure.invalid }
            counter = integer
        }
        guard !required || counter != nil else { throw ScanFailure.invalid }
        return counter ?? 0
    }

    private static func optionalString(_ json: [String: Any], keys: [String]) throws -> String? {
        var text: String?
        for key in keys {
            guard let value = json[key], !(value is NSNull) else { continue }
            guard let value = value as? String else { throw ScanFailure.invalid }
            if value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
            guard text == nil || text == value else { throw ScanFailure.invalid }
            text = value
        }
        return text
    }

    private static func optionalTimestamp(_ value: Any?) throws -> Int64? {
        guard let value, !(value is NSNull) else { return nil }
        let timestamp = try self.exactInteger(value)
        guard timestamp > 0, timestamp <= 253_402_300_799_999 else { throw ScanFailure.invalid }
        return Int64(timestamp)
    }
}
