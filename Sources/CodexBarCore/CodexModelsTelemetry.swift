import Foundation

#if canImport(os)
import os

typealias CodexModelsSignpostID = OSSignpostID

enum CodexModelsTelemetry {
    private static let log = OSLog(subsystem: "com.steipete.codexbar", category: "ModelsAnalytics")

    static func begin(_ name: StaticString) -> CodexModelsSignpostID {
        let id = OSSignpostID(log: self.log)
        os_signpost(.begin, log: self.log, name: name, signpostID: id)
        return id
    }

    static func end(_ name: StaticString, id: OSSignpostID) {
        os_signpost(.end, log: self.log, name: name, signpostID: id)
    }

    static func cacheHit(historyDays: Int) {
        os_signpost(.event, log: self.log, name: "SnapshotCacheHit", "historyDays=%{public}d", historyDays)
    }

    static func parity(dimensions: [CodexModelsParityDimension], rowCount: Int) {
        let mask = dimensions.reduce(0) { partial, dimension in
            guard let index = CodexModelsParityDimension.allCases.firstIndex(of: dimension) else { return partial }
            return partial | (1 << index)
        }
        os_signpost(
            .event,
            log: self.log,
            name: "DualRunParity",
            "mismatches=%{public}d mask=%{public}d rows=%{public}d",
            dimensions.count,
            mask,
            rowCount)
    }
}

#else

struct CodexModelsSignpostID: Sendable {}

enum CodexModelsTelemetry {
    static func begin(_: StaticString) -> CodexModelsSignpostID {
        CodexModelsSignpostID()
    }

    static func end(_: StaticString, id _: CodexModelsSignpostID) {}

    static func cacheHit(historyDays _: Int) {}

    static func parity(dimensions _: [CodexModelsParityDimension], rowCount _: Int) {}
}

#endif
