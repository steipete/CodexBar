import Foundation

extension MiniMaxUsageFetcher {
    static func attachingUsageSummaryIfAvailable(
        to snapshot: MiniMaxUsageSnapshot,
        context: WebFetchContext,
        groupID: String?) async throws -> MiniMaxUsageSnapshot
    {
        guard MiniMaxCookieHeader.normalized(from: context.cookie) != nil else {
            return snapshot
        }

        let resolvedGroupID = groupID ?? MiniMaxCookieHeader.override(from: context.cookie)?.groupID
        do {
            let summary = try await MiniMaxUsageSummaryFetcher.fetch(
                cookieHeader: context.cookie,
                groupID: resolvedGroupID,
                region: context.region,
                environment: context.environment,
                transport: context.transport)
            return snapshot.withUsageSummary(summary)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch let error as MiniMaxUsageError {
            if case .invalidCredentials = error, context.authorizationToken != nil {
                throw error
            }
            Self.log.debug("MiniMax usage summary unavailable: \(error.localizedDescription)")
            return snapshot
        } catch {
            Self.log.debug("MiniMax usage summary unavailable: \(error.localizedDescription)")
            return snapshot
        }
    }
}
