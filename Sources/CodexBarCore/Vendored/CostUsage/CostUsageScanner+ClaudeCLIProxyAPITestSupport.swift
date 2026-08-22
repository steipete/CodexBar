extension CostUsageScanner {
    final class ClaudeCLIProxyAPIAttributionCaptureObserverStore: @unchecked Sendable {
        let observer: () -> Void

        init(observer: @escaping () -> Void) {
            self.observer = observer
        }
    }

    @TaskLocal static var claudeCLIProxyAPIAttributionCaptureObserverStore:
        ClaudeCLIProxyAPIAttributionCaptureObserverStore?

    static func withClaudeCLIProxyAPIAttributionCaptureObserverForTesting<T>(
        _ observer: @escaping () -> Void,
        operation: () throws -> T) rethrows -> T
    {
        try self.$claudeCLIProxyAPIAttributionCaptureObserverStore.withValue(.init(observer: observer)) {
            try operation()
        }
    }
}
