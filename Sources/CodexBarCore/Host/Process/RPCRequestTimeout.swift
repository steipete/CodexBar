import Foundation

enum RPCRequestTimeout {
    @TaskLocal static var sleep: @Sendable (TimeInterval) async throws -> Void = { seconds in
        try await Task.sleep(for: .seconds(seconds))
    }

    private enum Result<Value: Sendable>: Sendable {
        case value(Value)
        case timedOut
    }

    static func run<Value: Sendable>(
        seconds: TimeInterval,
        timeoutError: any Error,
        onTimeout: @Sendable () -> Void,
        operation: @escaping @Sendable () async throws -> Value) async throws -> Value
    {
        try await withThrowingTaskGroup(of: Result<Value>.self) { group in
            group.addTask { try await .value(operation()) }
            group.addTask {
                try await self.sleep(seconds)
                return .timedOut
            }
            guard let result = try await group.next() else { throw timeoutError }
            group.cancelAll()
            switch result {
            case let .value(value):
                return value
            case .timedOut:
                // Select the timeout before teardown can produce a competing stdout EOF.
                onTimeout()
                throw timeoutError
            }
        }
    }
}
