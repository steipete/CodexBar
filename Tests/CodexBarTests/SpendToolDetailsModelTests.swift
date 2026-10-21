import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

@MainActor
struct SpendToolDetailsModelTests {
    @Test
    func `new file identities suppress old details before another load starts`() async {
        let model = SpendToolDetailsModel()
        let first = Self.key(fileNumber: 1)
        let next = Self.key(fileNumber: 2)
        await model.load(key: first) { Self.details("first") }
        #expect(model.details(for: first)?.output == "first")
        #expect(model.details(for: next) == nil)
        #expect(!model.failed(for: next))
        await model.load(key: next) { Self.details("next") }
        #expect(model.details(for: first) == nil)
        #expect(model.details(for: next)?.output == "next")
    }

    @Test
    func `late completion cannot replace a newer result or produce an error`() async {
        let model = SpendToolDetailsModel()
        let gate = Gate()
        let old = Self.key(fileNumber: 1)
        let new = Self.key(fileNumber: 2)
        let pending = Task { await model.load(key: old) { try await gate.wait() } }
        await gate.arrived()
        await model.load(key: new) { Self.details("new") }
        gate.release(throwing: SessionToolActivityError.sourceChanged)
        await pending.value
        #expect(model.details(for: new)?.output == "new")
        #expect(!model.failed(for: new))
        #expect(model.details(for: old) == nil)
    }

    @Test
    func `privacy and collapse release bodies and discard in flight completion`() async {
        for hidden in [false, true] {
            let model = SpendToolDetailsModel()
            let key = Self.key(fileNumber: 1)
            let gate = Gate()
            let pending = Task { await model.load(key: key) { try await gate.wait() } }
            await gate.arrived()
            let inactive = Self.key(fileNumber: 1, expanded: hidden, hidden: hidden)
            #expect(model.details(for: inactive) == nil)
            await model.load(key: inactive) {
                Issue.record("Inactive detail must not read the body")
                return Self.details("unexpected")
            }
            gate.release(returning: Self.details("old"))
            await pending.value
            #expect(model.details(for: key) == nil)
            #expect(!model.failed(for: key))
            await model.load(key: key) { Self.details("restored") }
            #expect(model.details(for: key)?.output == "restored")
        }
    }

    @Test
    func `cancelled loads do not publish results or changed file warnings`() async {
        let model = SpendToolDetailsModel()
        let key = Self.key(fileNumber: 1)
        let gate = Gate()
        let pending = Task { await model.load(key: key) { try await gate.wait() } }
        await gate.arrived()
        pending.cancel()
        gate.release(returning: Self.details("cancelled"))
        await pending.value
        #expect(model.details(for: key) == nil)
        #expect(!model.failed(for: key))
        await model.load(key: key) { throw CancellationError() }
        #expect(!model.failed(for: key))
        await model.load(key: key) { throw SessionToolActivityError.sourceChanged }
        #expect(model.failed(for: key))
        await model.load(key: key) { Self.details("retry") }
        #expect(model.details(for: key)?.output == "retry")
        #expect(!model.failed(for: key))
        let alreadyCancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            await model.load(key: Self.key(fileNumber: 2)) {
                Issue.record("An already cancelled task must not read")
                return Self.details("unexpected")
            }
        }
        await alreadyCancelled.value
        #expect(model.details(for: key)?.output == "retry")
    }

    private static func key(fileNumber: UInt64, expanded: Bool = true, hidden: Bool = false) -> SpendToolDetailsKey {
        SpendToolDetailsKey(
            operation: SessionToolOperation(
                id: .init(threadID: "owned", turnID: "turn", itemID: "item"),
                kind: .command,
                name: "CommandExecution",
                preview: "example",
                completedAt: Date(timeIntervalSince1970: 0),
                outcome: .completed,
                exitCode: 0,
                durationMilliseconds: 1,
                timing: .native,
                recordOffset: 0,
                recordLength: 100),
            source: .init(fileURL: URL(fileURLWithPath: "/synthetic/rollout.jsonl"), sessionID: "owned"),
            modified: Date(timeIntervalSince1970: 0),
            size: 100,
            fileNumber: fileNumber,
            expanded: expanded,
            hidden: hidden)
    }

    private static func details(_ output: String) -> SessionToolOperationDetails {
        SessionToolOperationDetails(input: "example", output: output, isTruncated: false)
    }

    @MainActor
    private final class Gate {
        private var continuation: CheckedContinuation<SessionToolOperationDetails, any Error>?
        private var arrival: CheckedContinuation<Void, Never>?

        func wait() async throws -> SessionToolOperationDetails {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                self.arrival?.resume()
                self.arrival = nil
            }
        }

        func arrived() async {
            if self.continuation != nil { return }
            await withCheckedContinuation { self.arrival = $0 }
        }

        func release(returning details: SessionToolOperationDetails) {
            self.continuation?.resume(returning: details)
            self.continuation = nil
        }

        func release(throwing error: any Error) {
            self.continuation?.resume(throwing: error)
            self.continuation = nil
        }
    }
}
