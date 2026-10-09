import CodexBarCore
import Foundation
import Observation

struct SpendToolDetailsKey: Equatable {
    let operation: SessionToolOperation
    let source: SessionToolActivitySource
    let modified: Date
    let size: UInt64
    let fileNumber: UInt64
    let expanded: Bool
    let hidden: Bool

    var canRead: Bool {
        self.expanded && !self.hidden
    }
}

@MainActor
@Observable
final class SpendToolDetailsModel {
    private var key: SpendToolDetailsKey?
    private var value: SessionToolOperationDetails?
    private var error = false
    private var generation = 0

    func details(for key: SpendToolDetailsKey) -> SessionToolOperationDetails? {
        key.canRead && self.key == key ? self.value : nil
    }

    func failed(for key: SpendToolDetailsKey) -> Bool {
        key.canRead && self.key == key && self.error
    }

    func load(key: SpendToolDetailsKey, read: () async throws -> SessionToolOperationDetails) async {
        guard !Task.isCancelled else { return }
        self.generation &+= 1
        let generation = self.generation
        self.key = nil
        self.value = nil
        self.error = false
        guard key.canRead, !Task.isCancelled else { return }
        self.key = key
        do {
            let value = try await read()
            guard generation == self.generation, !Task.isCancelled else { return }
            self.value = value
        } catch {
            guard generation == self.generation, !Task.isCancelled, !(error is CancellationError) else { return }
            self.error = true
        }
    }
}
