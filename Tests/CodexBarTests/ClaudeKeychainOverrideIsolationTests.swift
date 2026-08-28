import Foundation
import Testing
@testable import CodexBarCore

private actor TwoTaskBarrier {
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        await withCheckedContinuation { continuation in
            self.continuations.append(continuation)
            guard self.continuations.count == 2 else {
                return
            }
            let continuations = self.continuations
            self.continuations.removeAll()
            continuations.forEach { $0.resume() }
        }
    }
}

struct ClaudeKeychainOverrideIsolationTests {
    @Test
    func `keychain overrides stay isolated across concurrent tasks`() async {
        let expected = [Data([0x01]), Data([0x02])]
        let barrier = TwoTaskBarrier()
        let observed = await withTaskGroup(of: Data?.self, returning: [Data].self) { group in
            for data in expected {
                group.addTask {
                    await ClaudeOAuthCredentialsStore.withClaudeKeychainOverridesForTesting(
                        data: data,
                        fingerprint: nil)
                    {
                        await barrier.wait()
                        return ClaudeOAuthCredentialsStore.taskClaudeKeychainDataOverride
                    }
                }
            }

            var values: [Data] = []
            for await value in group {
                if let value {
                    values.append(value)
                }
            }
            return values
        }

        #expect(Set(observed) == Set(expected))
        #expect(ClaudeOAuthCredentialsStore.taskClaudeKeychainDataOverride == nil)
    }
}
