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
            let trace = await Task.detached {
                var loaded: [Int] = []
                var attempted: [Int] = []
                var retried: [Int] = []
                var events: [String] = []
                if scenario == .beforeStart {
                    withUnsafeCurrentTask { $0?.cancel() }
                    events.append("cancel")
                }
                let candidates = [1, 2].lazy.map { candidate in
                    let url = root.appendingPathComponent("profile-\(candidate)")
                    guard let data = FileManager.default.contents(atPath: url.path),
                          String(decoding: data, as: UTF8.self) == "fixture-session-\(candidate)"
                    else { fatalError("Owned fixture is missing or corrupt") }
                    loaded.append(candidate)
                    events.append("read-profile-\(candidate)")
                    if scenario == .duringLoad {
                        withUnsafeCurrentTask { $0?.cancel() }
                        events.append("cancel")
                    }
                    return candidate
                }
                let outcome: String
                do {
                    let value = try await ProviderCandidateRetryRunner.run(
                        candidates,
                        shouldRetry: { $0 is FixtureError },
                        onRetry: { candidate, _ in retried.append(candidate) },
                        attempt: { candidate in
                            attempted.append(candidate)
                            events.append("attempt-\(candidate)")
                            if candidate == 1,
                               scenario == .normalRetry || scenario == .duringFailedAttempt
                            {
                                if scenario == .duringFailedAttempt {
                                    withUnsafeCurrentTask { $0?.cancel() }
                                    events.append("cancel")
                                }
                                events.append("authentication-expired")
                                throw FixtureError.authenticationExpired
                            }
                            return candidate
                        })
                    outcome = "success(\(value))"
                } catch is CancellationError {
                    outcome = "cancelled"
                } catch {
                    outcome = "error(\(error))"
                }
                return "\(scenario.rawValue): outcome=\(outcome) loaded=\(loaded) "
                    + "attempted=\(attempted) retried=\(retried)\n  " + events.joined(separator: " -> ")
            }.value
            print(trace)
        }
    }
}
