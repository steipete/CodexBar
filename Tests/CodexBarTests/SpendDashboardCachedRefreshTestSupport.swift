import CodexBarCore
import Foundation
@testable import CodexBar

@MainActor
final class CachedRefreshControllerBox {
    var controller: SpendDashboardController?
}

actor CachedRefreshModeRecorder {
    private(set) var values: [SpendDashboardRequestBuildMode] = []

    func append(_ mode: SpendDashboardRequestBuildMode) {
        self.values.append(mode)
    }
}

actor CachedRefreshCodexLoadRecorder {
    private(set) var contexts: [CodexSpendSnapshotLoadContext] = []

    func record(_ context: CodexSpendSnapshotLoadContext) {
        self.contexts.append(context)
    }
}

actor CachedRefreshRequestGate {
    private var continuation: CheckedContinuation<Void, Never>?

    var isSuspended: Bool {
        self.continuation != nil
    }

    func suspend() async {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func resume() {
        self.continuation?.resume()
        self.continuation = nil
    }
}

actor CachedRefreshResultGate {
    private var continuations: [CheckedContinuation<SpendDashboardLoadResult, Never>] = []

    var pendingCount: Int {
        self.continuations.count
    }

    func load(_ request: SpendDashboardLoadRequest) async -> SpendDashboardLoadResult {
        _ = request
        return await withCheckedContinuation { continuation in
            self.continuations.append(continuation)
        }
    }

    func resume(at index: Int, result: SpendDashboardLoadResult) {
        self.continuations.remove(at: index).resume(returning: result)
    }
}

actor CachedRefreshLoaderGate {
    private var continuations: [CheckedContinuation<SpendDashboardLoadResult, Never>] = []

    var pendingCount: Int {
        self.continuations.count
    }

    func load(_ request: SpendDashboardLoadRequest) async -> SpendDashboardLoadResult {
        _ = request
        return await withCheckedContinuation { continuation in
            self.continuations.append(continuation)
        }
    }

    func resume(at index: Int, result: SpendDashboardLoadResult) {
        self.continuations.remove(at: index).resume(returning: result)
    }
}
