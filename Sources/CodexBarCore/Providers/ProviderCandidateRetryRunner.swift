import Foundation

enum ProviderCandidateRetryRunnerError: Error {
    case noCandidates
}

enum ProviderCandidateRetryRunner {
    static func run<Candidates: Sequence, Output>(
        _ candidates: Candidates,
        shouldRetry: (Error) -> Bool,
        onRetry: (Candidates.Element, Error) -> Void = { _, _ in },
        attempt: (Candidates.Element) async throws -> Output) async throws -> Output
    {
        try Task.checkCancellation()
        var iterator = candidates.makeIterator()
        guard var candidate = iterator.next() else {
            throw ProviderCandidateRetryRunnerError.noCandidates
        }

        while true {
            try Task.checkCancellation()
            do {
                return try await attempt(candidate)
            } catch {
                try Task.checkCancellation()
                guard shouldRetry(error), let next = iterator.next() else {
                    throw error
                }
                onRetry(candidate, error)
                candidate = next
            }
        }
    }
}
