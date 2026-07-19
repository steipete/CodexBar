import Foundation

/// Request usage snapshot for legacy Cursor plans (request-based instead of token-based).
public struct CursorRequestUsage: Codable, Sendable {
    /// Requests used this billing cycle
    public let used: Int
    /// Request limit (e.g., 500 for legacy enterprise plans)
    public let limit: Int

    public init(used: Int, limit: Int) {
        self.used = used
        self.limit = limit
    }

    public var usedPercent: Double {
        guard self.limit > 0 else { return 0 }
        return (Double(self.used) / Double(self.limit)) * 100
    }

    public var remainingPercent: Double {
        max(0, 100 - self.usedPercent)
    }
}
