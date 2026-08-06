import Foundation

enum CLIServeWebUI {
    static func response() -> CLILocalHTTPResponse {
        CLILocalHTTPResponse(
            status: .ok,
            body: Data(self.html.utf8),
            contentType: "text/html; charset=utf-8",
            extraHeaders: [("Cache-Control", "no-store")])
    }

    static let html = #"""
    <!doctype html>
    <html lang="en">
    <head>
      <meta charset="utf-8">
      <meta name="viewport" content="width=device-width, initial-scale=1">
      <meta name="color-scheme" content="light dark">
      <link rel="icon" href="data:,">
      <title>CodexBar Dashboard</title>
      <style>
        :root {
          color-scheme: light dark;
          --page: #f3f4f1;
          --surface: #ffffff;
          --surface-muted: #f7f8f5;
          --text: #1d211f;
          --muted: #66706a;
          --line: #dfe3de;
          --shadow: 0 10px 30px rgb(27 35 30 / 8%);
          --ok: #198754;
          --warning: #b76e00;
          --critical: #c63d3d;
          --unknown: #7a827d;
        }

        @media (prefers-color-scheme: dark) {
          :root {
            --page: #121513;
            --surface: #1b1f1c;
            --surface-muted: #161a17;
            --text: #eef2ee;
            --muted: #9ca69f;
            --line: #303630;
            --shadow: 0 14px 38px rgb(0 0 0 / 24%);
          }
        }

        * {
          box-sizing: border-box;
        }

        body {
          margin: 0;
          min-width: 280px;
          min-height: 100vh;
          background:
            linear-gradient(135deg, color-mix(in srgb, var(--page), #49a3b0 4%), var(--page) 42%);
          color: var(--text);
          font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
          font-size: 14px;
          line-height: 1.4;
        }

        .shell {
          width: min(1180px, 100%);
          margin: 0 auto;
          padding: 28px 22px 40px;
        }

        .topbar,
        .brand,
        .meta,
        .card-head,
        .provider-title,
        .status,
        .window-head,
        .metrics,
        .auth-actions {
          display: flex;
          align-items: center;
        }

        .topbar {
          min-height: 42px;
          justify-content: space-between;
          gap: 18px;
          margin-bottom: 22px;
        }

        .brand {
          gap: 10px;
          min-width: 0;
        }

        .mark {
          width: 27px;
          height: 27px;
          border: 2px solid currentColor;
          border-radius: 8px 8px 8px 3px;
          position: relative;
          box-shadow: inset 0 -5px 0 color-mix(in srgb, currentColor, transparent 86%);
        }

        .mark::after {
          content: "";
          position: absolute;
          right: 4px;
          bottom: 4px;
          width: 6px;
          height: 6px;
          border-radius: 2px;
          background: #49a3b0;
        }

        h1 {
          margin: 0;
          font-size: 21px;
          letter-spacing: -0.025em;
        }

        .version {
          color: var(--muted);
          font-size: 12px;
          white-space: nowrap;
        }

        .meta {
          justify-content: flex-end;
          flex-wrap: wrap;
          gap: 8px 12px;
          color: var(--muted);
          font-size: 12px;
        }

        .badge {
          display: none;
          padding: 3px 8px;
          border: 1px solid color-mix(in srgb, var(--warning), transparent 60%);
          border-radius: 999px;
          background: color-mix(in srgb, var(--warning), transparent 88%);
          color: var(--warning);
          font-weight: 650;
          text-transform: uppercase;
          letter-spacing: 0.06em;
        }

        .badge.visible {
          display: inline-flex;
        }

        button,
        input {
          font: inherit;
        }

        button {
          border: 1px solid var(--line);
          border-radius: 8px;
          background: var(--surface);
          color: var(--text);
          cursor: pointer;
          padding: 6px 10px;
        }

        button:hover {
          border-color: var(--muted);
        }

        button:focus-visible,
        input:focus-visible {
          outline: 2px solid #49a3b0;
          outline-offset: 2px;
        }

        .sign-out {
          display: none;
          padding: 3px 8px;
          color: var(--muted);
          font-size: 12px;
        }

        .sign-out.visible {
          display: inline-block;
        }

        .notice {
          display: none;
          max-width: 560px;
          margin: 60px auto;
          padding: 24px;
          border: 1px solid var(--line);
          border-radius: 14px;
          background: var(--surface);
          box-shadow: var(--shadow);
        }

        .notice.visible {
          display: block;
        }

        .notice h2 {
          margin: 0 0 7px;
          font-size: 18px;
        }

        .notice p {
          margin: 0 0 18px;
          color: var(--muted);
        }

        .auth-actions {
          gap: 8px;
        }

        .auth-actions input {
          min-width: 0;
          flex: 1;
          padding: 8px 10px;
          border: 1px solid var(--line);
          border-radius: 8px;
          background: var(--surface-muted);
          color: var(--text);
        }

        .auth-actions button {
          background: var(--text);
          color: var(--surface);
          font-weight: 650;
        }

        .grid {
          display: grid;
          grid-template-columns: repeat(auto-fit, minmax(min(100%, 320px), 1fr));
          gap: 14px;
        }

        .card {
          --accent: #49a3b0;
          position: relative;
          overflow: hidden;
          padding: 17px;
          border: 1px solid var(--line);
          border-top: 3px solid var(--accent);
          border-radius: 12px;
          background: var(--surface);
          box-shadow: var(--shadow);
        }

        .card.disabled {
          opacity: 0.55;
          filter: saturate(0.4);
        }

        .card.error {
          border-color: color-mix(in srgb, var(--critical), var(--line) 56%);
          border-top-color: var(--critical);
        }

        .card-head {
          justify-content: space-between;
          gap: 12px;
          margin-bottom: 14px;
        }

        .provider-title {
          min-width: 0;
          gap: 8px;
        }

        .provider-name {
          overflow: hidden;
          font-size: 16px;
          font-weight: 700;
          letter-spacing: -0.015em;
          text-overflow: ellipsis;
          white-space: nowrap;
        }

        .status {
          flex: none;
          gap: 6px;
          color: var(--muted);
          font-size: 12px;
        }

        .dot {
          width: 8px;
          height: 8px;
          border-radius: 50%;
          background: var(--unknown);
          box-shadow: 0 0 0 3px color-mix(in srgb, var(--unknown), transparent 85%);
        }

        .dot.ok {
          background: var(--ok);
          box-shadow: 0 0 0 3px color-mix(in srgb, var(--ok), transparent 85%);
        }

        .dot.warning {
          background: var(--warning);
          box-shadow: 0 0 0 3px color-mix(in srgb, var(--warning), transparent 85%);
        }

        .dot.critical {
          background: var(--critical);
          box-shadow: 0 0 0 3px color-mix(in srgb, var(--critical), transparent 85%);
        }

        .identity {
          min-height: 20px;
          margin: -7px 0 13px;
          color: var(--muted);
          font-size: 12px;
        }

        .identity span + span::before {
          content: " · ";
          color: var(--line);
        }

        .windows {
          display: grid;
          gap: 12px;
        }

        .window-head {
          justify-content: space-between;
          gap: 10px;
          margin-bottom: 5px;
          font-size: 12px;
        }

        .window-label {
          font-weight: 650;
        }

        .window-time {
          color: var(--muted);
          white-space: nowrap;
        }

        .track {
          height: 8px;
          overflow: hidden;
          border-radius: 999px;
          background: color-mix(in srgb, var(--text), transparent 91%);
        }

        .fill {
          height: 100%;
          border-radius: inherit;
          background: var(--accent);
          transition: width 220ms ease-out;
        }

        .metrics {
          align-items: stretch;
          gap: 8px;
          margin-top: 15px;
        }

        .metric {
          min-width: 0;
          flex: 1;
          padding: 9px 10px;
          border-radius: 8px;
          background: var(--surface-muted);
        }

        .metric-label {
          display: block;
          margin-bottom: 2px;
          color: var(--muted);
          font-size: 10px;
          font-weight: 650;
          letter-spacing: 0.05em;
          text-transform: uppercase;
        }

        .metric-value {
          display: block;
          overflow: hidden;
          font-size: 13px;
          font-weight: 650;
          text-overflow: ellipsis;
          white-space: nowrap;
        }

        .error-message {
          margin: 4px 0 0;
          padding: 10px 11px;
          border-radius: 8px;
          background: color-mix(in srgb, var(--critical), transparent 91%);
          color: var(--critical);
          font-size: 12px;
          overflow-wrap: anywhere;
        }

        .empty {
          grid-column: 1 / -1;
          padding: 42px 20px;
          border: 1px dashed var(--line);
          border-radius: 12px;
          color: var(--muted);
          text-align: center;
        }

        @media (max-width: 620px) {
          .shell {
            padding: 18px 14px 30px;
          }

          .topbar {
            align-items: flex-start;
            flex-direction: column;
          }

          .meta {
            justify-content: flex-start;
          }
        }

        @media (prefers-reduced-motion: reduce) {
          .fill {
            transition: none;
          }
        }
      </style>
    </head>
    <body>
      <main class="shell">
        <header class="topbar">
          <div class="brand">
            <span class="mark" aria-hidden="true"></span>
            <h1>CodexBar</h1>
            <span id="version" class="version"></span>
          </div>
          <div class="meta" aria-live="polite">
            <span id="generated">Loading…</span>
            <span id="stale" class="badge">Stale</span>
            <button id="sign-out" class="sign-out" type="button">Sign out</button>
          </div>
        </header>

        <section id="auth" class="notice" aria-labelledby="auth-title">
          <h2 id="auth-title">This server requires a dashboard token</h2>
          <p>Enter the bearer token configured for this CodexBar server.</p>
          <form id="token-form" class="auth-actions">
            <input id="token" type="password" name="token" autocomplete="current-password"
              aria-label="Dashboard token" required>
            <button type="submit">Connect</button>
          </form>
        </section>

        <section id="error" class="notice" aria-live="polite">
          <h2>Dashboard unavailable</h2>
          <p id="error-message"></p>
          <button id="retry" type="button">Retry now</button>
        </section>

        <section id="providers" class="grid" aria-live="polite"></section>
      </main>

      <script>
        "use strict";

        const tokenKey = "codexbar.dashboardToken";
        const state = {
          snapshot: null,
          timer: null,
          fetching: false,
          refreshSeconds: 15
        };

        const elements = {
          auth: document.getElementById("auth"),
          error: document.getElementById("error"),
          errorMessage: document.getElementById("error-message"),
          generated: document.getElementById("generated"),
          providers: document.getElementById("providers"),
          retry: document.getElementById("retry"),
          signOut: document.getElementById("sign-out"),
          stale: document.getElementById("stale"),
          token: document.getElementById("token"),
          tokenForm: document.getElementById("token-form"),
          version: document.getElementById("version")
        };

        function storedToken() {
          try {
            return localStorage.getItem(tokenKey) || "";
          } catch (_) {
            return "";
          }
        }

        function saveToken(token) {
          try {
            localStorage.setItem(tokenKey, token);
          } catch (_) {
            // The request can still use the submitted token in this browser session.
          }
        }

        function clearToken() {
          try {
            localStorage.removeItem(tokenKey);
          } catch (_) {
            // Nothing else to clear when storage is unavailable.
          }
        }

        function node(tag, className, text) {
          const element = document.createElement(tag);
          if (className) element.className = className;
          if (text !== undefined && text !== null) element.textContent = String(text);
          return element;
        }

        function finiteNumber(value, fallback = 0) {
          const number = Number(value);
          return Number.isFinite(number) ? number : fallback;
        }

        function dateValue(value) {
          const milliseconds = Date.parse(value || "");
          return Number.isFinite(milliseconds) ? milliseconds : null;
        }

        function compactDuration(seconds) {
          const total = Math.max(0, Math.round(seconds));
          if (total < 60) return `${total}s`;
          const minutes = Math.floor(total / 60);
          if (minutes < 60) return `${minutes}m`;
          const hours = Math.floor(minutes / 60);
          const minuteRemainder = minutes % 60;
          if (hours < 24) return minuteRemainder ? `${hours}h ${minuteRemainder}m` : `${hours}h`;
          const days = Math.floor(hours / 24);
          const hourRemainder = hours % 24;
          return hourRemainder ? `${days}d ${hourRemainder}h` : `${days}d`;
        }

        function relativeTime(value) {
          const time = dateValue(value);
          if (time === null) return "";
          const seconds = (time - Date.now()) / 1000;
          const duration = compactDuration(Math.abs(seconds));
          return seconds >= 0 ? `in ${duration}` : `${duration} ago`;
        }

        function resetTime(value) {
          const relative = relativeTime(value);
          if (!relative) return "";
          return relative.startsWith("in ") ? `resets ${relative}` : `reset ${relative}`;
        }

        function percent(value) {
          const number = finiteNumber(value);
          const rounded = Math.round(number * 10) / 10;
          return `${rounded}%`;
        }

        function amount(value) {
          return new Intl.NumberFormat(undefined, { maximumFractionDigits: 2 }).format(finiteNumber(value));
        }

        function dollars(value) {
          return new Intl.NumberFormat(undefined, {
            style: "currency",
            currency: "USD",
            minimumFractionDigits: 2,
            maximumFractionDigits: 2
          }).format(finiteNumber(value));
        }

        function accentColor(value) {
          return /^#[0-9a-f]{6}$/i.test(value || "") ? value : "#49A3B0";
        }

        function metric(label, value) {
          const item = node("div", "metric");
          item.append(node("span", "metric-label", label));
          item.append(node("span", "metric-value", value));
          return item;
        }

        function renderWindow(window) {
          const item = node("div", "window");
          const head = node("div", "window-head");
          const label = node(
            "span",
            "window-label",
            `${window.label || "Usage"} · ${percent(window.usedPercent)} used`
          );
          head.append(label);
          const reset = resetTime(window.resetAt);
          if (reset) head.append(node("span", "window-time", reset));

          const track = node("div", "track");
          const fill = node("div", "fill");
          const width = Math.min(100, Math.max(0, finiteNumber(window.usedPercent)));
          fill.style.width = `${width}%`;
          track.setAttribute("role", "progressbar");
          track.setAttribute("aria-label", "Usage window");
          track.setAttribute("aria-valuemin", "0");
          track.setAttribute("aria-valuemax", "100");
          track.setAttribute("aria-valuenow", String(width));
          track.append(fill);
          item.append(head, track);
          return item;
        }

        function renderProvider(provider) {
          const card = node("article", "card");
          card.style.setProperty("--accent", accentColor(provider.display?.accentColor));
          if (provider.enabled === false) card.classList.add("disabled");
          if (provider.error) card.classList.add("error");

          const head = node("div", "card-head");
          const title = node("div", "provider-title");
          title.append(node("span", "provider-name", provider.name || provider.id || "Provider"));
          head.append(title);

          const knownStatusLevels = ["ok", "warning", "critical", "unknown"];
          const requestedStatusLevel = provider.status?.level || "unknown";
          const statusLevel = knownStatusLevels.includes(requestedStatusLevel) ? requestedStatusLevel : "unknown";
          const statusLabel = provider.status?.label || statusLevel;
          const status = node("div", "status");
          const dot = node("span", `dot ${statusLevel}`);
          dot.setAttribute("aria-hidden", "true");
          status.append(dot, node("span", "status-label", statusLabel));
          head.append(status);
          card.append(head);

          if (provider.identity) {
            const identity = node("div", "identity");
            if (provider.identity.plan) identity.append(node("span", "", provider.identity.plan));
            if (provider.identity.accountEmail) {
              identity.append(node("span", "", provider.identity.accountEmail));
            }
            card.append(identity);
          }

          if (provider.error) {
            card.append(node("p", "error-message", provider.error.message || "Provider data is unavailable."));
          }

          const windows = node("div", "windows");
          for (const window of provider.windows || []) windows.append(renderWindow(window));
          card.append(windows);

          const metrics = node("div", "metrics");
          if (provider.credits?.remaining !== null && provider.credits?.remaining !== undefined) {
            const unit = provider.credits.unit ? ` ${provider.credits.unit}` : "";
            metrics.append(metric("Remaining", `${amount(provider.credits.remaining)}${unit}`));
          }
          if (provider.cost?.todayUSD !== null && provider.cost?.todayUSD !== undefined) {
            metrics.append(metric("Today", dollars(provider.cost.todayUSD)));
          }
          if (provider.cost?.last30DaysUSD !== null && provider.cost?.last30DaysUSD !== undefined) {
            metrics.append(metric("Last 30 days", dollars(provider.cost.last30DaysUSD)));
          }
          if (metrics.childElementCount) card.append(metrics);
          return card;
        }

        function updateFreshness() {
          if (!state.snapshot) return;
          const generatedAt = dateValue(state.snapshot.generatedAt);
          elements.generated.textContent = generatedAt === null
            ? "Updated time unavailable"
            : `Updated ${relativeTime(state.snapshot.generatedAt)}`;
          const staleAfter = Math.max(0, finiteNumber(state.snapshot.staleAfterSeconds));
          const stale = generatedAt !== null && (Date.now() - generatedAt) / 1000 > staleAfter;
          elements.stale.classList.toggle("visible", stale);
        }

        function renderSnapshot(snapshot) {
          state.snapshot = snapshot;
          const host = snapshot.host || {};
          const interval = finiteNumber(host.refreshIntervalSeconds, 15);
          state.refreshSeconds = Math.max(interval, 15);
          elements.version.textContent = host.codexBarVersion ? `v${host.codexBarVersion}` : "";
          elements.auth.classList.remove("visible");
          elements.error.classList.remove("visible");
          elements.signOut.classList.toggle("visible", Boolean(storedToken()));

          const providers = Array.isArray(snapshot.providers) ? [...snapshot.providers] : [];
          providers.sort((left, right) => {
            return finiteNumber(left.display?.sortKey) - finiteNumber(right.display?.sortKey);
          });
          const cards = providers.map(renderProvider);
          if (!cards.length) cards.push(node("div", "empty", "No providers are configured."));
          elements.providers.replaceChildren(...cards);
          updateFreshness();
        }

        function showTokenForm() {
          state.snapshot = null;
          elements.providers.replaceChildren();
          elements.error.classList.remove("visible");
          elements.auth.classList.add("visible");
          elements.generated.textContent = "Authorization required";
          elements.stale.classList.remove("visible");
          elements.signOut.classList.toggle("visible", Boolean(storedToken()));
          elements.token.focus();
        }

        function showError(message) {
          elements.auth.classList.remove("visible");
          elements.error.classList.add("visible");
          elements.errorMessage.textContent = message;
          elements.generated.textContent = "Refresh failed";
        }

        function scheduleRefresh() {
          clearTimeout(state.timer);
          if (elements.auth.classList.contains("visible")) return;
          state.timer = setTimeout(refresh, state.refreshSeconds * 1000);
        }

        async function refresh(overrideToken) {
          if (state.fetching) return;
          state.fetching = true;
          clearTimeout(state.timer);
          try {
            const token = overrideToken || storedToken();
            const headers = token ? { Authorization: `Bearer ${token}` } : {};
            const response = await fetch("/dashboard/v1/snapshot", {
              headers,
              cache: "no-store"
            });
            if (response.status === 401) {
              showTokenForm();
              return;
            }
            if (response.status === 504) {
              throw new Error(
                "The server is still building the first snapshot — this can take a minute or two " +
                "on large local histories. Retrying automatically."
              );
            }
            if (!response.ok) throw new Error(`Server returned HTTP ${response.status}`);
            renderSnapshot(await response.json());
          } catch (error) {
            showError(error instanceof Error ? error.message : "The dashboard could not be refreshed.");
          } finally {
            state.fetching = false;
            scheduleRefresh();
          }
        }

        elements.tokenForm.addEventListener("submit", event => {
          event.preventDefault();
          const token = elements.token.value.trim();
          if (!token) return;
          saveToken(token);
          elements.token.value = "";
          refresh(token);
        });

        elements.signOut.addEventListener("click", () => {
          clearToken();
          clearTimeout(state.timer);
          showTokenForm();
        });

        elements.retry.addEventListener("click", () => refresh());

        // No document.hidden gating: embedded panes and sidebars often report
        // "hidden" permanently, and browsers already throttle background timers.
        setInterval(updateFreshness, 1000);
        refresh();
      </script>
    </body>
    </html>
    """#
}
