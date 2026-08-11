import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct ReplicateUsageFetcher: Sendable {
    public static func fetchUsage(
        cookieHeader: String,
        username: String,
        accountKind: String,
        transport: any ProviderHTTPTransport = ProviderHTTPClient.shared,
        now: Date = Date()) async throws -> ReplicateUsageSummary
    {
        try await self.performFetch(
            cookieHeader: cookieHeader,
            username: username,
            accountKind: accountKind,
            transport: transport,
            now: now)
    }

    static func _fetchUsageForTesting(
        cookieHeader: String,
        username: String,
        accountKind: String,
        transport: any ProviderHTTPTransport,
        now: Date = Date()) async throws -> ReplicateUsageSummary
    {
        try await self.performFetch(
            cookieHeader: cookieHeader,
            username: username,
            accountKind: accountKind,
            transport: transport,
            now: now)
    }

    static func _parseSummaryForTesting(
        _ invoicesData: Data,
        creditData: Data? = nil,
        username: String? = nil,
        now: Date = Date()) throws -> ReplicateUsageSummary
    {
        try self.parseSummary(
            invoicesData: invoicesData,
            creditData: creditData,
            username: username,
            now: now)
    }

    public static func resolveAccount(fromBillingHTML html: String) throws -> (kind: String, username: String) {
        let payloads = self.reactComponentPropsJSONData(fromHTML: html)
        guard !payloads.isEmpty else {
            throw ReplicateUsageError.parseFailed("Missing react-component-props JSON")
        }

        for data in payloads {
            guard let json = try? JSONSerialization.jsonObject(with: data, options: []) else {
                continue
            }
            if let account = self.findAccount(in: json),
               let kind = (account["kind"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
               let username = (account["username"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !kind.isEmpty,
               !username.isEmpty
            {
                return (kind: kind, username: username)
            }
        }

        throw ReplicateUsageError.parseFailed("Missing account kind/username")
    }

    private static func performFetch(
        cookieHeader: String,
        username: String,
        accountKind: String,
        transport: any ProviderHTTPTransport,
        now: Date) async throws -> ReplicateUsageSummary
    {
        let header = cookieHeader.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !header.isEmpty else { throw ReplicateUsageError.missingCookie }

        let trimmedUsername = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedUsername.isEmpty else {
            throw ReplicateUsageError.parseFailed("Missing account username")
        }

        let invoicesURL = self.invoicesURL(username: trimmedUsername, accountKind: accountKind)
        let invoicesRequest = self.request(url: invoicesURL, cookieHeader: header)

        let invoicesResponse: ProviderHTTPResponse
        do {
            invoicesResponse = try await transport.response(
                for: invoicesRequest,
                retryPolicy: .transientIdempotent)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw ReplicateUsageError.networkError(error.localizedDescription)
        }

        try self.validateStatus(invoicesResponse.statusCode)

        let creditURL = self.unusedCreditURL(username: trimmedUsername, accountKind: accountKind)
        let creditData = try await self.fetchUnusedCreditData(
            url: creditURL,
            cookieHeader: header,
            transport: transport)

        return try self.parseSummary(
            invoicesData: invoicesResponse.data,
            creditData: creditData,
            username: trimmedUsername,
            now: now)
    }

    private static func fetchUnusedCreditData(
        url: URL,
        cookieHeader: String,
        transport: any ProviderHTTPTransport) async throws -> Data?
    {
        let request = self.request(url: url, cookieHeader: cookieHeader)
        do {
            let response = try await transport.response(for: request, retryPolicy: .transientIdempotent)
            guard response.statusCode == 200 else { return nil }
            return response.data
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return nil
        }
    }

    private static func request(url: URL, cookieHeader: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = ReplicateBillingEndpoints.timeoutSeconds
        return request
    }

    private static func validateStatus(_ statusCode: Int) throws {
        switch statusCode {
        case 200:
            return
        case 401, 403:
            throw ReplicateUsageError.invalidCredentials
        case 429:
            throw ReplicateUsageError.rateLimited
        default:
            throw ReplicateUsageError.apiError(statusCode)
        }
    }

    private static func invoicesURL(username: String, accountKind: String) -> URL {
        switch accountKind.lowercased() {
        case "organization":
            ReplicateBillingEndpoints.organizationInvoicesURL(organizationName: username)
        default:
            ReplicateBillingEndpoints.userInvoicesURL(username: username)
        }
    }

    private static func unusedCreditURL(username: String, accountKind: String) -> URL {
        switch accountKind.lowercased() {
        case "organization":
            ReplicateBillingEndpoints.organizationUnusedCreditURL(organizationName: username)
        default:
            ReplicateBillingEndpoints.userUnusedCreditURL(username: username)
        }
    }

    private static func parseSummary(
        invoicesData: Data,
        creditData: Data?,
        username: String?,
        now: Date) throws -> ReplicateUsageSummary
    {
        let invoicesResponse: ReplicateInvoicesResponse
        do {
            invoicesResponse = try JSONDecoder().decode(ReplicateInvoicesResponse.self, from: invoicesData)
        } catch {
            throw ReplicateUsageError.parseFailed(error.localizedDescription)
        }

        let currentMonthSpend = try Self.currentMonthSpend(from: invoicesResponse.invoices ?? [], now: now)

        var creditBalance: Double?
        if let creditData {
            let creditResponse: ReplicateUnusedCreditResponse
            do {
                creditResponse = try JSONDecoder().decode(ReplicateUnusedCreditResponse.self, from: creditData)
            } catch {
                throw ReplicateUsageError.parseFailed(error.localizedDescription)
            }
            if let rawCredit = creditResponse.unusedCredit?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                !rawCredit.isEmpty
            {
                guard let parsed = Double(rawCredit) else {
                    throw ReplicateUsageError.parseFailed("Invalid unused_credit value")
                }
                creditBalance = parsed
            }
        }

        return ReplicateUsageSummary(
            currentMonthSpend: currentMonthSpend,
            currencyCode: "USD",
            creditBalance: creditBalance,
            spendLimit: nil,
            username: username,
            updatedAt: now)
    }

    private static func currentMonthSpend(from invoices: [ReplicateInvoice], now: Date) throws -> Double {
        let monthlyInvoices = invoices.filter { $0.type == "monthly-usage" }
        guard let current = monthlyInvoices.first(where: { Self.isCurrentInvoice($0, now: now) }) else {
            throw ReplicateUsageError.parseFailed("No current monthly-usage invoice found")
        }

        let rawSpend = current.totalCostBeforeAdjustments?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let spendString = (rawSpend?.isEmpty == false) ? rawSpend! : "0"
        guard let spend = Double(spendString) else {
            throw ReplicateUsageError.parseFailed("Invalid total_cost_before_adjustments value")
        }
        return spend
    }

    private static func isCurrentInvoice(_ invoice: ReplicateInvoice, now: Date) -> Bool {
        guard let endedBefore = invoice.endedBefore?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !endedBefore.isEmpty
        else {
            return true
        }
        guard let endDate = Self.parseDate(endedBefore) else {
            return false
        }
        return endDate > now
    }

    private static func parseDate(_ value: String) -> Date? {
        let dayFormatter = DateFormatter()
        dayFormatter.calendar = Calendar(identifier: .gregorian)
        dayFormatter.locale = Locale(identifier: "en_US_POSIX")
        dayFormatter.timeZone = TimeZone(secondsFromGMT: 0)
        dayFormatter.dateFormat = "yyyy-MM-dd"
        if let date = dayFormatter.date(from: value) {
            return date
        }

        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = isoFormatter.date(from: value) {
            return date
        }
        isoFormatter.formatOptions = [.withInternetDateTime]
        return isoFormatter.date(from: value)
    }

    private static func reactComponentPropsJSONData(fromHTML html: String) -> [Data] {
        let data = Data(html.utf8)
        var payloads: [Data] = []
        var searchStart = data.startIndex

        while searchStart < data.endIndex,
              let idRange = data.range(of: Self.reactComponentPropsNeedle, options: [], in: searchStart..<data.endIndex)
        {
            guard let openTagEnd = data[idRange.upperBound...].firstIndex(of: UInt8(ascii: ">")) else {
                searchStart = idRange.upperBound
                continue
            }
            let contentStart = data.index(after: openTagEnd)
            guard let closeRange = data.range(
                of: Self.scriptCloseNeedle,
                options: [],
                in: contentStart..<data.endIndex)
            else {
                searchStart = idRange.upperBound
                continue
            }
            let rawData = data[contentStart..<closeRange.lowerBound]
            let trimmed = self.trimASCIIWhitespace(Data(rawData))
            if !trimmed.isEmpty {
                payloads.append(trimmed)
            }
            searchStart = closeRange.upperBound
        }

        return payloads
    }

    private static func findAccount(in value: Any) -> [String: Any]? {
        if let dict = value as? [String: Any] {
            if let account = dict["account"] as? [String: Any],
               account["kind"] is String,
               account["username"] is String
            {
                return account
            }

            var queue: [Any] = Array(dict.values)
            var seen = 0
            while !queue.isEmpty, seen < 4000 {
                let current = queue.removeFirst()
                seen += 1
                if let nested = current as? [String: Any] {
                    if let account = nested["account"] as? [String: Any],
                       account["kind"] is String,
                       account["username"] is String
                    {
                        return account
                    }
                    queue.append(contentsOf: nested.values)
                } else if let array = current as? [Any] {
                    queue.append(contentsOf: array)
                }
            }
        } else if let array = value as? [Any] {
            for element in array {
                if let account = self.findAccount(in: element) {
                    return account
                }
            }
        }
        return nil
    }

    private static func trimASCIIWhitespace(_ data: Data) -> Data {
        var start = data.startIndex
        var end = data.endIndex
        let whitespace: Set<UInt8> = [0x09, 0x0A, 0x0D, 0x20]
        while start < end, whitespace.contains(data[start]) {
            start = data.index(after: start)
        }
        while start < end {
            let previous = data.index(before: end)
            guard whitespace.contains(data[previous]) else { break }
            end = previous
        }
        return start == data.startIndex && end == data.endIndex ? data : Data(data[start..<end])
    }

    private static let reactComponentPropsNeedle = Data("id=\"react-component-props".utf8)
    private static let scriptCloseNeedle = Data("</script>".utf8)
}

private struct ReplicateInvoicesResponse: Decodable {
    let invoices: [ReplicateInvoice]?
}

private struct ReplicateInvoice: Decodable {
    let id: String?
    let type: String?
    let status: String?
    let startedOn: String?
    let endedBefore: String?
    let totalCost: String?
    let totalCostBeforeAdjustments: String?

    private enum CodingKeys: String, CodingKey {
        case id
        case type
        case status
        case startedOn = "started_on"
        case endedBefore = "ended_before"
        case totalCost = "total_cost"
        case totalCostBeforeAdjustments = "total_cost_before_adjustments"
    }
}

private struct ReplicateUnusedCreditResponse: Decodable {
    let unusedCredit: String?
    let linkToAddCredit: String?

    private enum CodingKeys: String, CodingKey {
        case unusedCredit = "unused_credit"
        case linkToAddCredit = "link_to_add_credit"
    }
}
