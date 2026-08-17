import AppKit
import CoreGraphics
import Foundation
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers

/// Self-driving diagnostic for provider tab-switch rendering artifacts. Inert
/// unless `CODEXBAR_FLICKER_PROBE_DIR` is set at launch. When armed it opens the
/// merged menu, switches provider tabs programmatically, and captures the menu
/// window's *own* composited frames plus a window-frame timeline for offline
/// analysis.
///
/// Two quirks shape the implementation:
/// - `openMenuFromShortcut` blocks in NSMenu's synchronous tracking loop, where
///   Swift Concurrency main-actor jobs do not run; all main-thread driving uses
///   a common-modes `Timer`.
/// - The interesting frames appear while the main thread is busy rebuilding the
///   menu, so captures run on a background thread: ScreenCaptureKit reads the
///   WindowServer composite without touching AppKit.
@MainActor
enum MenuSwitchFlickerProbe {
    private nonisolated static let processStart = DispatchTime.now()

    /// Appends timestamped diagnostic lines from production code paths while the
    /// probe env var is set; inert otherwise.
    nonisolated static func debugLog(_ line: @autoclosure () -> String) {
        guard let dir = ProcessInfo.processInfo.environment["CODEXBAR_FLICKER_PROBE_DIR"],
              !dir.isEmpty else { return }
        let url = URL(fileURLWithPath: dir).appendingPathComponent("padding-log.txt")
        // Read the start anchor before now(): the lazy static initializes on first
        // access, so the reverse order makes start > now and underflows UInt64.
        let startNs = self.processStart.uptimeNanoseconds
        let nowNs = DispatchTime.now().uptimeNanoseconds
        let elapsedMs = nowNs >= startNs ? Double(nowNs - startNs) / 1_000_000 : 0
        let text = String(format: "[%9.1fms] ", elapsedMs) + line() + "\n"
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(text.utf8))
            try? handle.close()
        } else {
            try? text.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    /// In-flight sessions must be strongly owned here: an unretained
    /// `ProbeSession(...).begin()` temporary lets the release-mode optimizer
    /// deallocate the session at creation ("weak reference will always be nil"),
    /// so the driving timer's `[weak self]` never fires and the probe records
    /// nothing. Sessions unregister themselves in `finish()`.
    private(set) static var activeSessions: [ProbeSession] = []

    static func startIfRequested(controller: StatusItemController) {
        guard let dir = ProcessInfo.processInfo.environment["CODEXBAR_FLICKER_PROBE_DIR"],
              !dir.isEmpty else { return }
        let directory = URL(fileURLWithPath: dir, isDirectory: true)
        // "hold" mode: open the menu and record for 30s without self-switching,
        // so an external driver can exercise the real pointer path with
        // synthesized mouse clicks. Default mode self-switches via the keyboard
        // path across two sessions (the second verifies open-time behavior with
        // carried-over state such as the stable-height session floor).
        let holdMode = ProcessInfo.processInfo.environment["CODEXBAR_FLICKER_PROBE_MODE"] == "hold"
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
            self.beginRetainedSession(controller: controller, directory: directory, holdMode: holdMode)
            guard !holdMode else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                self.beginRetainedSession(
                    controller: controller,
                    directory: directory.appendingPathComponent("second"),
                    holdMode: false)
            }
        }
    }

    static func beginRetainedSession(
        controller: StatusItemController,
        directory: URL,
        holdMode: Bool,
        configuration: ProbeSession.Configuration = ProbeSession.Configuration())
    {
        let session = ProbeSession(
            controller: controller,
            directory: directory,
            holdMode: holdMode,
            configuration: configuration)
        self.activeSessions.append(session)
        session.begin()
    }

    static func endSession(_ session: ProbeSession) {
        self.activeSessions.removeAll { $0 === session }
    }

    /// Background frame grabber: samples the window's WindowServer composite and
    /// bounds on a dedicated thread so main-thread stalls cannot hide frames.
    /// Frames are encoded to disk immediately — retaining full-resolution
    /// captures in memory would grow to gigabytes over a session — so only the
    /// lightweight bounds timeline is kept in memory.
    final class BackgroundFrameGrabber: @unchecked Sendable {
        struct Sample {
            let elapsedMs: Double
            let bounds: CGRect
            let wroteFrame: Bool
        }

        private static let maxFrameCount = 2000

        private let windowID: CGWindowID
        private let start: DispatchTime
        private let directory: URL
        private let lock = NSLock()
        private var storage: [Sample] = []
        private var frameIndex = 0
        private var running = true
        private var contentFilter: SCContentFilter?
        private var contentFilterLookupFailed = false
        private var captureInFlight = false

        init(windowID: CGWindowID, start: DispatchTime, directory: URL) {
            self.windowID = windowID
            self.start = start
            self.directory = directory
            self.storage.reserveCapacity(Self.maxFrameCount)
            Thread.detachNewThread { [weak self] in
                Thread.current.name = "MenuSwitchFlickerProbe.grabber"
                self?.loop()
            }
        }

        func stop() -> [Sample] {
            self.lock.lock()
            self.running = false
            let result = self.storage
            self.lock.unlock()
            return result
        }

        private func loop() {
            while true {
                self.lock.lock()
                let keepRunning = self.running
                let index = self.frameIndex
                self.lock.unlock()
                guard keepRunning, index < Self.maxFrameCount else { return }
                let elapsed = Double(DispatchTime.now().uptimeNanoseconds - self.start.uptimeNanoseconds)
                    / 1_000_000
                let bounds = self.currentBounds() ?? .null
                let wroteFrame = self.captureCompositeIfPossible(index: index, elapsed: elapsed)
                self.lock.lock()
                self.frameIndex += 1
                self.storage.append(Sample(elapsedMs: elapsed, bounds: bounds, wroteFrame: wroteFrame))
                self.lock.unlock()
                usleep(3000)
            }
        }

        private func captureCompositeIfPossible(index: Int, elapsed: Double) -> Bool {
            self.lock.lock()
            let alreadyInFlight = self.captureInFlight
            self.lock.unlock()
            guard !alreadyInFlight, let filter = self.resolvedContentFilter() else {
                return false
            }

            let configuration = SCStreamConfiguration()
            configuration.showsCursor = false
            if let bounds = self.currentBounds(), bounds.width > 1, bounds.height > 1 {
                configuration.width = Int(bounds.width * 2)
                configuration.height = Int(bounds.height * 2)
            }

            self.lock.lock()
            self.captureInFlight = true
            self.lock.unlock()
            let directory = self.directory
            SCScreenshotManager
                .captureImage(contentFilter: filter, configuration: configuration) { [weak self] image, _ in
                    if let image {
                        let name = String(format: "frame-%04d-%07.1fms.png", index, elapsed)
                        MenuSwitchFlickerProbe.writePNG(image, to: directory.appendingPathComponent(name))
                    }
                    self?.lock.lock()
                    self?.captureInFlight = false
                    self?.lock.unlock()
                }
            return true
        }

        private func resolvedContentFilter() -> SCContentFilter? {
            self.lock.lock()
            if let contentFilter = self.contentFilter {
                self.lock.unlock()
                return contentFilter
            }
            let lookupFailed = self.contentFilterLookupFailed
            self.lock.unlock()
            if lookupFailed { return nil }

            let windowID = self.windowID
            let semaphore = DispatchSemaphore(value: 0)
            SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: false) { [lock] content, _ in
                if let window = content?.windows.first(where: { $0.windowID == windowID }) {
                    lock.lock()
                    self.contentFilter = SCContentFilter(desktopIndependentWindow: window)
                    lock.unlock()
                }
                semaphore.signal()
            }
            if semaphore.wait(timeout: .now() + .milliseconds(250)) == .timedOut {
                self.lock.lock()
                self.contentFilterLookupFailed = true
                self.lock.unlock()
                return nil
            }

            self.lock.lock()
            let filter = self.contentFilter
            if filter == nil {
                self.contentFilterLookupFailed = true
            }
            self.lock.unlock()
            return filter
        }

        private func currentBounds() -> CGRect? {
            guard let info = CGWindowListCopyWindowInfo(
                .optionIncludingWindow,
                self.windowID) as? [[String: Any]],
                let record = info.first,
                let boundsDict = record[kCGWindowBounds as String] as? [String: CGFloat]
            else { return nil }
            return CGRect(
                x: boundsDict["X"] ?? 0,
                y: boundsDict["Y"] ?? 0,
                width: boundsDict["Width"] ?? 0,
                height: boundsDict["Height"] ?? 0)
        }
    }

    @MainActor
    final class ProbeSession {
        /// Timing and menu-opening seams. Production uses the defaults; tests
        /// shorten the schedule and substitute a non-blocking menu opener so the
        /// session can run against a synthetic menu without NSMenu tracking.
        struct Configuration {
            /// Three away/back cycles give slower external captures several chances
            /// to land on any transient artifact. Always ends on the original segment.
            var switchScheduleMs: [Int] = [400, 1000, 1600, 2200, 2800, 3400]
            var sessionEndMs = 4200
            var holdSessionEndMs = 30000
            /// Replaces `controller.openMenuFromShortcut()`, which blocks in
            /// NSMenu's synchronous tracking loop until the session cancels it.
            /// A substitute must likewise pump the main run loop until the
            /// session's timer stops, then return.
            var openMenu: (@MainActor () -> Void)?
        }

        private let controller: StatusItemController
        private let directory: URL
        private let holdMode: Bool
        private let configuration: Configuration
        private(set) var timer: Timer?
        private var log: [String] = []
        private var startedAt: DispatchTime?
        private var switchScheduleIndex = 0
        private var searchTicks = 0
        private weak var menu: NSMenu?
        private var grabber: BackgroundFrameGrabber?
        private var originalSegment: Int?
        private var targetSegment: Int?

        init(
            controller: StatusItemController,
            directory: URL,
            holdMode: Bool = false,
            configuration: Configuration = Configuration())
        {
            self.controller = controller
            self.directory = directory
            self.holdMode = holdMode
            self.configuration = configuration
        }

        func begin() {
            try? FileManager.default.createDirectory(
                at: self.directory,
                withIntermediateDirectories: true)
            let timer = Timer(timeInterval: 0.008, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.tick()
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
            // Blocks in menu tracking until `cancelTracking()`; the timer keeps firing.
            if let openMenu = self.configuration.openMenu {
                openMenu()
            } else {
                self.controller.openMenuFromShortcut()
            }
            self.finish()
        }

        private func tick() {
            guard let startedAt = self.startedAtOrLocateMenu() else { return }
            let now = Int((DispatchTime.now().uptimeNanoseconds - startedAt.uptimeNanoseconds) / 1_000_000)
            if !self.holdMode,
               self.switchScheduleIndex < self.configuration.switchScheduleMs.count,
               now >= self.configuration.switchScheduleMs[self.switchScheduleIndex]
            {
                let switchIndex = self.switchScheduleIndex
                self.switchScheduleIndex += 1
                // Cycle through overview (segment 0) too so full-rebuild transitions
                // are exercised alongside cached swaps.
                let cycle: [Int?] = [
                    self.targetSegment,
                    0,
                    self.originalSegment,
                    0,
                    self.targetSegment,
                    self.originalSegment,
                ]
                let segment = cycle[switchIndex % cycle.count]
                let handled = segment.map { self.switchSegment($0) } ?? false
                self.log.append("switch#\(switchIndex) to segment \(String(describing: segment)) " +
                    "at \(now)ms handled=\(handled)")
                return
            }
            let endMs = self.holdMode
                ? self.configuration.holdSessionEndMs
                : self.configuration.sessionEndMs
            if now >= endMs {
                self.timer?.invalidate()
                self.timer = nil
                self.menu?.cancelTracking()
            }
        }

        private func startedAtOrLocateMenu() -> DispatchTime? {
            if let startedAt = self.startedAt { return startedAt }
            self.searchTicks += 1
            if let menu = self.controller.openMenus.values.first,
               menu.items.first?.view is ProviderSwitcherView,
               let window = menu.items.compactMap(\.view?.window).first
            {
                self.menu = menu
                self.resolveSegments()
                let start = DispatchTime.now()
                self.startedAt = start
                self.grabber = BackgroundFrameGrabber(
                    windowID: CGWindowID(window.windowNumber),
                    start: start,
                    directory: self.directory)
                self.log.append("menu located, windowNumber=\(window.windowNumber) " +
                    "frame=\(window.frame) original=\(String(describing: self.originalSegment)) " +
                    "target=\(String(describing: self.targetSegment))")
                // Export CG (top-left origin) bounds for external click drivers;
                // other processes cannot enumerate this menu window.
                let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
                let frame = window.frame
                let cgY = primaryHeight - frame.maxY
                let boundsLine = "\(Int(frame.minX)) \(Int(cgY)) \(Int(frame.width)) \(Int(frame.height))\n"
                try? boundsLine.write(
                    to: self.directory.appendingPathComponent("menu-bounds.txt"),
                    atomically: true,
                    encoding: .utf8)
                return start
            }
            if self.searchTicks > 1200 {
                self.log.append("gave up locating menu after \(self.searchTicks) ticks")
                self.timer?.invalidate()
                self.timer = nil
                self.controller.openMenus.values.first?.cancelTracking()
            }
            return nil
        }

        /// Segment order mirrors the switcher: optional Overview first, then the
        /// display providers. Picks the first provider segment that is not the
        /// current selection so the probe performs a real switch, and restores
        /// the original selection afterwards.
        private func resolveSegments() {
            let enabledProviders = self.controller.store.enabledFirstPartyProvidersForDisplay()
            let includesOverview = self.controller.includesOverviewTab(enabledProviders: enabledProviders)
            let selection = self.controller.resolvedSwitcherSelection(
                enabledProviders: enabledProviders,
                includesOverview: includesOverview)
            var segments: [ProviderSwitcherSelection] = enabledProviders.map { .provider($0.instanceID) }
            if includesOverview {
                segments.insert(.overview, at: 0)
            }
            self.originalSegment = segments.firstIndex(of: selection)
            self.targetSegment = segments.firstIndex { candidate in
                candidate != selection && candidate != .overview
            }
        }

        private func switchSegment(_ index: Int) -> Bool {
            guard let switcher = self.menu?.items.first?.view as? ProviderSwitcherView else { return false }
            return switcher.handleKeyboardSelection(at: index)
        }

        private func finish() {
            self.timer?.invalidate()
            self.timer = nil
            let samples = self.grabber?.stop() ?? []
            self.log.append("captured \(samples.count) samples")
            var previousBounds = CGRect.null
            for sample in samples where sample.bounds != previousBounds {
                previousBounds = sample.bounds
                self.log.append(String(
                    format: "windowBounds @%.1fms -> %@",
                    sample.elapsedMs,
                    String(describing: sample.bounds)))
            }
            let nilFrames = samples.count(where: { !$0.wroteFrame })
            self.log.append("nil captures: \(nilFrames)")
            let text = self.log.joined(separator: "\n") + "\n"
            try? text.write(
                to: self.directory.appendingPathComponent("probe-log.txt"),
                atomically: true,
                encoding: .utf8)
            MenuSwitchFlickerProbe.endSession(self)
        }
    }

    nonisolated static func writePNG(_ image: CGImage, to url: URL) {
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            UTType.png.identifier as CFString,
            1,
            nil) else { return }
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
    }
}
