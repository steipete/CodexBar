import Foundation

extension CostUsageScanner {
    static func appendingCodexTokenTimestampsAreMonotonic(
        _ appended: [CostUsageCodexTokenSnapshot],
        to prefix: [CostUsageCodexTokenSnapshot],
        prefixIsMonotonic: Bool?,
        checkCancellation: CancellationCheck? = nil,
        workRecorder: CodexScanWorkRecorder? = nil) throws -> Bool
    {
        try checkCancellation?()
        // A legacy unknown prefix needs one validation; append cannot repair a known disorder.
        let prefixOrdered = try prefixIsMonotonic ?? Self.codexTokenTimestampsAreMonotonic(
            prefix,
            checkCancellation: checkCancellation,
            workRecorder: workRecorder)
        guard prefixOrdered else { return false }
        return try Self.codexTokenTimestampsAreMonotonic(
            appended,
            previous: prefix.last,
            checkCancellation: checkCancellation,
            workRecorder: workRecorder)
    }

    static func codexTokenTimestampsAreMonotonic(
        _ events: [CostUsageCodexTokenSnapshot],
        previous: CostUsageCodexTokenSnapshot? = nil,
        checkCancellation: CancellationCheck? = nil,
        workRecorder: CodexScanWorkRecorder? = nil) throws -> Bool
    {
        try checkCancellation?()
        guard !events.isEmpty else { return true }
        var previous = previous
        var previousDate = previous.flatMap { Self.dateFromTimestamp($0.timestamp) }
        for (index, current) in events.enumerated() {
            if index.isMultiple(of: 256) {
                try checkCancellation?()
            }
            let currentDate = Self.dateFromTimestamp(current.timestamp)
            if let previous {
                workRecorder?.recordTokenTimestampComparison()
                let isOrdered: Bool = if let previousDate, let currentDate {
                    previousDate <= currentDate
                } else {
                    previous.timestamp <= current.timestamp
                }
                if !isOrdered {
                    return false
                }
            }
            previous = current
            previousDate = currentDate
        }
        return true
    }
}
