import CodexBarCore
import Foundation
import Testing

@Suite
struct CostUsageScanExecutorLinuxTests {
    @Test
    func returnsWorkValue() async throws {
        let value = try await CostUsageScanExecutor.run { _ in 42 }
        #expect(value == 42)
    }

    @Test
    func cancelledTaskThrowsCancellationError() async {
        let task = Task {
            try await CostUsageScanExecutor.run { checkCancellation in
                while true {
                    try checkCancellation()
                    Thread.sleep(forTimeInterval: 0.005)
                }
            }
        }
        task.cancel()

        await #expect(throws: CancellationError.self) {
            try await task.value
        }
    }
}
