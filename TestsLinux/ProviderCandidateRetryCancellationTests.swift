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
            await #expect(throws: CancellationError.self) {
                _ = try await ProviderCandidateRetryRunner.run(
                    candidates,
                    shouldRetry: { _ in true },
                    attempt: { $0 })
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
            await #expect(throws: CancellationError.self) {
                _ = try await ProviderCandidateRetryRunner.run(
                    candidates,
                    shouldRetry: { _ in true },
                    attempt: { candidate in
                        attempted.append(candidate)
                        return candidate
                    })
            }
            #expect(attempted.isEmpty)
        }.value
    }

    @Test
    func `cancellation during a failed attempt stops lazy browser traversal`() async {
        let (entered, signalEntered) = AsyncStream<Void>.makeStream()
        let (released, release) = AsyncStream<Void>.makeStream()
        let refresh = Task {
            var loaded: [Int] = []
            var attempted: [Int] = []
            var retried: [Int] = []
            let candidates = [1, 2].lazy.map { candidate in
                loaded.append(candidate)
                return candidate
            }
            await #expect(throws: CancellationError.self) {
                _ = try await ProviderCandidateRetryRunner.run(
                    candidates,
                    shouldRetry: { $0 is TestError },
                    onRetry: { candidate, _ in retried.append(candidate) },
                    attempt: { candidate -> Int in
                        attempted.append(candidate)
                        signalEntered.yield()
                        signalEntered.finish()
                        for await _ in released {
                            break
                        }
                        throw TestError.authenticationExpired
                    })
            }
            #expect(loaded == [1])
            #expect(attempted == [1])
            #expect(retried.isEmpty)
        }
        for await _ in entered {
            break
        }
        refresh.cancel()
        release.yield()
        release.finish()
        await refresh.value
    }
}
