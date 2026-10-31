import Foundation

/// One decoded line supplies ordinary scalar coercions and strict, lossless request accounting.
struct ClaudeAccountingObservation {
    enum ObjectState { case missing, invalid, present }

    struct Count {
        enum Evidence { case missing, invalid, number(Int?) }
        let evidence: Evidence
        let ordinary: Int

        init(_ raw: Any?, number: LosslessJSONLObject.Number?) {
            self.ordinary = max(0, (raw as? NSNumber)?.intValue ?? 0)
            if raw == nil {
                self.evidence = .missing
            } else if let number {
                self.evidence = .number(number.integer)
            } else {
                self.evidence = .invalid
            }
        }

        func exact(absent: Int? = nil) -> Int? {
            switch self.evidence {
            case .missing: absent
            case let .number(value): value
            case .invalid: nil
            }
        }
    }

    struct UsageEvidence {
        let state: ObjectState
        let cacheState: ObjectState
        let input: Count
        let output: Count
        let read: Count
        let creation: Count
        let oneHour: Count
        let fiveMinute: Count

        init(message: ClaudeJSONObject?, numbers: [[String]: [String: LosslessJSONLObject.Number]]) {
            let usage = message?.dictionary("usage")
            let cache = usage?.dictionary("cache_creation")
            self.state = Self.state(message?["usage"], dictionary: usage)
            let values = numbers[["message", "usage"]] ?? [:]
            let nested = numbers[["message", "usage", "cache_creation"]] ?? [:]
            self.input = Count(usage?["input_tokens"], number: values["input_tokens"])
            self.output = Count(usage?["output_tokens"], number: values["output_tokens"])
            self.read = Count(usage?["cache_read_input_tokens"], number: values["cache_read_input_tokens"])
            self.creation = Count(usage?["cache_creation_input_tokens"], number: values["cache_creation_input_tokens"])
            self.cacheState = Self.state(usage?["cache_creation"], dictionary: cache, null: self.creation.exact() == 0)
            self.oneHour = Count(cache?["ephemeral_1h_input_tokens"], number: nested["ephemeral_1h_input_tokens"])
            self.fiveMinute = Count(cache?["ephemeral_5m_input_tokens"], number: nested["ephemeral_5m_input_tokens"])
        }

        private static func state(_ raw: Any?, dictionary: ClaudeJSONObject?, null: Bool = false) -> ObjectState {
            if raw == nil || null && raw is NSNull { return .missing }
            return dictionary == nil ? .invalid : .present
        }

        var ordinary: CostUsagePricing.ClaudeCostTokens {
            CostUsagePricing.ClaudeCostTokens(
                input: self.input.ordinary,
                cacheRead: self.read.ordinary,
                cacheCreation: self.creation.ordinary,
                cacheCreation1h: min(self.creation.ordinary, self.oneHour.ordinary),
                output: self.output.ordinary)
        }

        var strict: CostUsagePricing.ClaudeCostTokens? {
            guard self.state == .present, let input = self.input.exact(), let output = self.output.exact(),
                  let read = self.read.exact(absent: 0), let creation = self.creation.exact(absent: 0)
            else { return nil }
            var hour = 0
            if self.cacheState != .missing {
                guard self.cacheState == .present, let oneHour = self.oneHour.exact(absent: 0),
                      let fiveMinute = self.fiveMinute.exact(absent: 0),
                      let total = CheckedSum.integers([oneHour, fiveMinute]), total <= creation,
                      total == creation || self.oneHour.exact() == nil || self.fiveMinute.exact() == nil
                else { return nil }
                hour = oneHour
            }
            let result = CostUsagePricing.ClaudeCostTokens(
                input: input, cacheRead: read, cacheCreation: creation, cacheCreation1h: hour, output: output)
            return result.total == nil ? nil : result
        }
    }

    let timestamp: (date: Date, dayKey: String)?
    let identity: (messageID: String?, requestID: String?, sessionID: String?)
    let model: String?
    let isSidechain: Bool
    let usage: UsageEvidence
    let ordinary: CostUsagePricing.ClaudeCostTokens?
    let identified: CostUsagePricing.ClaudeCostTokens?
    let accountingState: ClaudeRequestRecord.AccountingState?
    let preliminary: Bool

    init(object: ClaudeJSONObject, decoded: LosslessJSONLObject.Decoded, calendar: Calendar) {
        let message = object.dictionary("message")
        self.timestamp = (object["timestamp"] as? String).flatMap {
            CostUsageScanner.claudeTimestampAndDayKey($0, calendar: calendar)
        }
        self.identity = CostUsageScanner.claudeUsageIdentity(object, message: message)
        self.model = message?["model"] as? String
        self.isSidechain = (object["isSidechain"] as? Bool) ?? (object["isSidechain"] as? NSNumber)?.boolValue ?? false
        self.usage = UsageEvidence(message: message, numbers: decoded.numbers)
        let ordinary = self.usage.ordinary
        self.ordinary = decoded.ordinaryCompatible && self.usage.state == .present ? ordinary : nil
        self.identified = decoded.hasDuplicateKeys ? nil : self.usage.strict
        let reason = message?["stop_reason"]
        if reason == nil {
            self.accountingState = .terminal
        } else if reason is NSNull {
            self.accountingState = .snapshot
        } else if let text = reason as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            self.accountingState = .terminal
        } else { self.accountingState = nil }
        // Proxies can supply a cache-unaware estimate before authoritative accounting arrives.
        if case (.missing, .missing) = (self.usage.read.evidence, self.usage.creation.evidence) {
            self.preliminary = self.accountingState == .snapshot && ordinary.input > 0 && ordinary.output == 0
        } else { self.preliminary = false }
    }
}

extension CostUsageScanner {
    static func decodeClaudeAccounting(
        _ data: Data,
        providerFilter: ClaudeLogProviderFilter,
        scanMetadata: Bool,
        calendar: Calendar,
        checkCancellation: @escaping () throws -> Void) throws
        -> (observation: ClaudeAccountingObservation?, ordinaryCompatible: Bool)?
    {
        #if DEBUG
        recordClaudeScanWork(.claudeLineDecode)
        #endif
        guard let decoded = try LosslessJSONLObject.decode(
            Array(data),
            numberObjectPaths: [
                [],
                ["metadata"],
                ["message"],
                ["message", "metadata"],
                ["message", "usage"],
                ["message", "usage", "cache_creation"],
            ],
            preserveOrdinaryNumbers: true,
            checkCancellation: checkCancellation) else { return nil }
        guard let object = ClaudeJSONObject.decoded(decoded.object),
              object["type"] as? String == "assistant"
        else { return (
            nil,
            decoded.ordinaryCompatible) }
        if providerFilter != .all, self.isVertexAIUsageEntry(
            obj: object, message: object.dictionary("message"), scanMetadata: scanMetadata)
            != (providerFilter == .vertexAIOnly) { return (nil, decoded.ordinaryCompatible) }
        return (
            ClaudeAccountingObservation(object: object, decoded: decoded, calendar: calendar),
            decoded.ordinaryCompatible)
    }
}

extension CostUsagePricing.ClaudeCostTokens {
    var total: Int? {
        CheckedSum.integers([self.input, self.cacheRead, self.cacheCreation, self.output])
    }
}
