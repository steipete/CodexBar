import Foundation

extension MiniMaxUsageFetcher {
    struct WebEnrichmentAttempt {
        let snapshot: MiniMaxUsageSnapshot
        let rejectedCredentials: Bool
        let receivedWebData: Bool
        let accountMismatch: Bool
    }

    static func attemptWebEnrichment(
        of snapshot: MiniMaxUsageSnapshot,
        context: WebFetchContext,
        groupID: String?) async throws -> WebEnrichmentAttempt
    {
        let resolvedGroupID = groupID ?? MiniMaxCookieHeader.override(from: context.cookie)?.groupID
        var enriched = snapshot
        var rejectedCredentials = false
        var receivedWebData = false
        var accountMismatch = false

        do {
            let credit = try await MiniMaxTokenPlanCreditFetcher.fetch(
                cookieHeader: context.cookie,
                groupID: resolvedGroupID,
                region: context.region,
                environment: context.environment,
                transport: context.transport)
            if let resolvedGroupID,
               !credit.groupIDs.isEmpty,
               credit.groupIDs.contains(resolvedGroupID)
            {
                enriched = enriched.withPointsBalanceFromDedicatedEndpoint(
                    credit.balance,
                    expiresAt: credit.expiresAt)
                receivedWebData = true
            } else if let resolvedGroupID,
                      !credit.groupIDs.isEmpty,
                      !credit.groupIDs.contains(resolvedGroupID)
            {
                accountMismatch = true
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch MiniMaxUsageError.invalidCredentials {
            rejectedCredentials = true
        } catch {
            Self.log.debug("MiniMax token plan credit unavailable: \(error.localizedDescription)")
        }

        return WebEnrichmentAttempt(
            snapshot: accountMismatch ? snapshot : enriched,
            rejectedCredentials: rejectedCredentials,
            receivedWebData: accountMismatch ? false : receivedWebData,
            accountMismatch: accountMismatch)
    }
}
