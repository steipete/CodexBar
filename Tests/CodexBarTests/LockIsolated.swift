import Foundation

/// A minimal `NSLock`-backed thread-safe box used by the `URLProtocol` test stubs to hold
/// their per-test `handler` closure.
///
/// The stubs' `handler` is read on URLSession's background thread (`canInit` / `startLoading`)
/// while tests assign it from another thread. Storing it here and exposing `handler` as a
/// computed property over the box serializes both the read and the write without changing any
/// call site. Before this, the stubs used an unsynchronized `nonisolated(unsafe) static var`,
/// which ThreadSanitizer reports as a data race under parallel Swift Testing.
final class LockIsolated<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value

    init(_ value: Value) {
        self.storage = value
    }

    var value: Value {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.storage
    }

    func setValue(_ value: Value) {
        self.lock.lock()
        defer { self.lock.unlock() }
        self.storage = value
    }
}
