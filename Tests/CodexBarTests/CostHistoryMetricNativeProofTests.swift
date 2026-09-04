import AppKit
import CodexBarCore
import CoreGraphics
import Foundation
import SwiftUI
import XCTest
@testable import CodexBar

/// Opt-in native NSMenu regression proof with synthetic cost data and no provider transports.
@MainActor
final class CostHistoryMetricNativeProofTests: XCTestCase {
    func test_metricSwitchDoesNotScrollNativeMenus() throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["CODEXBAR_COST_METRIC_NATIVE_PROOF"] == "1" else {
            throw XCTSkip("Set CODEXBAR_COST_METRIC_NATIVE_PROOF=1 to run the native menu proof.")
        }
        guard environment["CODEXBAR_SUPPRESS_TEST_KEYCHAIN_ACCESS"] == "1",
              environment[CodexCredentialFileAccess.isolationEnvironmentKey] == "1",
              environment["CODEXBAR_TEST_SESSION_FILE_ISOLATION"] == "1",
              environment["CODEXBAR_ALLOW_TEST_KEYCHAIN_ACCESS"] != "1"
        else {
            return XCTFail("Native proof requires credential, Keychain, and session isolation.")
        }

        let application = NSApplication.shared
        guard application.delegate == nil, UserDefaults.standard.object(forKey: "NSOpen") == nil else {
            return XCTFail("Native proof requires a standalone test application.")
        }
        let previousPolicy = application.activationPolicy()
        let previousApplication = NSWorkspace.shared.frontmostApplication
        let host = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 160),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false)
        host.title = "CodexBar Cost Metric Proof"
        host.isReleasedWhenClosed = false
        guard let screen = host.screen ?? NSScreen.main else {
            return XCTFail("Native metric proof requires an attached display.")
        }
        defer {
            host.close()
            _ = application.setActivationPolicy(previousPolicy)
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier {
                previousApplication?.activate()
            }
        }
        // Both menu topologies share one application lifecycle. Relaunching AppKit between
        // popups can deliver activation changes into the next menu's tracking loop.
        XCTAssertTrue(application.setActivationPolicy(.regular))
        application.finishLaunching()
        host.makeKeyAndOrderFront(nil)
        application.activate(ignoringOtherApps: true)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.15))

        for nested in [false, true] {
            let fixture = makeCostMetricProofFixture()
            let chartItem = NSMenuItem()
            chartItem.view = fixture.viewport
            chartItem.isEnabled = true
            let chartMenu = NSMenu()
            chartMenu.autoenablesItems = false
            chartMenu.addItem(chartItem)
            let parentItem = NSMenuItem(title: "Cost history", action: nil, keyEquivalent: "")
            parentItem.isEnabled = true
            parentItem.submenu = chartMenu
            let rootMenu = StatusItemMenu()
            rootMenu.autoenablesItems = false
            rootMenu.addItem(parentItem)
            let popupPoint = NSPoint(x: screen.visibleFrame.midX, y: screen.visibleFrame.maxY)
            let driver = CostMetricProofDriver(
                hosting: fixture.hosting,
                menu: chartMenu,
                rootMenu: nested ? rootMenu : nil,
                rootPopupPoint: nested ? popupPoint : nil,
                verifyWheel: true)
            driver.start()
            (nested ? rootMenu : chartMenu).popUp(positioning: nil, at: popupPoint, in: nil)
            driver.stop()

            if let failure = driver.failure {
                XCTFail("\(nested ? "Nested" : "Standalone") menu: \(failure)")
            }
            XCTAssertTrue(driver.topEdgeConstraintVerified)
            XCTAssertTrue(driver.verticalConstraintVerified)
            XCTAssertTrue(driver.metricControlClearanceVerified)
            XCTAssertTrue(driver.chartHoverClearanceVerified)
            XCTAssertTrue(driver.chartPointerVerified)
            XCTAssertEqual(driver.pointerSegments, [1, 0])
            XCTAssertEqual(driver.selectedSegments, [1, 0])
            XCTAssertEqual(fixture.metricChanges.values, [.cost, .tokens])
            XCTAssertTrue(driver.wheelScrollVerified)
            XCTAssertFalse(driver.observedOrigins.isEmpty)
            if nested {
                XCTAssertTrue(driver.nestedPointerSent)
                XCTAssertTrue(driver.nestedSubmenuObserved)
            }
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.15))
        }
    }
}

@MainActor
private func makeCostMetricProofFixture() -> (
    hosting: MenuHostingView<AnyView>,
    viewport: CostHistoryMenuScrollView,
    metricChanges: MetricChangeRecorder)
{
    var daily: [CostUsageDailyReport.Entry] = []
    for day in 1...30 {
        let cost = Double(day) * 0.25
        let totalTokens = day * 1200
        let breakdown = CostUsageDailyReport.ModelBreakdown(
            modelName: "fixture-model",
            costUSD: cost,
            totalTokens: totalTokens)
        daily.append(CostUsageDailyReport.Entry(
            date: String(format: "2026-08-%02d", day),
            inputTokens: day * 1000,
            outputTokens: day * 200,
            totalTokens: totalTokens,
            costUSD: cost,
            modelsUsed: ["fixture-model"],
            modelBreakdowns: [breakdown]))
    }
    var projects: [CostUsageProjectBreakdown] = []
    var sessions: [CostUsageSessionBreakdown] = []
    for index in 1...5 {
        let sources = (1...3).map { sourceIndex in
            CostUsageProjectSourceBreakdown(
                name: "Fixture source \(sourceIndex)",
                path: "/tmp/codexbar-cost-proof/source-\(index)-\(sourceIndex)",
                totalTokens: sourceIndex * 1000,
                totalCostUSD: Double(sourceIndex),
                daily: [],
                modelBreakdowns: nil)
        }
        projects.append(CostUsageProjectBreakdown(
            name: "Fixture project \(index)",
            path: "/tmp/codexbar-cost-proof/project-\(index)",
            totalTokens: index * 10000,
            totalCostUSD: Double(index),
            daily: [],
            modelBreakdowns: nil,
            sources: sources))

        sessions.append(CostUsageSessionBreakdown(
            sessionID: "fixture-session-\(index)",
            lastActivity: Date(timeIntervalSince1970: TimeInterval(index)),
            inputTokens: index * 1000,
            cachedInputTokens: index * 500,
            outputTokens: index * 100,
            totalTokens: index * 1100,
            requestCount: index,
            costUSD: Double(index),
            modelBreakdowns: []))
    }
    let metricChanges = MetricChangeRecorder()
    let chart = CostHistoryChartMenuView(
        provider: .codex,
        daily: daily,
        totalCostUSD: daily.reduce(0) { $0 + ($1.costUSD ?? 0) },
        projects: projects,
        sessions: sessions,
        hidePersonalInfo: false,
        width: 400,
        onMetricChanged: { metricChanges.values.append($0) })
    // Keep the same chart controls while guaranteeing one oversized native row on any display.
    let fillerHeight = NSScreen.screens.map(\.visibleFrame.height).max() ?? 1200
    let hosting = MenuHostingView(rootView: AnyView(VStack(spacing: 0) {
        chart
        Color.clear.frame(height: fillerHeight)
    }))
    hosting.applyMeasuredHeight(width: 400, height: hosting.measuredFittingHeight(width: 400))
    let viewport = CostHistoryMenuScrollView(hosting: hosting, width: 400, maximumHeight: 620)
    return (hosting, viewport, metricChanges)
}

@MainActor
private final class MetricChangeRecorder {
    var values: [CostHistoryChartMenuView.ChartMetric] = []
}

@MainActor
private final class CostMetricProofDriver {
    private let hosting: MenuHostingView<AnyView>
    private let menu: NSMenu
    private let rootMenu: NSMenu?
    private let rootPopupPoint: NSPoint?
    private let verifyWheel: Bool
    private(set) var nestedPointerSent = false
    private var timer: Timer?
    private var stage = 0
    private var proofStartedAt = Date()
    private var stageStartedAt = Date()
    private var baselineWindowFrame: CGRect?
    private var baselineNativeOrigin: CGPoint?
    private var baselineOrigin: CGPoint?
    private var wheelBaselineOrigin: CGPoint?
    private var wheelArmedAt: Date?
    private var wheelSettledOrigin: CGPoint?
    private var boundsObservers: [NSObjectProtocol] = []
    private var wheelPosted = false
    private(set) var observedOrigins: [CGPoint] = []
    private(set) var pointerSegments: [Int] = []
    private(set) var selectedSegments: [Int] = []
    private(set) var topEdgeConstraintVerified = false
    private(set) var verticalConstraintVerified = false
    private(set) var metricControlClearanceVerified = false
    private(set) var chartHoverClearanceVerified = false
    private(set) var chartPointerVerified = false
    private(set) var wheelScrollVerified = false
    private(set) var nestedSubmenuObserved = false
    private(set) var failure: String?

    init(
        hosting: MenuHostingView<AnyView>,
        menu: NSMenu,
        rootMenu: NSMenu? = nil,
        rootPopupPoint: NSPoint? = nil,
        verifyWheel: Bool = false)
    {
        self.hosting = hosting
        self.menu = menu
        self.rootMenu = rootMenu
        self.rootPopupPoint = rootPopupPoint
        self.verifyWheel = verifyWheel
    }

    func start() {
        self.proofStartedAt = Date()
        let timer = Timer(timeInterval: 0.02, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.tick()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        self.timer?.invalidate()
        self.timer = nil
        self.boundsObservers.forEach(NotificationCenter.default.removeObserver)
        self.boundsObservers.removeAll()
    }

    private struct ProofContext {
        let control: NSSegmentedControl
        let chartHoverView: MouseLocationReader.TrackingView
        let scrollView: NSScrollView
        let origin: NSPoint
    }

    private func tick() {
        guard Date().timeIntervalSince(self.proofStartedAt) < 20 else {
            self.failure = "Native metric proof exceeded its overall deadline at stage \(self.stage)."
            self.finish()
            return
        }
        self.sendPointerToNestedParentIfNeeded()
        guard let context = self.proofContext() else {
            self.handleMissingProofContext()
            return
        }
        if self.rootMenu != nil {
            self.nestedSubmenuObserved = true
        }
        if let frame = self.baselineWindowFrame, context.scrollView.window?.frame != frame {
            self.failure = "Metric interaction moved the native menu window."
            self.finish()
            return
        }
        if let native = context.scrollView.enclosingScrollView,
           let baseline = self.baselineNativeOrigin,
           !Self.matches(native.contentView.bounds.origin, baseline)
        {
            self.failure = "Metric interaction scrolled the native ancestor."
            self.finish()
            return
        }
        if self.stage > 0, !self.wheelPosted,
           !self.requireStable(context.origin, action: "Metric interaction")
        {
            return
        }
        self.observedOrigins.append(context.origin)
        switch self.stage {
        case 0:
            self.handleInitialStage(context)
        case 1:
            self.handleChartHoverStage(context)
        case 2:
            self.handleCostHoverStage(context)
        case 3:
            self.handleCostSelectedStage(context)
        case 4:
            self.handleTokenHoverStage(context)
        case 5:
            self.handleTokenSelectedStage(context)
        case 6:
            self.handleWheelStage(context)
        default:
            self.handleStageTimeout()
        }
    }

    private func sendPointerToNestedParentIfNeeded() {
        guard let rootPopupPoint = self.rootPopupPoint, self.hosting.window == nil else { return }
        self.nestedPointerSent = true
        Self.postPointerMove(toCocoaScreen: NSPoint(x: rootPopupPoint.x, y: rootPopupPoint.y - 12))
    }

    private func proofContext() -> ProofContext? {
        guard self.hosting.window?.screen != nil,
              let control = Self.descendant(of: self.hosting, as: NSSegmentedControl.self),
              let chartHoverView = Self.descendant(of: self.hosting, as: MouseLocationReader.TrackingView.self),
              let scrollView = self.hosting.enclosingScrollView
        else {
            return nil
        }
        return ProofContext(
            control: control,
            chartHoverView: chartHoverView,
            scrollView: scrollView,
            origin: scrollView.contentView.documentVisibleRect.origin)
    }

    private func handleMissingProofContext() {
        guard Date().timeIntervalSince(self.proofStartedAt) > 5 else { return }
        self.failure = "Native metric proof could not find the picker, chart hover view, or menu scroll view."
        self.finish()
    }

    private func handleInitialStage(_ context: ProofContext) {
        guard self.verifyTopEdgeConstraint(
            context.scrollView,
            control: context.control,
            chartHoverView: context.chartHoverView)
        else { return }
        self.baselineWindowFrame = context.scrollView.window?.frame
        self.baselineNativeOrigin = context.scrollView.enclosingScrollView?.contentView.bounds.origin
        self.baselineOrigin = context.origin
        self.observeBounds(of: context.scrollView)
        self.capture("tokens", window: context.scrollView.window)
        Self.movePointer(to: context.chartHoverView)
        self.advance(to: 1)
    }

    private func handleChartHoverStage(_ context: ProofContext) {
        guard Date().timeIntervalSince(self.stageStartedAt) >= 0.25 else { return }
        guard self.verifyPointer(in: context.chartHoverView) else { return }
        self.chartPointerVerified = true
        guard self.requireStable(context.origin, action: "Hovering the chart") else { return }
        Self.movePointer(toSegment: 1, in: context.control)
        self.advance(to: 2)
    }

    private func handleCostHoverStage(_ context: ProofContext) {
        guard Date().timeIntervalSince(self.stageStartedAt) >= 0.25 else { return }
        guard self.verifyPointer(atSegment: 1, in: context.control) else { return }
        guard self.requireStable(context.origin, action: "Hovering the cost segment") else { return }
        guard self.activateSegment(1, in: context.control) else { return }
        self.advance(to: 3)
    }

    private func handleCostSelectedStage(_ context: ProofContext) {
        guard context.control.selectedSegment == 1 else { return }
        self.selectedSegments.append(1)
        guard self.requireStable(context.origin, action: "Switching to cost") else { return }
        self.capture("cost", window: context.scrollView.window)
        Self.movePointer(toSegment: 0, in: context.control)
        self.advance(to: 4)
    }

    private func handleTokenHoverStage(_ context: ProofContext) {
        guard Date().timeIntervalSince(self.stageStartedAt) >= 0.25 else { return }
        guard self.verifyPointer(atSegment: 0, in: context.control) else { return }
        guard self.requireStable(context.origin, action: "Hovering the token segment") else { return }
        guard self.activateSegment(0, in: context.control) else { return }
        self.advance(to: 5)
    }

    private func handleTokenSelectedStage(_ context: ProofContext) {
        guard context.control.selectedSegment == 0 else { return }
        self.selectedSegments.append(0)
        guard self.requireStable(context.origin, action: "Switching to tokens") else { return }
        if self.verifyWheel {
            self.advance(to: 6)
        } else {
            self.finish()
        }
    }

    private func handleWheelStage(_ context: ProofContext) {
        let elapsed = Date().timeIntervalSince(self.stageStartedAt)
        guard elapsed >= 0.06 else { return }
        if !self.wheelPosted {
            self.wheelBaselineOrigin = context.origin
            Self.movePointer(to: context.chartHoverView)
            Self.postScrollWheel(delta: -40)
            self.wheelPosted = true
            self.wheelArmedAt = Date()
            return
        }
        guard let armed = self.wheelArmedAt else { return }
        if Date().timeIntervalSince(armed) >= 0.4, self.wheelSettledOrigin == nil {
            self.wheelSettledOrigin = context.origin
        }
        guard Date().timeIntervalSince(armed) >= 1 else { return }
        self.wheelScrollVerified = !Self.matches(context.origin, self.wheelBaselineOrigin)
            && Self.matches(context.origin, self.wheelSettledOrigin)
        if !self.wheelScrollVerified {
            self.failure = "Intentional wheel scrolling immediately after metric selection was lost."
        }
        self.finish()
    }

    private func handleStageTimeout() {
        guard Date().timeIntervalSince(self.stageStartedAt) > 5 else { return }
        self.failure = "Native metric proof timed out at stage \(self.stage)."
        self.finish()
    }

    private func verifyTopEdgeConstraint(
        _ scrollView: NSScrollView,
        control: NSSegmentedControl,
        chartHoverView: NSView) -> Bool
    {
        guard let menuWindow = scrollView.window,
              let screen = menuWindow.screen,
              let documentView = scrollView.documentView
        else {
            self.failure = "Native metric proof could not resolve the menu window, display, or document view."
            self.finish()
            return false
        }

        let menuFrame = menuWindow.frame
        let visibleFrame = screen.visibleFrame
        let topEdgeDistance = abs(visibleFrame.maxY - menuFrame.maxY)
        // AppKit keeps a five-point safety inset around a constrained native menu.
        let topEdgeTolerance: CGFloat = self.rootMenu == nil ? 6 : 30
        guard topEdgeDistance <= topEdgeTolerance else {
            self.failure = "Native metric proof menu missed the display top edge by \(topEdgeDistance) points."
            self.finish()
            return false
        }
        self.topEdgeConstraintVerified = true

        let documentHeight = documentView.bounds.height
        let viewportHeight = scrollView.contentView.documentVisibleRect.height
        guard documentHeight > viewportHeight + 1 else {
            self.failure = "Native metric proof menu was not vertically constrained "
                + "(document=\(documentHeight), viewport=\(viewportHeight))."
            self.finish()
            return false
        }
        guard let native = scrollView.enclosingScrollView, let nativeDocument = native.documentView else {
            self.failure = "Native menu scroll ancestor is missing."
            self.finish()
            return false
        }
        if nativeDocument.bounds.height > native.contentView.documentVisibleRect.height + 1 {
            self.failure = "The bounded cost row still overflowed the native menu."
            self.finish()
            return false
        }
        self.verticalConstraintVerified = true

        let controlTopInWindow = control.convert(
            NSPoint(x: control.bounds.midX, y: control.bounds.maxY),
            to: nil)
        let controlTopOnScreen = menuWindow.convertPoint(toScreen: controlTopInWindow).y
        let controlTopClearance = menuFrame.maxY - controlTopOnScreen
        // The native row fits without scroll gutters; keep controls at least one control height below its edge.
        let minimumControlTopClearance = control.bounds.height
        guard controlTopClearance >= minimumControlTopClearance else {
            self.failure = "Native metric proof control remained in the menu's top scroll gutter "
                + "(clearance=\(controlTopClearance), minimum=\(minimumControlTopClearance))."
            self.finish()
            return false
        }
        self.metricControlClearanceVerified = true

        let hoverFrameInWindow = chartHoverView.convert(chartHoverView.bounds, to: nil)
        let hoverTopOnScreen = menuWindow.convertPoint(
            toScreen: NSPoint(x: hoverFrameInWindow.midX, y: hoverFrameInWindow.maxY)).y
        let hoverTopClearance = menuFrame.maxY - hoverTopOnScreen
        guard hoverTopClearance >= minimumControlTopClearance else {
            self.failure = "Native metric proof chart hover surface remained in the menu's top scroll gutter "
                + "(clearance=\(hoverTopClearance), minimum=\(minimumControlTopClearance))."
            self.finish()
            return false
        }
        self.chartHoverClearanceVerified = true
        return true
    }

    private func advance(to stage: Int) {
        self.stage = stage
        self.stageStartedAt = Date()
    }

    private func requireStable(_ origin: CGPoint, action: String) -> Bool {
        guard Self.matches(origin, self.baselineOrigin) else {
            let baseline = String(describing: self.baselineOrigin)
            self.failure = "\(action) scrolled the native menu from \(baseline) to \(origin)."
            self.finish()
            return false
        }
        return true
    }

    private func observeBounds(of scrollView: NSScrollView) {
        let clips = [scrollView.contentView, scrollView.enclosingScrollView?.contentView].compactMap(\.self)
        for clip in clips {
            clip.postsBoundsChangedNotifications = true
            let origin = clip.bounds.origin
            let isOwned = clip === scrollView.contentView
            let observer = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification, object: clip, queue: .main)
            { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, !isOwned || !self.wheelPosted else { return }
                    guard !Self.matches(clip.bounds.origin, origin) else { return }
                    self.failure = "Metric interaction transiently moved a scroll viewport."
                    self.finish()
                }
            }
            self.boundsObservers.append(observer)
        }
    }

    private func capture(_ name: String, window: NSWindow?) {
        guard let directory = ProcessInfo.processInfo.environment["CODEXBAR_COST_PROOF_DIRECTORY"],
              let window else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-x", "-o", "-l", String(window.windowNumber), "\(directory)/\(name).png"]
        try? process.run()
        process.waitUntilExit()
    }

    private func finish() {
        self.stop()
        // The root owns nested tracking; cancelling both menus can dismiss the next popup.
        (self.rootMenu ?? self.menu).cancelTracking()
    }

    private static func matches(_ origin: CGPoint, _ baseline: CGPoint?) -> Bool {
        guard let baseline else { return false }
        return abs(origin.x - baseline.x) <= 1 && abs(origin.y - baseline.y) <= 1
    }

    private static func descendant<T: NSView>(of view: NSView, as _: T.Type) -> T? {
        if let match = view as? T {
            return match
        }
        for subview in view.subviews {
            if let match = self.descendant(of: subview, as: T.self) {
                return match
            }
        }
        return nil
    }

    private static func movePointer(toSegment segment: Int, in control: NSSegmentedControl) {
        let point = self.eventPoint(forSegment: segment, in: control)
        self.postPointerMove(to: point)
    }

    private static func movePointer(to view: NSView) {
        let local = NSPoint(x: view.bounds.midX, y: view.bounds.minY + 1)
        self.postPointerMove(to: self.eventPoint(local: local, in: view))
    }

    private static func postPointerMove(to point: CGPoint) {
        CGEvent(
            mouseEventSource: nil,
            mouseType: .mouseMoved,
            mouseCursorPosition: point,
            mouseButton: .left)?.post(tap: .cghidEventTap)
    }

    private static func postScrollWheel(delta: Int32) {
        CGEvent(
            scrollWheelEvent2Source: nil,
            units: .pixel,
            wheelCount: 1,
            wheel1: delta,
            wheel2: 0,
            wheel3: 0)?.post(tap: .cghidEventTap)
    }

    private static func postPointerMove(toCocoaScreen point: NSPoint) {
        let displayHeight = CGDisplayBounds(CGMainDisplayID()).height
        self.postPointerMove(to: CGPoint(x: point.x, y: displayHeight - point.y))
    }

    private func activateSegment(_ segment: Int, in control: NSSegmentedControl) -> Bool {
        let point = Self.eventPoint(forSegment: segment, in: control)
        guard let mouseDown = CGEvent(
            mouseEventSource: nil,
            mouseType: .leftMouseDown,
            mouseCursorPosition: point,
            mouseButton: .left),
            let mouseUp = CGEvent(
                mouseEventSource: nil,
                mouseType: .leftMouseUp,
                mouseCursorPosition: point,
                mouseButton: .left)
        else {
            self.failure = "Native metric proof could not create the segmented control click events."
            self.finish()
            return false
        }
        mouseDown.setIntegerValueField(.mouseEventClickState, value: 1)
        mouseUp.setIntegerValueField(.mouseEventClickState, value: 1)
        mouseDown.post(tap: .cghidEventTap)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
        mouseUp.post(tap: .cghidEventTap)
        return true
    }

    private func verifyPointer(in view: NSView) -> Bool {
        guard let window = view.window else {
            self.failure = "Native metric proof could not resolve the chart hover window."
            self.finish()
            return false
        }
        let viewPoint = view.convert(window.mouseLocationOutsideOfEventStream, from: nil)
        guard view.bounds.contains(viewPoint) else {
            self.failure = "Native metric proof pointer did not reach the chart hover surface."
            self.finish()
            return false
        }
        return true
    }

    private func verifyPointer(atSegment expectedSegment: Int, in control: NSSegmentedControl) -> Bool {
        guard let window = control.window, control.segmentCount > 0 else {
            self.failure = "Native metric proof could not resolve the segmented control window."
            self.finish()
            return false
        }
        let windowPoint = window.mouseLocationOutsideOfEventStream
        let controlPoint = control.convert(windowPoint, from: nil)
        guard control.bounds.contains(controlPoint) else {
            self.failure = "Native metric proof pointer did not reach the segmented control."
            self.finish()
            return false
        }
        let segmentWidth = control.bounds.width / CGFloat(control.segmentCount)
        let reachedSegment = min(Int(controlPoint.x / segmentWidth), control.segmentCount - 1)
        guard reachedSegment == expectedSegment else {
            self.failure = "Native metric proof pointer reached segment \(reachedSegment), "
                + "expected \(expectedSegment)."
            self.finish()
            return false
        }
        self.pointerSegments.append(reachedSegment)
        return true
    }

    private static func eventPoint(forSegment segment: Int, in control: NSSegmentedControl) -> CGPoint {
        let segmentWidth = control.bounds.width / CGFloat(max(control.segmentCount, 1))
        let local = NSPoint(x: segmentWidth * (CGFloat(segment) + 0.5), y: control.bounds.midY)
        return self.eventPoint(local: local, in: control)
    }

    private static func eventPoint(local: NSPoint, in view: NSView) -> CGPoint {
        let windowPoint = view.convert(local, to: nil)
        let cocoaPoint = view.window?.convertPoint(toScreen: windowPoint) ?? windowPoint
        let mainDisplayHeight = CGDisplayBounds(CGMainDisplayID()).height
        return CGPoint(x: cocoaPoint.x, y: mainDisplayHeight - cocoaPoint.y)
    }
}
