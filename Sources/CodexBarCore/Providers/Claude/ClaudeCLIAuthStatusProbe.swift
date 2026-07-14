import Foundation

enum ClaudeCLIAuthStatusProbe {
    enum Outcome: Equatable, Sendable {
        case loggedIn
        case loggedOut
        case timedOut
        case cancelled
        case failed
    }

    private struct Response: Decodable {
        let loggedIn: Bool
    }

    private struct Request: Hashable, Sendable {
        let binary: String
        let environment: [String: String]
        let timeout: TimeInterval
    }

    private actor Coordinator {
        private var inFlight: [Request: Task<Outcome, Never>] = [:]

        func run(
            request: Request,
            operation: @escaping @Sendable () async -> Outcome) async -> Outcome
        {
            if let task = self.inFlight[request] {
                return await task.value
            }

            let task = Task { await operation() }
            self.inFlight[request] = task
            let outcome = await task.value
            self.inFlight[request] = nil
            return outcome
        }
    }

    private static let coordinator = Coordinator()

    #if DEBUG
    typealias ProbeOverride = @Sendable (String, [String: String], TimeInterval) async -> Outcome
    @TaskLocal static var probeOverrideForTesting: ProbeOverride?
    #endif

    static func probe(
        binary: String,
        environment: [String: String],
        timeout: TimeInterval = 5) async -> Outcome
    {
        guard !Task.isCancelled else { return .cancelled }
        let request = Request(binary: binary, environment: environment, timeout: timeout)
        #if DEBUG
        let override = self.probeOverrideForTesting
        #endif
        // Keep the one bounded subprocess alive when a waiter is cancelled so other concurrent refreshes can share
        // its result. The cancelled waiter still receives `.cancelled` after the shared probe finishes.
        let outcome = await self.coordinator.run(request: request) {
            #if DEBUG
            if let override {
                return await override(binary, environment, timeout)
            }
            #endif
            return await self.runProbe(binary: binary, environment: environment, timeout: timeout)
        }
        return Task.isCancelled ? .cancelled : outcome
    }

    private static func runProbe(
        binary: String,
        environment: [String: String],
        timeout: TimeInterval) async -> Outcome
    {
        do {
            let result = try await SubprocessRunner.run(
                binary: binary,
                arguments: ["auth", "status", "--json"],
                environment: ClaudeCLISession.launchEnvironment(baseEnv: environment),
                timeout: timeout,
                standardInput: FileHandle.nullDevice,
                label: "claude-auth-status")
            guard let response = self.parseResponse(result.stdout) else { return .failed }
            return response.loggedIn ? .loggedIn : .loggedOut
        } catch is CancellationError {
            return .cancelled
        } catch let error as SubprocessRunnerError {
            if case .timedOut = error {
                return .timedOut
            }
            return .failed
        } catch {
            return .failed
        }
    }

    static func parseLoggedIn(_ output: String) -> Bool {
        self.parseResponse(output)?.loggedIn == true
    }

    private static func parseResponse(_ output: String) -> Response? {
        guard let data = output.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(Response.self, from: data)
    }
}
