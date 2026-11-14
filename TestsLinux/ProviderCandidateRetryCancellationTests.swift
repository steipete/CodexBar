import Testing
@testable import CodexBarCore

struct ProviderCandidateRetryCancellationTests {
    private enum TestError: Error {
        case authenticationExpired
    }

    @Test
    func `cancelled refresh does not load its first candidate`() async {
        await Task {
            withUnsafeCurrentTask { $0?.cancel() }
            var loaded: [Int] = []
            let candidates = [1, 2].lazy.map { candidate in
                loaded.append(candidate)
                return candidate
            }
            do {
                _ = try await ProviderCandidateRetryRunner.run(
                    candidates,
                    shouldRetry: { _ in true },
                    attempt: { $0 })
                Issue.record("Expected cancellation")
            } catch is CancellationError {
                // Expected.
            } catch {
                Issue.record("Expected cancellation, got \(error)")
            }
            #expect(loaded.isEmpty)
        }.value
    }

    @Test
    func `cancellation while loading a candidate prevents its attempt`() async {
        await Task {
            var attempted: [Int] = []
            let candidates = [1, 2].lazy.map { candidate in
                withUnsafeCurrentTask { $0?.cancel() }
                return candidate
            }
            do {
                _ = try await ProviderCandidateRetryRunner.run(
                    candidates,
                    shouldRetry: { _ in true },
                    attempt: { candidate in
                        attempted.append(candidate)
                        return candidate
                    })
                Issue.record("Expected cancellation")
            } catch is CancellationError {
                // Expected.
            } catch {
                Issue.record("Expected cancellation, got \(error)")
            }
            #expect(attempted.isEmpty)
        }.value
    }

    @Test
    func `cancellation during a failed attempt stops lazy browser traversal`() async {
        await Task {
            var loaded: [Int] = []
            var attempted: [Int] = []
            var retried: [Int] = []
            let candidates = [1, 2].lazy.map { candidate in
                loaded.append(candidate)
                return candidate
            }
            do {
                _ = try await ProviderCandidateRetryRunner.run(
                    candidates,
                    shouldRetry: { $0 is TestError },
                    onRetry: { candidate, _ in retried.append(candidate) },
                    attempt: { candidate -> Int in
                        attempted.append(candidate)
                        withUnsafeCurrentTask { $0?.cancel() }
                        throw TestError.authenticationExpired
                    })
                Issue.record("Expected cancellation")
            } catch is CancellationError {
                // Expected.
            } catch {
                Issue.record("Expected cancellation, got \(error)")
            }
            #expect(loaded == [1])
            #expect(attempted == [1])
            #expect(retried.isEmpty)
        }.value
    }
}
