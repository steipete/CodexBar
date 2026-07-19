import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

enum LocalhostTrustPolicy {
    static func shouldAcceptServerTrust(
        host: String,
        authenticationMethod: String,
        hasServerTrust: Bool) -> Bool
    {
        #if !os(Linux)
        guard authenticationMethod == NSURLAuthenticationMethodServerTrust else { return false }
        #endif
        let normalizedHost = host.lowercased()
        guard normalizedHost == "127.0.0.1" || normalizedHost == "localhost" else { return false }
        return hasServerTrust
    }
}

final class LocalhostSessionDelegate: NSObject {
    func data(for request: URLRequest, session: URLSession) async throws -> (Data, URLResponse) {
        let state = LocalhostSessionTaskState()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let task = session.dataTask(with: request) { data, response, error in
                    if let error {
                        continuation.resume(throwing: error)
                        return
                    }
                    guard let data, let response else {
                        continuation.resume(throwing: AntigravityStatusProbeError.apiError("Invalid response"))
                        return
                    }
                    continuation.resume(returning: (data, response))
                }
                state.setTask(task)
                task.resume()
            }
        } onCancel: {
            state.cancel()
        }
    }

    private func challengeResult(_ challenge: URLAuthenticationChallenge) -> (
        disposition: URLSession.AuthChallengeDisposition,
        credential: URLCredential?)
    {
        #if os(Linux)
        return (.performDefaultHandling, nil)
        #else
        let protectionSpace = challenge.protectionSpace
        let trust = protectionSpace.serverTrust
        guard LocalhostTrustPolicy.shouldAcceptServerTrust(
            host: protectionSpace.host,
            authenticationMethod: protectionSpace.authenticationMethod,
            hasServerTrust: trust != nil),
            let trust
        else {
            return (.performDefaultHandling, nil)
        }
        return (.useCredential, URLCredential(trust: trust))
        #endif
    }
}

extension LocalhostSessionDelegate: URLSessionDelegate {
    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge) async -> (URLSession.AuthChallengeDisposition, URLCredential?)
    {
        self.challengeResult(challenge)
    }
}

extension LocalhostSessionDelegate: URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge) async -> (URLSession.AuthChallengeDisposition, URLCredential?)
    {
        self.challengeResult(challenge)
    }
}

private final class LocalhostSessionTaskState: @unchecked Sendable {
    private let lock = NSLock()
    private var task: URLSessionDataTask?
    private var isCancelled = false

    func setTask(_ task: URLSessionDataTask) {
        self.lock.lock()
        self.task = task
        let shouldCancel = self.isCancelled
        self.lock.unlock()

        if shouldCancel {
            task.cancel()
        }
    }

    func cancel() {
        self.lock.lock()
        self.isCancelled = true
        let task = self.task
        self.lock.unlock()
        task?.cancel()
    }
}
