import Foundation

/// Maps the platform.openai.com `credit_grants` response into a credit balance snapshot.
enum OpenAIPlatformCreditGrants {
    static let subscriptionGrantPrefix = "chatgpt_api_credits_promo_"

    struct Payload: Decodable {
        struct Grants: Decodable {
            let data: [Grant]
        }

        struct Grant: Decodable {
            let id: String
            let grantAmount: Double?
            let usedAmount: Double?
            let effectiveAt: Double?
            let expiresAt: Double?
            let isScheduled: Bool?

            var amount: Double {
                self.grantAmount ?? 0
            }

            var used: Double {
                min(self.usedAmount ?? 0, self.amount)
            }
        }

        let totalAvailable: Double
        let grants: Grants?
    }

    static func snapshot(from data: Data, now: Date, calendar: Calendar = .current) throws -> UsageSnapshot {
        let payload = try self.decode(
            Payload.self,
            from: data,
            message: "Could not parse OpenAI credit grants. The response format may have changed.")
        let nowSeconds = now.timeIntervalSince1970
        let grants = (payload.grants?.data ?? [])
            .filter { $0.amount > 0 && ($0.expiresAt ?? .infinity) > nowSeconds }
            .sorted { ($0.expiresAt ?? .infinity) < ($1.expiresAt ?? .infinity) }
        let isScheduled = { (grant: Payload.Grant) in
            grant.isScheduled == true || (grant.effectiveAt ?? 0) > nowSeconds
        }
        // Grants expire rather than reset, so the lane is the subscription grant about to be lost.
        let subscription = grants.first {
            $0.id.hasPrefix(self.subscriptionGrantPrefix) && !isScheduled($0) && $0.used < $0.amount
        }
        let amounts = { (grant: Payload.Grant) in
            "\(UsageFormatter.usdString(grant.amount - grant.used)) of " +
                "\(UsageFormatter.usdString(grant.amount)) left"
        }
        let primary = subscription.map { grant in
            RateWindow(
                usedPercent: grant.used / grant.amount * 100,
                windowMinutes: nil,
                resetsAt: nil,
                resetDescription: [amounts(grant), self.expiry(grant.expiresAt, now: now, calendar: calendar)]
                    .compactMap(\.self).joined(separator: " · "))
        }
        let rows = grants.filter { $0.id != subscription?.id }.map { grant in
            ProviderDetailSection.Row.makeRow(
                label: isScheduled(grant) ? "Scheduled credit"
                    : grant.id.hasPrefix(self.subscriptionGrantPrefix) ? "ChatGPT subscription credit"
                    : "Credit grant",
                value: amounts(grant),
                secondaryValue: self.expiry(grant.expiresAt, now: now, calendar: calendar),
                progress: .makeProgress(used: grant.used, total: grant.amount))
        }
        let details = rows.isEmpty ? [] : [ProviderDetailSection.makeSection(title: "Other credit grants", rows: rows)]
        return UsageSnapshot(
            primary: primary,
            secondary: nil,
            // The prepaid style shows `used` as the balance, matching Claude Platform credits. `resetsAt` keeps the
            // soonest grant expiry as a timestamp, where the legacy billing fallback also puts it.
            providerCost: ProviderCostSnapshot(
                used: payload.totalAvailable,
                limit: 0,
                currencyCode: "USD",
                period: "Prepaid credits",
                resetsAt: grants.first?.expiresAt.map(Date.init(timeIntervalSince1970:)),
                balance: payload.totalAvailable,
                updatedAt: now),
            details: details,
            updatedAt: now,
            identity: ProviderIdentitySnapshot(
                providerID: .openai,
                accountEmail: nil,
                accountOrganization: nil,
                loginMethod: "Platform session"),
            dataConfidence: .exact)
    }

    /// Decodes a snake_case platform.openai.com response, failing with `message` when the format drifts.
    static func decode<T: Decodable>(_ type: T.Type, from data: Data, message: String) throws -> T {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        do {
            return try decoder.decode(type, from: data)
        } catch {
            throw ProviderFetchClassifiedError(kind: .parseFailure, message: message)
        }
    }

    private static func expiry(_ expiresAt: Double?, now: Date, calendar: Calendar) -> String? {
        guard let expiresAt else { return nil }
        let date = Date(timeIntervalSince1970: expiresAt)
        var style = Date.FormatStyle(
            locale: Locale(identifier: "en_US"),
            calendar: calendar,
            timeZone: calendar.timeZone).month(.abbreviated).day()
        if calendar.component(.year, from: date) != calendar.component(.year, from: now) {
            style = style.year()
        }
        return "Expires \(date.formatted(style))"
    }
}
