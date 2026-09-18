import Foundation

enum ProviderTransportError {
    static func preservingIdentity(of error: Error, describedBy providerError: Error) -> Error {
        if error is CancellationError { return error }
        let original = error as NSError
        guard original.domain == NSURLErrorDomain else { return providerError }
        // Provider diagnostics must not erase the transport codes used for retention and retries.
        var userInfo = original.userInfo
        userInfo[NSLocalizedDescriptionKey] = providerError.localizedDescription
        return NSError(domain: original.domain, code: original.code, userInfo: userInfo)
    }
}
