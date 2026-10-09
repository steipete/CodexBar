import CoreFoundation
import Foundation

enum SessionToolActivityParser {
    static func isUnindexedNativeOperation(_ root: [String: Any], source: SessionToolActivitySource) -> Bool {
        guard root["type"] as? String == "event_msg", let payload = root["payload"] as? [String: Any],
              payload["type"] as? String == "item_completed", let item = payload["item"] as? [String: Any],
              let type = item["type"] as? String, self.kind(type) != nil else { return false }
        let owner = payload["thread_id"] as? String
        return owner == nil || owner == source.sessionID
    }

    static func operation(
        from root: [String: Any],
        source: SessionToolActivitySource,
        offset: UInt64,
        length: Int) -> SessionToolOperation?
    {
        guard root["type"] as? String == "event_msg",
              let payload = root["payload"] as? [String: Any],
              payload["type"] as? String == "item_completed",
              payload["thread_id"] as? String == source.sessionID,
              source.sessionID.utf8.count <= 256,
              let turn = payload["turn_id"] as? String, !turn.isEmpty, turn.utf8.count <= 256,
              let item = payload["item"] as? [String: Any],
              let id = item["id"] as? String, !id.isEmpty, id.utf8.count <= 256,
              let type = item["type"] as? String,
              let kind = self.kind(type),
              let timestamp = root["timestamp"] as? String,
              let completedAt = CostUsageScanner.dateFromTimestamp(timestamp) else { return nil }
        let nativeDuration = self.duration(item["duration"])
        let interval = self.interval(payload)
        let duration = nativeDuration ?? interval
        let command = (item["command"] as? [String])?.joined(separator: " ")
        let name: String = switch kind {
        case .mcp:
            [item["server"] as? String, item["tool"] as? String].compactMap(\.self)
                .joined(separator: "/")
        case .dynamic:
            [item["namespace"] as? String, item["tool"] as? String].compactMap(\.self)
                .joined(separator: "/")
        case .extensionItem:
            item["kind"] as? String ?? type
        default:
            type
        }
        return SessionToolOperation(
            id: .init(threadID: source.sessionID, turnID: turn, itemID: id),
            kind: kind,
            name: SessionToolTextPreview.prefix(name.isEmpty ? type : name, characters: 256, bytes: 1024),
            preview: command.map { SessionToolTextPreview.prefix($0, characters: 160, bytes: 640) },
            completedAt: completedAt,
            outcome: self.outcome(item, kind: kind),
            exitCode: self.integer(item["exit_code"]),
            durationMilliseconds: duration,
            timing: nativeDuration != nil ? .native : (interval != nil ? .recordedInterval : nil),
            recordOffset: offset,
            recordLength: length)
    }

    private static func kind(_ type: String) -> SessionToolOperation.Kind? {
        switch type {
        case "CommandExecution": .command
        case "McpToolCall": .mcp
        case "DynamicToolCall": .dynamic
        case "FileChange": .fileChange
        case "WebSearch": .webSearch
        case "ImageView", "ImageGeneration": .image
        case "Extension": .extensionItem
        default: nil
        }
    }

    private static func outcome(_ item: [String: Any], kind: SessionToolOperation.Kind)
        -> SessionToolOperation.Outcome
    {
        let status = item["status"] as? String
        if status == "declined" { return .declined }
        if kind == .command, let exit = self.integer(item["exit_code"]),
           exit != 0 { return .nonzeroExit }
        if kind == .mcp || kind == .dynamic {
            let result = item["result"] as? [String: Any]
            if status == "failed" || self.boolean(result?["isError"]) == true
                || self.boolean(item["success"]) == false ||
                (item["error"] != nil && !(item["error"] is NSNull))
            { return .toolError }
        }
        if status == "failed" { return .toolError }
        if status == "completed" || (kind == .command && self.integer(item["exit_code"]) == 0)
            || (kind == .dynamic && self.boolean(item["success"]) == true)
        { return .completed }
        return .unknown
    }

    static func integer(_ raw: Any?) -> Int? {
        guard let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite,
              number.doubleValue.rounded(.towardZero) == number.doubleValue,
              let value = Int(number.stringValue) else { return nil }
        return value
    }

    private static func boolean(_ raw: Any?) -> Bool? {
        guard let number = raw as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }

    static func duration(_ raw: Any?) -> Double? {
        guard let value = raw as? [String: Any], let seconds = self.integer(value["secs"]),
              seconds >= 0,
              let nanos = self.integer(value["nanos"]),
              (0..<1_000_000_000).contains(nanos) else { return nil }
        let base = seconds.multipliedReportingOverflow(by: 1000)
        guard !base.overflow else { return nil }
        let millis = Double(base.partialValue) + Double(nanos) / 1_000_000
        return millis.isFinite ? millis : nil
    }

    static func interval(_ payload: [String: Any]) -> Double? {
        guard let start = self.integer(payload["started_at_ms"]), start > 0,
              let end = self.integer(payload["completed_at_ms"]), end >= start else { return nil }
        return Double(end) - Double(start)
    }
}
