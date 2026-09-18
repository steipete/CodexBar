import Foundation
import Testing
@testable import CodexBarCore

struct AsyncOperationGateTests {
    @Test
    func `cancelled work is rejected while cleanup may still acquire the resource`() async {
        let gate = AsyncOperationGate()
        let id = UUID()
        let result = await Task {
            withUnsafeCurrentTask { $0?.cancel() }
            let rejected = await gate.acquire(id: id)
            let cleanupAcquired = await gate.acquire(id: id, rejectIfCancelled: false)
            await gate.release(id: id)
            return (rejected, cleanupAcquired)
        }.value
        #expect(!result.0)
        #expect(result.1)
        #expect(await gate.acquire(id: id))
        await gate.release(id: id)
    }
}
