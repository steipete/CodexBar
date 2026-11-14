import Foundation

/// Standalone runtime proof: compile alongside the production retry runner, without a test framework.
@main
enum ProviderCandidateCancellationProof {
    enum Scenario: String, CaseIterable {
        case beforeStart
        case duringLoad
        case duringFailedAttempt
        case normalRetry
    }

    enum FixtureError: Error {
        case authenticationExpired
    }

    final class Trace {
        let scenario: Scenario
        let root: URL
        var loaded: [Int] = []
        var attempted: [Int] = []
        var retried: [Int] = []
        var events: [String] = []

        init(scenario: Scenario, root: URL) {
            self.scenario = scenario
            self.root = root
        }

        func cancel() {
            withUnsafeCurrentTask { $0?.cancel() }
            self.events.append("cancel")
        }

        func load(_ candidate: Int) -> Int {
            let url = self.root.appendingPathComponent("profile-\(candidate)")
            guard let data = FileManager.default.contents(atPath: url.path),
                  data == Data("fixture-session-\(candidate)".utf8)
            else { fatalError("Owned fixture is missing or corrupt") }
            self.loaded.append(candidate)
            self.events.append("read-profile-\(candidate)")
            if self.scenario == .duringLoad { self.cancel() }
            return candidate
        }

        func attempt(_ candidate: Int) throws -> Int {
            self.attempted.append(candidate)
            self.events.append("attempt-\(candidate)")
            if candidate == 1, self.scenario == .normalRetry || self.scenario == .duringFailedAttempt {
                if self.scenario == .duringFailedAttempt { self.cancel() }
                self.events.append("authentication-expired")
                throw FixtureError.authenticationExpired
            }
            return candidate
        }

        func summary(outcome: String) -> String {
            "\(self.scenario.rawValue): outcome=\(outcome) loaded=\(self.loaded) "
                + "attempted=\(self.attempted) retried=\(self.retried)\n  "
                + self.events.joined(separator: " -> ")
        }
    }

    static func main() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("candidate-cancellation-proof-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for candidate in [1, 2] {
            try Data("fixture-session-\(candidate)".utf8).write(
                to: root.appendingPathComponent("profile-\(candidate)"))
        }

        for scenario in Scenario.allCases {
            let output = await Task.detached {
                let trace = Trace(scenario: scenario, root: root)
                if scenario == .beforeStart { trace.cancel() }
                let candidates = [1, 2].lazy.map { trace.load($0) }
                let outcome: String
                do {
                    let value = try await ProviderCandidateRetryRunner.run(
                        candidates,
                        shouldRetry: { $0 is FixtureError },
                        onRetry: { candidate, _ in trace.retried.append(candidate) },
                        attempt: { try trace.attempt($0) })
                    outcome = "success(\(value))"
                } catch is CancellationError {
                    outcome = "cancelled"
                } catch {
                    outcome = "error(\(error))"
                }
                return trace.summary(outcome: outcome)
            }.value
            print(output)
        }
    }
}
