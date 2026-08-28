import Foundation
@testable import CodexBarCLI

func makeServeTestCache() -> (ServeTestWallClock, CLIServeResponseCache) {
    let wallClock = ServeTestWallClock()
    return (wallClock, CLIServeResponseCache(wallClock: wallClock.now))
}

final class ServeTestWallClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date = Date(timeIntervalSince1970: 1000)

    func now() -> Date {
        self.lock.withLock { self.date }
    }

    func advance(by interval: TimeInterval) {
        self.lock.withLock {
            self.date = self.date.addingTimeInterval(interval)
        }
    }
}
