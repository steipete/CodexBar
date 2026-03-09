import Foundation

enum ProviderCandidateRetryRunnerError: Error, Sendable {
    case noCandidates
}

enum ProviderCandidateRetryRunner {
    static func run<Candidate, Output>(
        _ candidates: [Candidate],
        shouldRetry: (Error) -> Bool,
        onRetry: (Candidate, Error) -> Void = { _, _ in },
        attempt: (Candidate) async throws -> Output) async throws -> Output
    {
        guard !candidates.isEmpty else {
            throw ProviderCandidateRetryRunnerError.noCandidates
        }

        for (index, candidate) in candidates.enumerated() {
            do {
                return try await attempt(candidate)
            } catch {
                let hasMoreCandidates = index + 1 < candidates.count
                guard hasMoreCandidates, shouldRetry(error) else {
                    throw error
                }
                onRetry(candidate, error)
            }
        }
        throw ProviderCandidateRetryRunnerError.noCandidates
    }
}
