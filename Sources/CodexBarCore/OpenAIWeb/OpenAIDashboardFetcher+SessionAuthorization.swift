#if os(macOS)
import Foundation

extension OpenAIDashboardFetcher {
    struct DashboardAPIResponse {
        let apiData: DashboardAPIData
        /// A bearer retry is paired only with the identity returned by that same cookie session.
        let verifiedSignedInEmail: String?
    }

    private struct SessionAuthorization: Decodable {
        struct User: Decodable {
            let email: String
        }

        let accessToken: String
        let user: User

        var verifiedEmail: String? {
            let email = self.user.email.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !email.isEmpty,
                  !self.accessToken.isEmpty,
                  self.accessToken.rangeOfCharacter(from: .whitespacesAndNewlines.union(.controlCharacters)) == nil
            else { return nil }
            return email
        }
    }

    static func fetchDashboardAPIResponse(
        cookieHeader: String,
        deadline: Date?,
        logger: @escaping (String) -> Void) async throws -> DashboardAPIResponse?
    {
        try Task.checkCancellation()
        guard !cookieHeader.isEmpty else { return nil }
        do {
            var (data, status) = try await self.fetchDashboardUsageResponse(
                cookieHeader: cookieHeader,
                bearerToken: nil,
                deadline: deadline,
                logger: logger)
            var authorization: SessionAuthorization?
            if status == 401 {
                guard let session = try await self.fetchDashboardSessionAuthorization(
                    cookieHeader: cookieHeader,
                    deadline: deadline,
                    logger: logger)
                else { return nil }
                authorization = session
                (data, status) = try await self.fetchDashboardUsageResponse(
                    cookieHeader: cookieHeader,
                    bearerToken: session.accessToken,
                    deadline: deadline,
                    logger: logger)
            }
            guard status >= 200, status < 300 else { return nil }
            let decoded = try JSONDecoder().decode(CodexUsageResponse.self, from: data)
            let result = self.dashboardAPIData(from: decoded)
            let authentication = (cookieHeader: cookieHeader, bearerToken: authorization?.accessToken)
            let monthlyResult = try await self.fetchSpendControlsMonthlyUsageIfNeeded(
                result,
                response: decoded,
                authentication: authentication,
                deadline: deadline,
                logger: logger)
            try Task.checkCancellation()
            let enrichedResult = try await self.fetchWorkspaceRemainingBalanceIfNeeded(
                monthlyResult,
                response: decoded,
                authentication: authentication,
                deadline: deadline,
                logger: logger)
            try Task.checkCancellation()
            if enrichedResult.hasUsageData {
                logger("usage api supplied language-independent rate/credit data")
            }
            return DashboardAPIResponse(
                apiData: enrichedResult,
                verifiedSignedInEmail: authorization?.verifiedEmail)
        } catch {
            if error is CancellationError || Task.isCancelled || (error as? URLError)?.code == .cancelled {
                throw CancellationError()
            }
            logger("usage api unavailable")
            return nil
        }
    }

    private static func fetchDashboardUsageResponse(
        cookieHeader: String,
        bearerToken: String?,
        deadline: Date?,
        logger: @escaping (String) -> Void) async throws -> (Data, Int)
    {
        try Task.checkCancellation()
        let remaining = deadline.map { self.remainingTimeout(until: $0) } ?? 4
        guard remaining > 0 else { throw URLError(.timedOut) }
        let (data, response) = try await CodexAuthenticatedHTTPTransport.current.data(
            for: self.dashboardUsageAPIRequest(
                cookieHeader: cookieHeader,
                bearerToken: bearerToken,
                timeout: min(4, remaining)))
        try Task.checkCancellation()
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        logger("usage api status=\(status)")
        return (data, status)
    }

    private static func fetchDashboardSessionAuthorization(
        cookieHeader: String,
        deadline: Date?,
        logger: @escaping (String) -> Void) async throws -> SessionAuthorization?
    {
        try Task.checkCancellation()
        let remaining = deadline.map { self.remainingTimeout(until: $0) } ?? 2
        guard remaining > 0 else { throw URLError(.timedOut) }
        let (data, response) = try await CodexAuthenticatedHTTPTransport.current.data(
            for: self.dashboardIdentityAPIRequest(
                url: URL(string: "https://chatgpt.com/api/auth/session")!,
                cookieHeader: cookieHeader,
                timeout: min(2, remaining)))
        try Task.checkCancellation()
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        logger("usage session api status=\(status)")
        guard status >= 200, status < 300 else { return nil }
        let session = try JSONDecoder().decode(SessionAuthorization.self, from: data)
        guard session.verifiedEmail != nil else { return nil }
        return session
    }
}
#endif
