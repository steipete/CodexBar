import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// One raw ledger row from `GET .../credits/history` (design.md D3). `time` is ISO8601-shaped;
/// `cost` is the credits consumed by that session/task run.
public struct ZoomMateCreditHistoryRecord: Decodable, Sendable {
    public let sessionID: String?
    public let title: String?
    public let cost: Double?
    public let time: String?
    public let isRunning: Bool?
    public let isDeleted: Bool?

    private enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case title
        case cost
        case time
        case isRunning = "is_running"
        case isDeleted = "is_deleted"
    }

    public init(
        sessionID: String?,
        title: String?,
        cost: Double?,
        time: String?,
        isRunning: Bool?,
        isDeleted: Bool?)
    {
        self.sessionID = sessionID
        self.title = title
        self.cost = cost
        self.time = time
        self.isRunning = isRunning
        self.isDeleted = isDeleted
    }
}

/// Aggregated result of fetching `credits/history` across as many pages as needed to cover the
/// requested window. Kept separate from the daily-bucketed breakdown so the same raw records can
/// be re-aggregated without refetching.
///
/// `creditStatus` carries the `credits/status` snapshot the history fetch was paired with, so
/// the menu layer can compute the pacing verdict (`ZoomMateUsageSnapshot.pacingVerdict`) directly
/// from this one attached object instead of needing a second field on `UsageSnapshot` — deferring
/// pace computation to render time also means it always reflects "now," not the last fetch time.
public struct ZoomMateCreditsHistorySnapshot: Sendable {
    public let records: [ZoomMateCreditHistoryRecord]
    public let creditStatus: ZoomMateCreditStatus?
    public let updatedAt: Date

    public init(
        records: [ZoomMateCreditHistoryRecord],
        creditStatus: ZoomMateCreditStatus? = nil,
        updatedAt: Date)
    {
        self.records = records
        self.creditStatus = creditStatus
        self.updatedAt = updatedAt
    }

    /// Pacing verdict computed from the paired `credits/status` snapshot, if one was attached at
    /// fetch time. `nil` when no `creditStatus` is available (e.g. it wasn't passed to `fetch`)
    /// or when the account is unlimited / missing cycle dates — see
    /// `ZoomMateCreditStatus.pacingVerdict`.
    public func pacingVerdict(now: Date = Date()) -> UsagePace? {
        self.creditStatus?.pacingVerdict(now: now)
    }
}

/// Fetches and paginates `GET https://ai.zoom.us/ai-computer/api/v1/credits/history` (design.md
/// D3). Reuses the same minted-bearer `RequestContext` as `credits/status` — no separate auth
/// mechanism. `app_id` is confirmed not a scoping filter (D3/R2), so a fixed placeholder matching
/// ZoomMate's own web UI (`demo_app`) is sent on every request.
public struct ZoomMateCreditsHistoryFetcher: Sendable {
    private static let log = CodexBarLog.logger(LogCategories.zoommate)
    private static let historyPath = "/ai-computer/api/v1/credits/history"
    private static let refererURL = URL(string: "https://zoommate.zoom.us")!
    private static let userAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) " +
        "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36"

    /// Confirmed cheap for real accounts (design.md D3/R3): 30 days of history is at most a
    /// couple of pages at this size, well below any practical rate-limit concern. A larger
    /// `limit` than the web UI's `10` reduces round-trips without meaningfully increasing
    /// payload size (records are small).
    public static let defaultPageLimit = 50
    /// Hard ceiling on pagination requests per fetch, independent of the account's actual
    /// history size — guards against an unexpectedly large or misbehaving account/response
    /// (e.g. a `total` that never gets satisfied) turning into an unbounded fetch loop.
    public static let maxPages = 20

    public init() {}

    /// Fetches every record whose `time` falls within `[startTime, endTime]`, paginating with
    /// `limit`/`page` until the endpoint's flat `total` count is satisfied (no other pagination
    /// metadata exists — design.md D3).
    public static func fetch(
        context: ZoomMateUsageFetcher.RequestContext,
        startTime: Date,
        endTime: Date,
        creditStatus: ZoomMateCreditStatus? = nil,
        limit: Int = ZoomMateCreditsHistoryFetcher.defaultPageLimit,
        timeout: TimeInterval = 15,
        now: Date = Date(),
        transport: any ProviderHTTPTransport = ProviderHTTPClient.shared) async throws -> ZoomMateCreditsHistorySnapshot
    {
        // The whole pagination loop fails over as a unit so all pages of one snapshot come from
        // the same host.
        try await ZoomMateUsageFetcher.withAPIHostFailover { host in
            var allRecords: [ZoomMateCreditHistoryRecord] = []
            var page = 0
            var total = Int.max

            while page * limit < total, page < self.maxPages {
                let request = PageRequest(
                    host: host,
                    context: context,
                    startTime: startTime,
                    endTime: endTime,
                    limit: limit,
                    page: page,
                    timeout: timeout,
                    transport: transport)
                let envelope = try await self.fetchPage(request)
                guard let data = envelope.data else {
                    throw ZoomMateUsageError.parseFailed("Missing data object in credits/history response.")
                }
                let pageRecords = data.records ?? []
                allRecords.append(contentsOf: pageRecords)
                total = data.total ?? allRecords.count
                if pageRecords.isEmpty {
                    // Defensive: stop if the server ever returns an empty page before `total` is
                    // reached, rather than looping until `maxPages`.
                    break
                }
                // Defensive date-boundary stop (design.md D2): `total` reflects the account's entire
                // history, not just the requested window, so a server-side filtering quirk could
                // otherwise cause extra pagination past what the window actually needs. If every
                // record on this page is already older than the requested `startTime` (rows are
                // sorted `time desc`, so an entirely-stale page means all subsequent pages are stale
                // too), stop here rather than trusting `total`/`maxPages` to eventually end the loop.
                let allOlderThanWindow = pageRecords.allSatisfy { record in
                    guard let time = record.time, let parsed = Self.parseRecordTime(time) else { return false }
                    return parsed < startTime
                }
                if allOlderThanWindow {
                    break
                }
                page += 1
            }

            return ZoomMateCreditsHistorySnapshot(records: allRecords, creditStatus: creditStatus, updatedAt: now)
        }
    }

    private static func fetchPage(_ pageRequest: PageRequest) async throws -> HistoryEnvelope {
        var components = URLComponents(string: "https://\(pageRequest.host)\(self.historyPath)")!
        components.queryItems = [
            URLQueryItem(name: "app_id", value: "demo_app"),
            URLQueryItem(name: "limit", value: String(pageRequest.limit)),
            URLQueryItem(name: "page", value: String(pageRequest.page)),
            URLQueryItem(name: "sort_by", value: "time"),
            URLQueryItem(name: "sort_order", value: "desc"),
            URLQueryItem(name: "start_time", value: Self.iso8601String(pageRequest.startTime)),
            URLQueryItem(name: "end_time", value: Self.iso8601String(pageRequest.endTime)),
        ]
        guard let url = components.url else {
            throw ZoomMateUsageError.apiError("Failed to build credits/history URL.")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = pageRequest.timeout
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        request.setValue(self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("empty", forHTTPHeaderField: "Sec-Fetch-Dest")
        request.setValue("cors", forHTTPHeaderField: "Sec-Fetch-Mode")
        request.setValue("same-site", forHTTPHeaderField: "Sec-Fetch-Site")
        for (name, value) in pageRequest.context.headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        request.setValue(pageRequest.context.authorization, forHTTPHeaderField: "Authorization")
        request.setValue(self.refererURL.absoluteString, forHTTPHeaderField: "Origin")
        request.setValue(self.refererURL.absoluteString, forHTTPHeaderField: "Referer")

        let response = try await pageRequest.transport.response(for: request)
        let data = response.data
        guard response.statusCode == 200 else {
            Self.log.error("ZoomMate credits/history returned \(response.statusCode)")
            if response.statusCode == 401 || response.statusCode == 403 {
                throw ZoomMateUsageError.invalidCredentials
            }
            throw ZoomMateUsageError.apiError("HTTP \(response.statusCode)")
        }

        do {
            return try JSONDecoder().decode(HistoryEnvelope.self, from: data)
        } catch {
            Self.log.error("ZoomMate credits/history parse failed")
            throw ZoomMateUsageError.parseFailed(error.localizedDescription)
        }
    }

    private static func iso8601String(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    /// Parses a record's `time` field for the pagination date-boundary check. Tries with and
    /// without fractional seconds, matching the range of ISO8601 shapes the API may return.
    private static func parseRecordTime(_ text: String) -> Date? {
        let withFractional = ISO8601DateFormatter()
        withFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFractional.date(from: text) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: text)
    }

    private struct PageRequest {
        let host: String
        let context: ZoomMateUsageFetcher.RequestContext
        let startTime: Date
        let endTime: Date
        let limit: Int
        let page: Int
        let timeout: TimeInterval
        let transport: any ProviderHTTPTransport
    }

    private struct HistoryEnvelope: Decodable {
        struct DataBox: Decodable {
            let records: [ZoomMateCreditHistoryRecord]?
            let total: Int?
        }

        let data: DataBox?
        let statusCode: Int?
        let errorMessage: String?

        private enum CodingKeys: String, CodingKey {
            case data
            case statusCode = "status_code"
            case errorMessage = "error_message"
        }
    }
}
