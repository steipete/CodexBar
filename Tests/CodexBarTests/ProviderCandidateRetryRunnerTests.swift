import Testing
@testable import CodexBarCore

@Suite
struct ProviderCandidateRetryRunnerTests {
    private enum TestError: Error, Equatable {
        case retryable(Int)
        case nonRetryable(Int)
    }

    @Test
    func retriesThenSucceeds() async throws {
        let candidates = [1, 2, 3]
        var attempted: [Int] = []
        var retried: [Int] = []

        let output = try await ProviderCandidateRetryRunner.run(
            candidates,
            shouldRetry: { error in
                if case TestError.retryable = error {
                    return true
                }
                return false
            },
            onRetry: { candidate, _ in
                retried.append(candidate)
            },
            attempt: { candidate in
                attempted.append(candidate)
                guard candidate == 3 else {
                    throw TestError.retryable(candidate)
                }
                return candidate * 10
            })

        #expect(output == 30)
        #expect(attempted == [1, 2, 3])
        #expect(retried == [1, 2])
    }

    @Test
    func nonRetryableFailsImmediately() async {
        let candidates = [1, 2, 3]
        var attempted: [Int] = []
        var retried: [Int] = []

        do {
            _ = try await ProviderCandidateRetryRunner.run(
                candidates,
                shouldRetry: { error in
                    if case TestError.retryable = error {
                        return true
                    }
                    return false
                },
                onRetry: { candidate, _ in
                    retried.append(candidate)
                },
                attempt: { candidate in
                    attempted.append(candidate)
                    throw TestError.nonRetryable(candidate)
                })
            Issue.record("Expected TestError.nonRetryable")
        } catch let error as TestError {
            #expect(error == .nonRetryable(1))
            #expect(attempted == [1])
            #expect(retried.isEmpty)
        } catch {
            Issue.record("Expected TestError.nonRetryable(1), got \(error)")
        }
    }

    @Test
    func exhaustedRetryableThrowsLastError() async {
        let candidates = [1, 2]
        var attempted: [Int] = []
        var retried: [Int] = []

        do {
            _ = try await ProviderCandidateRetryRunner.run(
                candidates,
                shouldRetry: { error in
                    if case TestError.retryable = error {
                        return true
                    }
                    return false
                },
                onRetry: { candidate, _ in
                    retried.append(candidate)
                },
                attempt: { candidate in
                    attempted.append(candidate)
                    throw TestError.retryable(candidate)
                })
            Issue.record("Expected TestError.retryable")
        } catch let error as TestError {
            #expect(error == .retryable(2))
            #expect(attempted == [1, 2])
            #expect(retried == [1])
        } catch {
            Issue.record("Expected TestError.retryable(2), got \(error)")
        }
    }

    @Test
    func emptyCandidatesThrowsNoCandidates() async {
        do {
            let candidates: [Int] = []
            _ = try await ProviderCandidateRetryRunner.run(
                candidates,
                shouldRetry: { _ in true },
                attempt: { _ in 1 })
            Issue.record("Expected ProviderCandidateRetryRunnerError.noCandidates")
        } catch ProviderCandidateRetryRunnerError.noCandidates {
            // expected
        } catch {
            Issue.record("Expected ProviderCandidateRetryRunnerError.noCandidates, got \(error)")
        }
    }
}
