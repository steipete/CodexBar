#if os(macOS)
import AppKit
import Foundation
import WebKit

@MainActor
public enum WebKitTeardown {
    private static var retained: [ObjectIdentifier: AnyObject] = [:]
    private static var scheduled: Set<ObjectIdentifier> = []
    private static let log = CodexBarLog.logger(LogCategories.webkitTeardown)

    #if arch(x86_64)
    private static let retainAfterCleanup = true
    #else
    private static let retainAfterCleanup = false
    #endif
    private static let cleanupDelay: TimeInterval = 0.25
    private static let releasePollInterval: TimeInterval = 0.2
    private static let releaseMinimumDelay: TimeInterval = 2.0
    #if arch(x86_64)
    private static let releaseMaximumDelay: TimeInterval = 8.0
    #else
    private static let releaseMaximumDelay: TimeInterval = 2.0
    #endif

    public static func retain(_ owner: AnyObject) {
        self.retained[ObjectIdentifier(owner)] = owner
    }

    public static func scheduleCleanup(
        owner: AnyObject,
        window: NSWindow?,
        webView: WKWebView?,
        closeWindow: (() -> Void)? = nil)
    {
        let id = ObjectIdentifier(owner)
        self.retained[id] = owner
        guard !self.scheduled.contains(id) else { return }
        self.scheduled.insert(id)
        self.log.debug(
            "WebKit cleanup scheduled",
            metadata: ["window": "\(window != nil)", "webView": "\(webView != nil)"])

        Task { @MainActor in
            // Let WebKit unwind delegate callbacks before teardown on Intel.
            await Task.yield()
            try? await Task.sleep(nanoseconds: self.nanoseconds(self.cleanupDelay))
            self.cleanup(window: window, webView: webView, closeWindow: closeWindow)
            self.scheduleRelease(id: id, window: window, webView: webView)
        }
    }

    #if DEBUG
    static func isRetainedForTesting(_ owner: AnyObject) -> Bool {
        self.retained[ObjectIdentifier(owner)] != nil
    }

    static func isScheduledForTesting(_ owner: AnyObject) -> Bool {
        self.scheduled.contains(ObjectIdentifier(owner))
    }

    static func resetForTesting() {
        self.retained.removeAll()
        self.scheduled.removeAll()
    }
    #endif

    private static func cleanup(window: NSWindow?, webView: WKWebView?, closeWindow: (() -> Void)?) {
        self.log.debug(
            "WebKit cleanup",
            metadata: ["window": "\(window != nil)", "webView": "\(webView != nil)"])
        webView?.stopLoading()
        webView?.navigationDelegate = nil
        window?.delegate = nil

        if self.retainAfterCleanup {
            window?.orderOut(nil)
        } else if let closeWindow {
            closeWindow()
        } else {
            window?.close()
        }
    }

    private static func scheduleRelease(id: ObjectIdentifier, window: NSWindow?, webView: WKWebView?) {
        Task { @MainActor in
            let start = Date()
            while true {
                let elapsed = Date().timeIntervalSince(start)
                let windowVisible = window?.isVisible ?? false
                let webViewLoading = webView?.isLoading ?? false
                let inPlay = windowVisible || webViewLoading
                if elapsed >= self.releaseMaximumDelay || (!inPlay && elapsed >= self.releaseMinimumDelay) {
                    break
                }
                try? await Task.sleep(nanoseconds: self.nanoseconds(self.releasePollInterval))
            }
            self.retained.removeValue(forKey: id)
            self.scheduled.remove(id)
            self.log.debug("WebKit cleanup released")
        }
    }

    private static func nanoseconds(_ interval: TimeInterval) -> UInt64 {
        UInt64(interval * 1_000_000_000)
    }
}
#endif
