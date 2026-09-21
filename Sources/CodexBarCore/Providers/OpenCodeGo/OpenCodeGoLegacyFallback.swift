import Foundation

enum OpenCodeGoLegacyFallback {
    static func fetch<Value: Sendable>(
        cookieHeader: String,
        isUsableLegacyValue: @Sendable (Value) -> Bool = { _ in true },
        console: @Sendable () async throws -> Value,
        legacy: @Sendable () async throws -> Value) async throws -> Value
    {
        try Task.checkCancellation()
        do {
            let value = try await console()
            try Task.checkCancellation()
            return value
        } catch {
            let consoleError = error
            guard try self.shouldTryLegacy(after: error, cookieHeader: cookieHeader) else { throw error }
            do {
                let value = try await legacy()
                try Task.checkCancellation()
                if !isUsableLegacyValue(value),
                   !self.isInvalidCredentials(consoleError),
                   self.hasCookie(in: cookieHeader, names: OpenCodeWebCookieSupport.consoleSessionCookieNames)
                {
                    throw consoleError
                }
                return value
            } catch {
                try self.checkCancellation(error)
                // Failed legacy reads cannot turn a Console access failure into invalid auth or absent Go usage.
                if error is OpenCodeGoUsageError,
                   !self.isInvalidCredentials(consoleError),
                   self.hasCookie(in: cookieHeader, names: OpenCodeWebCookieSupport.consoleSessionCookieNames)
                {
                    throw consoleError
                }
                throw error
            }
        }
    }

    private static func shouldTryLegacy(after error: Error, cookieHeader: String) throws -> Bool {
        try self.checkCancellation(error)
        if case .noSubscription? = error as? OpenCodeGoUsageError { return false }
        guard self.hasCookie(in: cookieHeader, names: OpenCodeWebCookieSupport.sessionCookieNames) else { return false }
        if error is OpenCodeGoUsageError { return true }
        guard let error = error as? URLError else { return false }
        switch error.code {
        case .timedOut, .networkConnectionLost, .cannotConnectToHost, .cannotFindHost,
             .dnsLookupFailed, .notConnectedToInternet, .resourceUnavailable:
            return true
        default:
            return false
        }
    }

    private static func checkCancellation(_ error: Error) throws {
        try Task.checkCancellation()
        if error is CancellationError || (error as? URLError)?.code == .cancelled {
            throw CancellationError()
        }
    }

    private static func isInvalidCredentials(_ error: Error) -> Bool {
        if case .invalidCredentials? = error as? OpenCodeGoUsageError { return true }
        return false
    }

    private static func hasCookie(in header: String, names: Set<String>) -> Bool {
        CookieHeaderNormalizer.pairs(from: header).contains { names.contains($0.name) && !$0.value.isEmpty }
    }
}
