import AppKit
import CodexBarCore
import WebKit

@MainActor
final class OpenAICreditsPurchaseWindowController: NSWindowController, WKNavigationDelegate, WKScriptMessageHandler {
    private static let defaultSize = NSSize(width: 980, height: 760)
    private static let logHandlerName = "codexbarLog"
    private static let debugLogURL = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("codexbar-buy-credits.log")
    private static let autoStartScript = """
    (() => {
      if (window.__codexbarAutoBuyCreditsStarted) return 'already';
      const log = (...args) => {
        try {
          window.webkit?.messageHandlers?.codexbarLog?.postMessage(args);
        } catch {}
      };
      const buttonSelector = 'button, a, [role="button"], input[type="button"], input[type="submit"]';
      const isVisible = (el) => {
        if (!el || !el.getBoundingClientRect) return false;
        const rect = el.getBoundingClientRect();
        if (rect.width < 2 || rect.height < 2) return false;
        const style = window.getComputedStyle ? window.getComputedStyle(el) : null;
        if (style) {
          if (style.display === 'none' || style.visibility === 'hidden') return false;
          if (parseFloat(style.opacity || '1') === 0) return false;
        }
        return true;
      };
      const textOf = el => {
        const raw = el && (el.innerText || el.textContent) ? String(el.innerText || el.textContent) : '';
        return raw.trim();
      };
      const matches = text => {
        const lower = String(text || '').toLowerCase();
        if (!lower.includes('credit')) return false;
        return (
          lower.includes('buy') ||
          lower.includes('add') ||
          lower.includes('purchase') ||
          lower.includes('top up') ||
          lower.includes('top-up')
        );
      };
      const matchesAddMore = text => {
        const lower = String(text || '').toLowerCase();
        return lower.includes('add more');
      };
      const labelFor = el => {
        if (!el) return '';
        return textOf(el) || el.getAttribute('aria-label') || el.getAttribute('title') || el.value || '';
      };
      const summarize = el => {
        if (!el) return null;
        return {
          tag: el.tagName,
          type: el.getAttribute('type'),
          role: el.getAttribute('role'),
          label: labelFor(el),
          aria: el.getAttribute('aria-label'),
          disabled: isDisabled(el),
          href: el.getAttribute('href'),
          testId: el.getAttribute('data-testid'),
          className: (el.className && String(el.className).slice(0, 120)) || ''
        };
      };
      const collectButtons = () => {
        const results = new Set();
        const addAll = (root) => {
          if (!root || !root.querySelectorAll) return;
          root.querySelectorAll(buttonSelector).forEach(el => results.add(el));
        };
        addAll(document);
        document.querySelectorAll('*').forEach(el => {
          if (el.shadowRoot) addAll(el.shadowRoot);
        });
        document.querySelectorAll('iframe').forEach(frame => {
          try {
            const doc = frame.contentDocument;
            if (!doc) return;
            addAll(doc);
            doc.querySelectorAll('*').forEach(el => {
              if (el.shadowRoot) addAll(el.shadowRoot);
            });
          } catch {}
        });
        return Array.from(results);
      };
      const findDialogNextButton = () => {
        const dialog = document.querySelector('[role=\"dialog\"], dialog, [aria-modal=\"true\"]');
        if (!dialog) return null;
        const buttons = Array.from(dialog.querySelectorAll(buttonSelector));
        const labeled = buttons.filter(btn => labelFor(btn).toLowerCase().startsWith('next'));
        const visible = labeled.find(isVisible);
        return visible || labeled[0] || null;
      };
      const clickButton = (el) => {
        if (!el) return false;
        try {
          el.dispatchEvent(new MouseEvent('click', { bubbles: true, cancelable: true, view: window }));
        } catch {
          try {
            el.click();
          } catch {
            return false;
          }
        }
        return true;
      };
      const triggerPointerClick = (el) => {
        if (!el) return false;
        const rect = el.getBoundingClientRect ? el.getBoundingClientRect() : null;
        if (!rect) return false;
        const x = rect.left + rect.width / 2;
        const y = rect.top + rect.height / 2;
        const events = ['pointerdown', 'mousedown', 'pointerup', 'mouseup', 'click'];
        for (const type of events) {
          try {
            el.dispatchEvent(new MouseEvent(type, {
              bubbles: true,
              cancelable: true,
              view: window,
              clientX: x,
              clientY: y
            }));
          } catch {
            return false;
          }
        }
        return true;
      };
      const pickLikelyButton = (buttons) => {
        if (!buttons || buttons.length === 0) return null;
        const labeled = buttons.find(btn => {
          const label = labelFor(btn);
          if (matches(label) || matchesAddMore(label)) return true;
          const aria = String(btn.getAttribute('aria-label') || '').toLowerCase();
          return aria.includes('credit') || aria.includes('buy') || aria.includes('add');
        });
        return labeled || buttons[0];
      };
      const findAddMoreButton = () => {
        const buttons = collectButtons();
        return buttons.find(btn => matchesAddMore(labelFor(btn))) || null;
      };
      const findNextButton = () => {
        const dialogNext = findDialogNextButton();
        if (dialogNext) return dialogNext;
        const buttons = collectButtons();
        const labeled = buttons.filter(btn => {
          const label = labelFor(btn).toLowerCase();
          return label === 'next' || label.startsWith('next ');
        });
        const visible = labeled.find(isVisible);
        if (visible) return visible;
        const submit = buttons.find(btn => btn.type && String(btn.type).toLowerCase() === 'submit' && isVisible(btn));
        return submit || labeled[0] || null;
      };
      const isDisabled = (el) => {
        if (!el) return true;
        if (el.disabled) return true;
        const ariaDisabled = String(el.getAttribute('aria-disabled') || '').toLowerCase();
        if (ariaDisabled === 'true') return true;
        if (el.classList && (el.classList.contains('disabled') || el.classList.contains('is-disabled'))) {
          return true;
        }
        return false;
      };
      const forceClickElement = (el) => {
        if (!el) return false;
        const rect = el.getBoundingClientRect ? el.getBoundingClientRect() : null;
        if (rect) {
          const x = rect.left + rect.width / 2;
          const y = rect.top + rect.height / 2;
          const target = document.elementFromPoint(x, y);
          if (target) {
            try {
              target.dispatchEvent(new MouseEvent('click', { bubbles: true, cancelable: true, view: window }));
              return true;
            } catch {
              return false;
            }
          }
        }
        return false;
      };
      const requestSubmit = (el) => {
        if (!el || !el.closest) return false;
        const form = el.closest('form');
        if (!form) return false;
        if (typeof form.requestSubmit === 'function') {
          form.requestSubmit(el);
          return true;
        }
        if (typeof form.submit === 'function') {
          form.submit();
          return true;
        }
        return false;
      };
      const clickNextIfReady = (attempts) => {
        const nextButton = findNextButton();
        if (!nextButton) {
          if (attempts && attempts % 5 === 0) log('next_missing', { attempts });
          return false;
        }
        if (isDisabled(nextButton)) {
          if (attempts && attempts % 5 === 0) log('next_disabled', summarize(nextButton));
          return false;
        }
        if (!isVisible(nextButton)) {
          if (attempts && attempts % 5 === 0) log('next_hidden', summarize(nextButton));
          return false;
        }
        nextButton.focus?.();
        if (requestSubmit(nextButton)) {
          log('next_submit', summarize(nextButton));
          return true;
        }
        if (triggerPointerClick(nextButton)) {
          log('next_pointer', summarize(nextButton));
          return true;
        }
        if (clickButton(nextButton)) {
          log('next_click', summarize(nextButton));
          return true;
        }
        return forceClickElement(nextButton);
      };
      const startNextPolling = (initialDelay = 500, interval = 500, maxAttempts = 90) => {
        if (window.__codexbarNextPolling) return;
        window.__codexbarNextPolling = true;
        log('start_next_poll', { initialDelay, interval, maxAttempts });
        setTimeout(() => {
          let attempts = 0;
          const nextTimer = setInterval(() => {
            attempts += 1;
            if (attempts % 5 === 0) {
              const nextButton = findNextButton();
              log('next_poll', {
                attempts,
                found: Boolean(nextButton),
                summary: summarize(nextButton)
              });
            }
            if (clickNextIfReady(attempts) || attempts >= maxAttempts) {
              clearInterval(nextTimer);
            }
          }, interval);
        }, initialDelay);
      };
      const observeNextButton = () => {
        if (window.__codexbarNextObserver || !window.MutationObserver) return;
        const observer = new MutationObserver(() => {
          if (clickNextIfReady(1)) {
            observer.disconnect();
            window.__codexbarNextObserver = null;
          }
        });
        observer.observe(document.body, { subtree: true, childList: true, attributes: true });
        window.__codexbarNextObserver = observer;
      };
      const findCreditsCardButton = () => {
        const nodes = Array.from(document.querySelectorAll('h1,h2,h3,div,span,p'));
        const labelMatch = nodes.find(node => {
          const lower = textOf(node).toLowerCase();
          return lower === 'credits remaining' || (lower.includes('credits') && lower.includes('remaining'));
        });
        if (!labelMatch) return null;
        let cur = labelMatch;
        for (let i = 0; i < 6 && cur; i++) {
          const buttons = Array.from(cur.querySelectorAll(buttonSelector));
          const picked = pickLikelyButton(buttons);
          if (picked) return picked;
          cur = cur.parentElement;
        }
        return null;
      };
      const findAndClick = () => {
        const addMoreButton = findAddMoreButton();
        if (addMoreButton) {
          log('add_more_click', summarize(addMoreButton));
          clickButton(addMoreButton);
          return true;
        }
        const cardButton = findCreditsCardButton();
        if (!cardButton) return false;
        log('credits_card_click', summarize(cardButton));
        return clickButton(cardButton);
      };
      const logDialogButtons = () => {
        const dialog = document.querySelector('[role=\"dialog\"], dialog, [aria-modal=\"true\"]');
        if (dialog) {
          const buttons = Array.from(dialog.querySelectorAll(buttonSelector)).map(summarize).filter(Boolean);
          if (buttons.length) {
            log('dialog_buttons', { count: buttons.length, buttons: buttons.slice(0, 6) });
          }
          const nextButton = findDialogNextButton();
          if (nextButton) {
            log('dialog_next', summarize(nextButton));
            setTimeout(() => clickNextIfReady(1), 100);
          }
          return;
        }
        const candidates = collectButtons()
          .map(summarize)
          .filter(Boolean)
          .filter(entry => {
            const label = (entry.label || '').toLowerCase();
            return label.includes('next')
              || label.includes('continue')
              || label.includes('confirm')
              || label.includes('buy');
          });
        if (candidates.length) {
          log('button_candidates', { count: candidates.length, buttons: candidates.slice(0, 8) });
        }
      };
      log('auto_start', { href: location.href, ready: document.readyState });
      const iframeSources = Array.from(document.querySelectorAll('iframe'))
        .map(frame => frame.getAttribute('src') || '')
        .filter(Boolean)
        .slice(0, 6);
      if (iframeSources.length) {
        log('iframes', iframeSources);
      }
      const shadowHostCount = Array.from(document.querySelectorAll('*')).filter(el => el.shadowRoot).length;
      if (shadowHostCount > 0) {
        log('shadow_roots', { count: shadowHostCount });
      }
      if (findAndClick()) {
        window.__codexbarAutoBuyCreditsStarted = true;
        startNextPolling();
        observeNextButton();
        logDialogButtons();
        return 'clicked';
      }
      startNextPolling(500);
      observeNextButton();
      logDialogButtons();
      let attempts = 0;
      const maxAttempts = 14;
      const timer = setInterval(() => {
        attempts += 1;
        if (findAndClick()) {
          logDialogButtons();
          startNextPolling();
          clearInterval(timer);
          return;
        }
        if (attempts >= maxAttempts) {
          clearInterval(timer);
        }
      }, 500);
      window.__codexbarAutoBuyCreditsStarted = true;
      return 'scheduled';
    })();
    """

    private let logger = CodexBarLog.logger(LogCategories.creditsPurchase)
    private var webView: WKWebView?
    private var accountEmail: String?
    private var pendingAutoStart = false
    private let logHandler = WeakScriptMessageHandler()

    init() {
        super.init(window: nil)
        self.logHandler.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show(purchaseURL: URL, accountEmail: String?, autoStartPurchase: Bool) {
        let normalizedEmail = Self.normalizeEmail(accountEmail)
        if self.window == nil || normalizedEmail != self.accountEmail {
            self.accountEmail = normalizedEmail
            self.buildWindow()
        }
        Self.resetDebugLog()
        let accountValue = normalizedEmail == nil ? "none" : "set"
        let sanitizedURL = Self.sanitizedURLString(purchaseURL)
        Self.appendDebugLog(
            "show autoStart=\(autoStartPurchase) url=\(sanitizedURL) account=\(accountValue)")
        self.logger.info("Buy credits window opened")
        self.logger.debug("Auto-start purchase", metadata: ["enabled": autoStartPurchase ? "1" : "0"])
        self.logger.debug("Purchase URL", metadata: ["url": sanitizedURL])
        self.logger.debug("Account email", metadata: ["state": accountValue])
        self.pendingAutoStart = autoStartPurchase
        self.load(url: purchaseURL)
        self.window?.center()
        self.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func buildWindow() {
        let config = WKWebViewConfiguration()
        config.userContentController.add(self.logHandler, name: Self.logHandlerName)
        config.websiteDataStore = OpenAIDashboardWebsiteDataStore.store(forAccountEmail: self.accountEmail)

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView(frame: .zero)
        container.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            webView.topAnchor.constraint(equalTo: container.topAnchor),
            webView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        let window = NSWindow(
            contentRect: Self.defaultFrame(),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false)
        window.title = "Buy Credits"
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        window.contentView = container
        window.center()
        window.delegate = self

        self.window = window
        self.webView = webView
    }

    private func load(url: URL) {
        guard let webView else { return }
        let request = URLRequest(url: url)
        webView.load(request)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard self.pendingAutoStart else { return }
        self.pendingAutoStart = false
        let currentURL = webView.url?.absoluteString ?? "unknown"
        Self.appendDebugLog("didFinish url=\(currentURL)")
        self.logger.debug("Buy credits navigation finished", metadata: ["url": currentURL])
        webView.evaluateJavaScript(Self.autoStartScript) { [logger] result, error in
            if let error {
                Self.appendDebugLog("autoStart error=\(error.localizedDescription)")
                logger.error("Auto-start purchase failed", metadata: ["error": error.localizedDescription])
                return
            }
            if let result {
                Self.appendDebugLog("autoStart result=\(String(describing: result))")
                logger.debug("Auto-start purchase result", metadata: ["result": String(describing: result)])
            }
        }
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == Self.logHandlerName else { return }
        let payload = String(describing: message.body)
        Self.appendDebugLog("js \(payload)")
        self.logger.debug("Auto-buy log", metadata: ["payload": payload])
    }

    private static func normalizeEmail(_ email: String?) -> String? {
        guard let raw = email?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        return raw.lowercased()
    }

    private static func defaultFrame() -> NSRect {
        let visible = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1200, height: 900)
        let width = min(Self.defaultSize.width, visible.width * 0.92)
        let height = min(Self.defaultSize.height, visible.height * 0.88)
        let origin = NSPoint(x: visible.midX - width / 2, y: visible.midY - height / 2)
        return NSRect(origin: origin, size: NSSize(width: width, height: height))
    }

    private static func appendDebugLog(_ message: String) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let line = "[\(timestamp)] \(LogRedactor.redact(message))\n"
        guard let data = line.data(using: .utf8) else { return }
        if FileManager.default.fileExists(atPath: Self.debugLogURL.path) {
            if let handle = try? FileHandle(forWritingTo: Self.debugLogURL) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            }
        } else {
            try? data.write(to: Self.debugLogURL, options: .atomic)
        }
    }

    private static func resetDebugLog() {
        try? FileManager.default.removeItem(at: self.debugLogURL)
    }

    private static func sanitizedURLString(_ url: URL) -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url.absoluteString
        }
        components.query = nil
        components.fragment = nil
        return components.string ?? url.absoluteString
    }
}

private final class WeakScriptMessageHandler: NSObject, WKScriptMessageHandler {
    weak var delegate: WKScriptMessageHandler?

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        self.delegate?.userContentController(userContentController, didReceive: message)
    }
}

// MARK: - NSWindowDelegate

extension OpenAICreditsPurchaseWindowController: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        guard let window = self.window else { return }
        let webView = self.webView
        self.pendingAutoStart = false
        self.webView = nil
        self.window = nil
        self.logger.info("Buy credits window closing")
        WebKitTeardown.scheduleCleanup(owner: window, window: window, webView: webView)
    }
}
