import Foundation

public struct ReplicateUsageFetcher: Sendable {
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
