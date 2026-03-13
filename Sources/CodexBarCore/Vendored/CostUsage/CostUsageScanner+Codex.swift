import Foundation

private struct CostUsageScannerCodexRecoveredPrefix: Sendable {
    let type: String
    let timestamp: String?
    let sessionId: String?
    let model: String?
    let totalUsage: CostUsageCodexTotals?
    let lastUsage: CostUsageCodexTotals?
}

private struct CostUsageScannerCodexTokenUsageRecord {
    let explicitModel: String?
    let totalUsage: CostUsageCodexTotals?
    let lastUsage: CostUsageCodexTotals?
}

private struct CostUsageScannerCodexParseState {
    var currentModel: String?
    var previousTotals: CostUsageCodexTotals?
    var sessionId: String?
    var days: [String: [String: [Int]]] = [:]
}

extension CostUsageScanner {
    private static func regexCapture(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range) else { return nil }
        guard let captureRange = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[captureRange])
    }

    private static func extractInt(after anchor: String, in text: String) -> Int? {
        guard let range = text.range(of: anchor) else { return nil }
        var idx = range.upperBound
        var digits = ""
        while idx < text.endIndex, let ascii = text[idx].asciiValue, ascii >= 48, ascii <= 57 {
            digits.append(text[idx])
            idx = text.index(after: idx)
        }
        guard !digits.isEmpty else { return nil }
        return Int(digits)
    }

    private static func recoverCodexTokenUsage(blockName: String, in text: String) -> CostUsageCodexTotals? {
        guard let range = text.range(of: "\"\(blockName)\":{") else { return nil }
        let suffix = text[range.upperBound...]
        guard let end = suffix.firstIndex(of: "}") else { return nil }
        let block = String(suffix[..<end])
        guard
            let input = Self.extractInt(after: "\"input_tokens\":", in: block),
            let output = Self.extractInt(after: "\"output_tokens\":", in: block)
        else { return nil }
        let cached = Self.extractInt(after: "\"cached_input_tokens\":", in: block)
            ?? Self.extractInt(after: "\"cache_read_input_tokens\":", in: block)
            ?? 0
        return CostUsageCodexTotals(input: input, cached: cached, output: output)
    }

    private static func recoverCodexPrefixText(from bytes: Data) -> String? {
        if let text = String(bytes: bytes, encoding: .utf8) {
            return text
        }

        var trimmed = bytes
        while !trimmed.isEmpty {
            trimmed.removeLast()
            if let text = String(bytes: trimmed, encoding: .utf8) {
                return text
            }
        }

        return nil
    }

    private static func recoverCodexPrefix(from bytes: Data) -> CostUsageScannerCodexRecoveredPrefix? {
        guard let text = recoverCodexPrefixText(from: bytes) else { return nil }
        guard let type = Self.regexCapture("^\\{\"type\":\"([^\"]+)\"", in: text) else { return nil }

        let timestamp = Self.regexCapture("\"timestamp\":\"([^\"]+)\"", in: text)

        let sessionIdPatterns = [
            "\"payload\":\\{.*?\"session_id\":\"([^\"]+)\"",
            "\"payload\":\\{.*?\"sessionId\":\"([^\"]+)\"",
            "\"payload\":\\{.*?\"id\":\"([^\"]+)\"",
            "\"session_id\":\"([^\"]+)\"",
            "\"sessionId\":\"([^\"]+)\"",
            "\"id\":\"([^\"]+)\"",
        ]
        let sessionId = sessionIdPatterns.lazy.compactMap { Self.regexCapture($0, in: text) }.first

        let modelPatterns: [String] = switch type {
        case "turn_context":
            [
                "\"payload\":\\{.*?\"model\":\"([^\"]+)\"",
                "\"payload\":\\{.*?\"info\":\\{.*?\"model\":\"([^\"]+)\"",
                "(?:^|,)\"model\":\"([^\"]+)\"",
            ]
        case "event_msg":
            [
                "\"payload\":\\{.*?\"info\":\\{.*?\"model\":\"([^\"]+)\"",
                "\"payload\":\\{.*?\"info\":\\{.*?\"model_name\":\"([^\"]+)\"",
                "\"payload\":\\{.*?\"model\":\"([^\"]+)\"",
                "(?:^|,)\"model\":\"([^\"]+)\"",
            ]
        default:
            ["(?:^|,)\"model\":\"([^\"]+)\""]
        }
        let model = modelPatterns.lazy.compactMap { Self.regexCapture($0, in: text) }.first

        let totalUsage = type == "event_msg" && text.contains("\"token_count\"")
            ? Self.recoverCodexTokenUsage(blockName: "total_token_usage", in: text)
            : nil
        let lastUsage = type == "event_msg" && text.contains("\"token_count\"")
            ? Self.recoverCodexTokenUsage(blockName: "last_token_usage", in: text)
            : nil

        return CostUsageScannerCodexRecoveredPrefix(
            type: type,
            timestamp: timestamp,
            sessionId: sessionId,
            model: model,
            totalUsage: totalUsage,
            lastUsage: lastUsage)
    }

    private static func shouldInspectCodexLine(_ line: CostUsageJsonl.Line) -> Bool {
        if line.bytes.isEmpty { return false }
        let hasRelevantType = line.bytes.containsAscii(#""type":"event_msg""#)
            || line.bytes.containsAscii(#""type":"turn_context""#)
            || line.bytes.containsAscii(#""type":"session_meta""#)
        guard hasRelevantType else { return false }
        if line.bytes.containsAscii(#""type":"event_msg""#), !line.bytes.containsAscii(#""token_count""#) {
            return false
        }
        return true
    }

    private static func addCodexUsage(
        dayKey: String,
        model: String,
        usage: CostUsageCodexTotals,
        range: CostUsageDayRange,
        state: inout CostUsageScannerCodexParseState)
    {
        guard CostUsageDayRange.isInRange(dayKey: dayKey, since: range.scanSinceKey, until: range.scanUntilKey)
        else { return }
        let normModel = CostUsagePricing.normalizeCodexModel(model)

        var dayModels = state.days[dayKey] ?? [:]
        var packed = dayModels[normModel] ?? [0, 0, 0]
        packed[0] = (packed[safe: 0] ?? 0) + usage.input
        packed[1] = (packed[safe: 1] ?? 0) + usage.cached
        packed[2] = (packed[safe: 2] ?? 0) + usage.output
        dayModels[normModel] = packed
        state.days[dayKey] = dayModels
    }

    private static func recordCodexTokenUsage(
        dayKey: String,
        usage: CostUsageScannerCodexTokenUsageRecord,
        range: CostUsageDayRange,
        state: inout CostUsageScannerCodexParseState)
    {
        if let explicitModel = usage.explicitModel {
            state.currentModel = explicitModel
        }

        let model = usage.explicitModel ?? state.currentModel ?? "gpt-5"
        var deltaInput = 0
        var deltaCached = 0
        var deltaOutput = 0

        if let totalUsage = usage.totalUsage {
            let prev = state.previousTotals
            deltaInput = max(0, totalUsage.input - (prev?.input ?? 0))
            deltaCached = max(0, totalUsage.cached - (prev?.cached ?? 0))
            deltaOutput = max(0, totalUsage.output - (prev?.output ?? 0))
            state.previousTotals = totalUsage
        } else if let lastUsage = usage.lastUsage {
            deltaInput = max(0, lastUsage.input)
            deltaCached = max(0, lastUsage.cached)
            deltaOutput = max(0, lastUsage.output)
        } else {
            return
        }

        if deltaInput == 0, deltaCached == 0, deltaOutput == 0 { return }
        let deltaUsage = CostUsageCodexTotals(
            input: deltaInput,
            cached: min(deltaCached, deltaInput),
            output: deltaOutput)
        Self.addCodexUsage(
            dayKey: dayKey,
            model: model,
            usage: deltaUsage,
            range: range,
            state: &state)
    }

    private static func parseCodexTruncatedLine(
        _ line: CostUsageJsonl.Line,
        range: CostUsageDayRange,
        state: inout CostUsageScannerCodexParseState)
    {
        guard let recovered = recoverCodexPrefix(from: line.bytes) else { return }

        if recovered.type == "session_meta" {
            if state.sessionId == nil {
                state.sessionId = recovered.sessionId
            }
            return
        }

        if let model = recovered.model {
            state.currentModel = model
        }

        guard let tsText = recovered.timestamp else { return }
        guard let dayKey = Self.dayKeyFromTimestamp(tsText) ?? Self.dayKeyFromParsedISO(tsText) else { return }

        if recovered.type == "turn_context" {
            return
        }

        guard recovered.type == "event_msg" else { return }
        guard line.bytes.containsAscii(#""token_count""#) else { return }
        Self.recordCodexTokenUsage(
            dayKey: dayKey,
            usage: CostUsageScannerCodexTokenUsageRecord(
                explicitModel: recovered.model,
                totalUsage: recovered.totalUsage,
                lastUsage: recovered.lastUsage),
            range: range,
            state: &state)
    }

    private static func parseCodexFullLine(
        _ line: CostUsageJsonl.Line,
        range: CostUsageDayRange,
        state: inout CostUsageScannerCodexParseState)
    {
        guard
            let obj = (try? JSONSerialization.jsonObject(with: line.bytes)) as? [String: Any],
            let type = obj["type"] as? String
        else { return }

        if type == "session_meta" {
            if state.sessionId == nil {
                let payload = obj["payload"] as? [String: Any]
                state.sessionId = payload?["session_id"] as? String
                    ?? payload?["sessionId"] as? String
                    ?? payload?["id"] as? String
                    ?? obj["session_id"] as? String
                    ?? obj["sessionId"] as? String
                    ?? obj["id"] as? String
            }
            return
        }

        guard let tsText = obj["timestamp"] as? String else { return }
        guard let dayKey = Self.dayKeyFromTimestamp(tsText) ?? Self.dayKeyFromParsedISO(tsText) else { return }

        if type == "turn_context" {
            if let payload = obj["payload"] as? [String: Any] {
                if let model = payload["model"] as? String {
                    state.currentModel = model
                } else if let info = payload["info"] as? [String: Any], let model = info["model"] as? String {
                    state.currentModel = model
                }
            }
            return
        }

        guard type == "event_msg" else { return }
        guard let payload = obj["payload"] as? [String: Any] else { return }
        guard (payload["type"] as? String) == "token_count" else { return }

        let info = payload["info"] as? [String: Any]
        let modelFromInfo = info?["model"] as? String
            ?? info?["model_name"] as? String
            ?? payload["model"] as? String
            ?? obj["model"] as? String

        func toInt(_ value: Any?) -> Int {
            if let number = value as? NSNumber { return number.intValue }
            return 0
        }

        let totalUsage = (info?["total_token_usage"] as? [String: Any]).map {
            CostUsageCodexTotals(
                input: toInt($0["input_tokens"]),
                cached: toInt($0["cached_input_tokens"] ?? $0["cache_read_input_tokens"]),
                output: toInt($0["output_tokens"]))
        }
        let lastUsage = (info?["last_token_usage"] as? [String: Any]).map {
            CostUsageCodexTotals(
                input: toInt($0["input_tokens"]),
                cached: toInt($0["cached_input_tokens"] ?? $0["cache_read_input_tokens"]),
                output: toInt($0["output_tokens"]))
        }

        Self.recordCodexTokenUsage(
            dayKey: dayKey,
            usage: CostUsageScannerCodexTokenUsageRecord(
                explicitModel: modelFromInfo,
                totalUsage: totalUsage,
                lastUsage: lastUsage),
            range: range,
            state: &state)
    }

    private static func parseCodexLine(
        _ line: CostUsageJsonl.Line,
        range: CostUsageDayRange,
        state: inout CostUsageScannerCodexParseState)
    {
        guard self.shouldInspectCodexLine(line) else { return }
        if line.wasTruncated {
            self.parseCodexTruncatedLine(line, range: range, state: &state)
        } else {
            self.parseCodexFullLine(line, range: range, state: &state)
        }
    }

    static func parseCodexFile(
        fileURL: URL,
        range: CostUsageDayRange,
        startOffset: Int64 = 0,
        initialModel: String? = nil,
        initialTotals: CostUsageCodexTotals? = nil) -> CodexParseResult
    {
        var state = CostUsageScannerCodexParseState(
            currentModel: initialModel,
            previousTotals: initialTotals,
            sessionId: nil,
            days: [:])

        let maxLineBytes = 256 * 1024
        let prefixBytes = 32 * 1024

        let parsedBytes = (try? CostUsageJsonl.scan(
            fileURL: fileURL,
            offset: startOffset,
            maxLineBytes: maxLineBytes,
            prefixBytes: prefixBytes,
            onLine: { line in
                Self.parseCodexLine(line, range: range, state: &state)
            })) ?? startOffset

        return CodexParseResult(
            days: state.days,
            parsedBytes: parsedBytes,
            lastModel: state.currentModel,
            lastTotals: state.previousTotals,
            sessionId: state.sessionId)
    }
}
