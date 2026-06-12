import Foundation
import Testing
@testable import CodexBar

#if DEBUG
struct MainThreadHangWatchdogTests {
    @MainActor
    @Test
    func `breadcrumb tracks nested activity`() {
        #expect(MainThreadActivityBreadcrumb.current == nil)
        MainThreadActivityBreadcrumb.push("outer")
        MainThreadActivityBreadcrumb.push("inner")
        #expect(MainThreadActivityBreadcrumb.current == "inner")
        MainThreadActivityBreadcrumb.pop()
        #expect(MainThreadActivityBreadcrumb.current == "outer")
        MainThreadActivityBreadcrumb.pop()
        #expect(MainThreadActivityBreadcrumb.current == nil)
    }

    @Test
    func `watchdog reports a blocked main thread with the active breadcrumb`() async throws {
        let watchdog = MainThreadHangWatchdog(
            pingInterval: 0.02,
            hangThreshold: 0.05,
            sampleThreshold: 60,
            sampleCooldown: 3600)

        let reported = OSAllocatedBox<[(TimeInterval, [String])]>([])
        watchdog.onHangForTesting = { duration, activities in
            reported.append((duration, activities))
        }

        let ready = OSAllocatedBox(false)
        let gateOnce = OSAllocatedBox(true)
        let beginPing = DispatchSemaphore(value: 0)
        let pingScheduled = DispatchSemaphore(value: 0)
        watchdog.onBeforePingForTesting = {
            guard gateOnce.takeTrue() else { return }
            ready.set(true)
            beginPing.wait()
        }
        watchdog.onPingScheduledForTesting = {
            pingScheduled.signal()
        }
        watchdog.start()
        defer {
            beginPing.signal()
            pingScheduled.signal()
            watchdog.stop()
        }

        for _ in 0..<200 where !ready.get() {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(ready.get())

        let didSchedulePing = await MainActor.run {
            beginPing.signal()
            guard pingScheduled.wait(timeout: .now() + 2) == .success else { return false }
            MainThreadActivityBreadcrumb.push("testStall")
            Thread.sleep(forTimeInterval: 0.4)
            MainThreadActivityBreadcrumb.pop()
            return true
        }
        try #require(didSchedulePing)

        // Concurrent test suites stall the main thread too: a single hang report can span
        // several of them and is only delivered once the whole stall ends, so poll for our
        // synthetic stall instead of sleeping a fixed interval.
        var stallReport: (TimeInterval, [String])?
        for _ in 0..<200 {
            if let report = reported.get().first(where: { $0.1.contains("testStall") }) {
                stallReport = report
                break
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        let report = try #require(stallReport)
        #expect(report.0 >= 0.05)
    }
}

private final class OSAllocatedBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T

    init(_ value: T) {
        self.value = value
    }

    func set(_ newValue: T) {
        self.lock.lock()
        self.value = newValue
        self.lock.unlock()
    }

    func get() -> T {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.value
    }
}

extension OSAllocatedBox {
    func append<Element>(_ element: Element) where T == [Element] {
        self.lock.lock()
        self.value.append(element)
        self.lock.unlock()
    }

    func takeTrue() -> Bool where T == Bool {
        self.lock.lock()
        defer { self.lock.unlock() }
        guard self.value else { return false }
        self.value = false
        return true
    }
}
#endif
