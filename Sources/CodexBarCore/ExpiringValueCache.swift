import Foundation

final class ExpiringValueCache<Value: Sendable>: @unchecked Sendable {
    private let ttl: TimeInterval
    private let lock = NSLock()
    private var entry: (value: Value, expiresAt: Date)?

    init(ttl: TimeInterval) {
        self.ttl = ttl
    }

    func load(now: Date) -> Value? {
        self.lock.lock()
        defer { self.lock.unlock() }
        guard let entry = self.entry else { return nil }
        guard entry.expiresAt > now else {
            self.entry = nil
            return nil
        }
        return entry.value
    }

    func store(_ value: Value, now: Date) {
        self.lock.lock()
        defer { self.lock.unlock() }
        self.entry = (value: value, expiresAt: now.addingTimeInterval(self.ttl))
    }

    func invalidate() {
        self.lock.lock()
        defer { self.lock.unlock() }
        self.entry = nil
    }
}
