import Foundation
import Testing
@testable import CodexBar

#if DEBUG
@Suite(.serialized)
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
    func `watchdog reports an unsynchronized main thread stall`() async throws {
        let watchdog = MainThreadHangWatchdog(
            pingInterval: 0.01,
            hangThreshold: 0.05,
            sampleThreshold: 60,
            sampleCooldown: 3600)

        let reported = OSAllocatedBox<[(TimeInterval, [String])]>([])
        watchdog.onHangForTesting = { duration, activities in
            reported.append((duration, activities))
        }

        watchdog.start()
        defer { watchdog.stop() }

        try await Task.sleep(for: .milliseconds(75))
        await MainActor.run {
            MainThreadActivityBreadcrumb.push("testStall")
            Thread.sleep(forTimeInterval: 0.25)
            MainThreadActivityBreadcrumb.pop()
        }

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

    @Test
    func `sample capture cannot inflate reported hang duration`() throws {
        let sampleRequested = OSAllocatedBox(false)
        let watchdog = MainThreadHangWatchdog(
            pingInterval: 0.01,
            hangThreshold: 0.03,
            sampleThreshold: 0.05,
            sampleCooldown: 3600,
            sampleCaptureOverride: {
                sampleRequested.set(true)
                Thread.sleep(forTimeInterval: 1)
                return "/tmp/codexbar-watchdog-test-sample.txt"
            })

        let reported = OSAllocatedBox<[(TimeInterval, [String])]>([])
        watchdog.onHangForTesting = { duration, activities in
            reported.append((duration, activities))
        }

        MainThreadActivityBreadcrumb.push("sampledStall")
        watchdog.traceHangForTesting(responseDelay: 0.05, waitForSampleAttempt: true)
        MainThreadActivityBreadcrumb.pop()

        let report = try #require(reported.get().first)
        #expect(sampleRequested.get())
        #expect(report.1.contains("sampledStall"))
        #expect(report.0 >= 0.03)
        #expect(report.0 < 0.75)
    }

    @Test
    func `failed sample capture is attempted once per hang`() {
        let attempts = OSAllocatedBox(0)
        let watchdog = MainThreadHangWatchdog(
            pingInterval: 0.01,
            hangThreshold: 0.01,
            sampleThreshold: 0,
            sampleCooldown: 3600,
            sampleCaptureOverride: {
                attempts.withValue { $0 += 1 }
                return nil
            })

        watchdog.traceHangForTesting(responseDelay: 0.05, waitForSampleAttempt: true)

        #expect(attempts.get() == 1)
    }

    @Test
    func `missed sample window does not consume cooldown`() {
        let attempts = OSAllocatedBox(0)
        let watchdog = MainThreadHangWatchdog(
            pingInterval: 0.01,
            hangThreshold: 0.01,
            sampleThreshold: 0.02,
            sampleCooldown: 3600,
            sampleCaptureOverride: {
                attempts.withValue { $0 += 1 }
                return nil
            })

        watchdog.traceHangForTesting(responseDelay: 0.05, responseBeforeTrace: true)
        #expect(attempts.get() == 0)

        watchdog.traceHangForTesting(responseDelay: 0.05, waitForSampleAttempt: true)
        #expect(attempts.get() == 1)
    }

    @Test
    func `cooldown blocked hang samples when cooldown expires`() {
        let attempts = OSAllocatedBox(0)
        let watchdog = MainThreadHangWatchdog(
            pingInterval: 0.01,
            hangThreshold: 0.01,
            sampleThreshold: 0,
            sampleCooldown: 0.2,
            sampleCaptureOverride: {
                attempts.withValue { $0 += 1 }
                return nil
            })

        watchdog.traceHangForTesting(responseDelay: 0.05, waitForSampleAttempt: true)
        watchdog.traceHangForTesting(responseDelay: 1)

        #expect(attempts.get() == 2)
    }
}
#endif

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

    func withValue(_ body: (inout T) -> Void) {
        self.lock.lock()
        body(&self.value)
        self.lock.unlock()
    }
}
