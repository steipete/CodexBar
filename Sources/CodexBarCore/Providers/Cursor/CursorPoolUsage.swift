import Foundation

/// Usage snapshot for Cursor's Auto and API model pools (token-based pro plans).
///
/// Cursor separates quota into two buckets:
/// - **Auto pool** – includes base quota + bonus credits; used when Cursor picks the model automatically.
/// - **API pool** – base quota only; used when a specific named/external model is selected.
public struct CursorPoolUsage: Codable, Sendable {
    /// Percentage of Auto pool consumed (0-100). Accounts for bonus credits.
    public let autoPercentUsed: Double
    /// Percentage of API pool consumed (0-100). Base plan limit only.
    public let apiPercentUsed: Double
    /// Total Auto pool size in requests (included base + bonus credits).
    public let autoPoolTotal: Int?
    /// Total API pool size in requests (base plan limit).
    public let apiPoolTotal: Int?
    /// Requests consumed from the Auto pool.
    public let autoPoolUsed: Int?
    /// Requests consumed from the API pool (estimated from percent × total).
    public let apiPoolUsed: Int?

    public init(
        autoPercentUsed: Double,
        apiPercentUsed: Double,
        autoPoolTotal: Int?,
        apiPoolTotal: Int?,
        autoPoolUsed: Int?,
        apiPoolUsed: Int?)
    {
        self.autoPercentUsed = autoPercentUsed
        self.apiPercentUsed = apiPercentUsed
        self.autoPoolTotal = autoPoolTotal
        self.apiPoolTotal = apiPoolTotal
        self.autoPoolUsed = autoPoolUsed
        self.apiPoolUsed = apiPoolUsed
    }

    public var autoRemainingPercent: Double { max(0, 100 - self.autoPercentUsed) }
    public var apiRemainingPercent: Double { max(0, 100 - self.apiPercentUsed) }
}
