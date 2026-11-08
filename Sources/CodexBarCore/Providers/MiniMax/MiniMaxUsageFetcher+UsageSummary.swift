import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

extension MiniMaxUsageFetcher {
    static func attachingOptionalUsageIfAvailable(
        to snapshot: MiniMaxUsageSnapshot,
        context: WebFetchContext,
        groupID: String?,
        includeBillingHistory: Bool,
        now: Date) async throws -> MiniMaxUsageSnapshot
    {
        guard includeBillingHistory else { return snapshot }
        if self.usageSummaryURL(context: context) != nil {
            return try await self.attachingUsageSummaryIfAvailable(
                to: snapshot,
                context: context,
                groupID: groupID,
                now: now)
        }
        return try await self.attachingBillingIfAvailable(
            to: snapshot,
            context: context,
            includeBillingHistory: includeBillingHistory,
            now: now)
    }

    static func usageSummaryURL(context: WebFetchContext) -> URL? {
        // Keep console-session credentials on the current China host. Legacy sessions and
        // custom endpoints retain their existing billing path.
        guard context.region == .chinaMainland,
              CookieHeaderNormalizer.pairs(from: context.cookie).contains(where: {
                  $0.name == "_token" && !$0.value.isEmpty
              }),
              self.resolveCodingPlanURL(region: context.region, environment: context.environment)
              == URL(string: "https://platform.minimax.cn/console/usage"),
              self.resolveRemainsURLs(region: context.region, environment: context.environment).first
              == URL(string: "https://www.minimax.cn/backend/account/token_plan/remains_percent"),
              SettingsValue.cleaned(context.environment[MiniMaxSettingsReader.billingHistoryURLKey]) == nil
        else { return nil }
        return URL(string: "https://www.minimax.cn/backend/account/token_plan/usage_summary")
    }

    static func attachingUsageSummaryIfAvailable(
        to snapshot: MiniMaxUsageSnapshot,
        context: WebFetchContext,
        groupID: String?,
        now: Date) async throws -> MiniMaxUsageSnapshot
    {
        guard let url = self.usageSummaryURL(context: context) else { return snapshot }
        var request = self.makeWebRequest(
            url: url,
            context: context,
            accept: "application/json, text/plain, */*")
        let cookieGroupID = CookieHeaderNormalizer.pairs(from: context.cookie)
            .first { $0.name == "minimax_group_id_v2" }?.value
        if let groupID = SettingsValue.cleaned(groupID) ?? SettingsValue.cleaned(cookieGroupID) {
            request.setValue(groupID, forHTTPHeaderField: "X-Group-Id")
        }
        request.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
        request.setValue("https://platform.minimax.cn", forHTTPHeaderField: "Origin")
        request.setValue("https://platform.minimax.cn/console/usage", forHTTPHeaderField: "Referer")

        do {
            let response = try await context.transport.response(for: request)
            guard response.statusCode == 200 else {
                Self.log.debug("MiniMax token usage summary unavailable (HTTP \(response.statusCode))")
                return snapshot
            }
            let summary = try MiniMaxUsageSummaryParser.parse(data: response.data, now: now)
            return snapshot.withUsageSummary(summary)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw error
        } catch {
            // Optional statistics must not discard a successfully authenticated quota response.
            // Avoid logging server payloads or errors that could contain session credentials.
            Self.log.debug("MiniMax token usage summary unavailable")
            return snapshot
        }
    }
}
