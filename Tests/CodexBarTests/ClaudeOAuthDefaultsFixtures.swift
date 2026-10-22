import Foundation
import Testing
@testable import CodexBarCore

struct ClaudeOAuthDefaultsFixtures: TestTrait, SuiteTrait, TestScoping {
    @TaskLocal private static var current: LockIsolated<InMemoryUserDefaults>?

    static var defaults: InMemoryUserDefaults {
        guard let current else { preconditionFailure("Add ClaudeOAuthDefaultsFixtures to this test or suite") }
        return current.value
    }

    var isRecursive: Bool {
        true
    }

    func provideScope(
        for test: Test,
        testCase: Test.Case?,
        performing function: @Sendable () async throws -> Void) async throws
    {
        let defaults = InMemoryUserDefaults()
        try await Self.$current.withValue(LockIsolated(defaults)) {
            try await ClaudeOAuthKeychainPromptPreference.withApplicationUserDefaultsOverrideForTesting(defaults) {
                try await function()
            }
        }
    }
}
