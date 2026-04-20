#if os(macOS)
let openAIDashboardNetworkCaptureBootstrapScript = """
(() => {
  if (window.__codexbarDashboardNetworkCaptureInstalled) return;
  window.__codexbarDashboardNetworkCaptureInstalled = true;

  const storageKey = '__codexbarCapturedResponses';
  const maxEntries = 40;
  const maxTextLength = 200000;
  const relevantNeedles = [
    'creditdetails',
    'credit_amount',
    'creditsremaining',
    'balance',
    'product_surface_usage_values',
    'premium_usage_values',
    'primary_window',
    'secondary_window',
    'limit_window_seconds',
    'reset_after_seconds',
    'codereviewratelimit',
    'ratelimit',
    'additionalratelimits'
  ];

  const responseStore = () => {
    if (!Array.isArray(window[storageKey])) {
      window[storageKey] = [];
    }
    return window[storageKey];
  };

  const isRelevantJSONString = (text) => {
    const lower = String(text || '').toLowerCase();
    if (!lower) return false;
    return relevantNeedles.some(needle => lower.includes(needle));
  };

  const pushJSONCapture = (url, status, json) => {
    if (json === null || json === undefined) return;
    let compact = '';
    try {
      compact = JSON.stringify(json);
    } catch {
      return;
    }
    if (!compact || !isRelevantJSONString(compact)) return;

    const entries = responseStore();
    entries.push({
      url: String(url || ''),
      status: Number(status) || 0,
      json
    });
    if (entries.length > maxEntries) {
      entries.splice(0, entries.length - maxEntries);
    }
  };

  const maybeCaptureJSONText = (url, status, contentType, text) => {
    if (typeof text !== 'string') return;
    const clipped = text.length > maxTextLength ? text.slice(0, maxTextLength) : text;
    const trimmed = clipped.trim();
    const looksJSON = /json/i.test(String(contentType || '')) || trimmed.startsWith('{') || trimmed.startsWith('[');
    if (!looksJSON || !trimmed) return;
    try {
      pushJSONCapture(url, status, JSON.parse(trimmed));
    } catch {}
  };

  const originalFetch = window.fetch;
  if (typeof originalFetch === 'function') {
    window.fetch = function(...args) {
      return originalFetch.apply(this, args).then(response => {
        try {
          const clone = response.clone();
          const contentType = clone.headers && clone.headers.get ? (clone.headers.get('content-type') || '') : '';
          const requestURL = clone.url || (
            args[0] && typeof args[0] === 'object' && 'url' in args[0]
              ? args[0].url
              : args[0]
          );
          clone.text().then(text => {
            maybeCaptureJSONText(requestURL, response.status, contentType, text);
          }).catch(() => {});
        } catch {}
        return response;
      });
    };
  }

  const originalOpen = XMLHttpRequest.prototype.open;
  const originalSend = XMLHttpRequest.prototype.send;

  XMLHttpRequest.prototype.open = function(method, url) {
    this.__codexbarCaptureURL = url;
    return originalOpen.apply(this, arguments);
  };

  XMLHttpRequest.prototype.send = function() {
    this.addEventListener('loadend', function() {
      try {
        const url = this.responseURL || this.__codexbarCaptureURL || '';
        const contentType = this.getResponseHeader ? (this.getResponseHeader('content-type') || '') : '';
        let text = '';
        if (typeof this.responseText === 'string' && this.responseText) {
          text = this.responseText;
        } else if (typeof this.response === 'string' && this.response) {
          text = this.response;
        } else if (this.response && typeof this.response === 'object') {
          try {
            pushJSONCapture(url, this.status || 0, this.response);
            return;
          } catch {}
        }
        maybeCaptureJSONText(url, this.status || 0, contentType, text);
      } catch {}
    }, { once: true });
    return originalSend.apply(this, arguments);
  };
})();
"""
#endif
