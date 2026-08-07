import Foundation

extension CLIServeWebUI {
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
          border-radius: 12px;
          background: var(--surface);
          box-shadow: var(--shadow);
        }

        .card.active-account {
          border-color: color-mix(in srgb, var(--ok), var(--line) 45%);
        }

        .card.pending {
          min-height: 132px;
        }

        .pending-lines {
          display: grid;
          gap: 9px;
          margin-top: 18px;
        }

        .pending-line {
          height: 9px;
          border-radius: 999px;
          background: color-mix(in srgb, var(--accent), transparent 84%);
          animation: pending-pulse 1.6s ease-in-out infinite;
        }

        .pending-line:last-child {
          width: 62%;
          animation-delay: 120ms;
        }

        @keyframes pending-pulse {
          0%, 100% { opacity: 0.42; }
          50% { opacity: 0.9; }
        }

        .group {
          margin-bottom: 26px;
        }

        .group-title {
          margin: 0 0 10px;
          color: var(--muted);
          font-size: 12px;
          font-weight: 700;
          letter-spacing: 0.08em;
          text-transform: uppercase;
        }

        .provider-icon {
          flex: none;
          width: 18px;
          height: 18px;
          background: var(--accent);
          -webkit-mask: var(--icon) center / contain no-repeat;
          mask: var(--icon) center / contain no-repeat;
        }

        .provider-dot {
          flex: none;
          width: 10px;
          height: 10px;
          border-radius: 50%;
          background: var(--accent);
        }

        .pill {
          flex: none;
          padding: 2px 9px;
          border: 1px solid;
          border-radius: 999px;
          font-size: 11px;
          font-weight: 650;
        }

        .pill.ok { color: var(--ok); border-color: color-mix(in srgb, var(--ok), transparent 45%); }
        .pill.warning { color: var(--warning); border-color: color-mix(in srgb, var(--warning), transparent 45%); }
        .pill.critical { color: var(--critical); border-color: color-mix(in srgb, var(--critical), transparent 45%); }
        .pill.active { color: var(--ok); border-color: color-mix(in srgb, var(--ok), transparent 45%); }

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

        .accounts {
          display: grid;
          gap: 12px;
        }

        .account {
          padding: 11px 12px;
          border: 1px solid var(--line);
          border-radius: 10px;
          background: var(--surface-muted);
        }

        .account.active {
          border-color: color-mix(in srgb, var(--ok), var(--line) 45%);
        }

        .account-head {
          display: flex;
          justify-content: space-between;
          align-items: center;
          gap: 10px;
          margin-bottom: 9px;
        }

        .account-name {
          overflow: hidden;
          font-size: 13px;
          font-weight: 650;
          text-overflow: ellipsis;
          white-space: nowrap;
        }

        .account-badge {
          flex: none;
          padding: 1px 8px;
          border: 1px solid color-mix(in srgb, var(--ok), transparent 45%);
          border-radius: 999px;
          color: var(--ok);
          font-size: 10px;
          font-weight: 650;
          letter-spacing: 0.04em;
          text-transform: uppercase;
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

        .chart-wrap {
          margin-top: 14px;
        }

        .chart {
          display: block;
          width: 100%;
          height: 44px;
        }

        .chart rect {
          fill: color-mix(in srgb, var(--accent), transparent 25%);
        }

        .chart rect:hover {
          fill: var(--accent);
        }

        .chart-caption {
          display: flex;
          justify-content: space-between;
          gap: 10px;
          margin-top: 4px;
          color: var(--muted);
          font-size: 10px;
          font-weight: 650;
          letter-spacing: 0.04em;
          text-transform: uppercase;
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
          .fill,
          .pending-line {
            animation: none;
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

        <section id="providers" aria-live="polite"></section>
      </main>

      <script>
        "use strict";

        const tokenKey = "codexbar.dashboardToken";
        const snapshotKey = "codexbar.lastSnapshot";
        const providerIconURLs = __PROVIDER_ICON_URLS__;
        const state = {
          snapshot: null,
          timer: null,
          fetching: false,
          fillPromise: null,
          fillGeneration: 0,
          fillComplete: false,
          forceStale: false,
          refreshSeconds: 15,
          costHistories: {}
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

        function storedSnapshot() {
          try {
            const snapshot = JSON.parse(localStorage.getItem(snapshotKey) || "null");
            return snapshot && snapshot.schemaVersion === 1 && Array.isArray(snapshot.providers)
              ? snapshot
              : null;
          } catch (_) {
            return null;
          }
        }

        function persistSnapshot(snapshot) {
          try {
            const persisted = {
              ...snapshot,
              providers: (snapshot.providers || []).filter(provider => !provider._pending).map(provider => {
                const copy = { ...provider };
                delete copy._pending;
                delete copy._progressiveError;
                copy.identity = redactedIdentity(copy.identity);
                if (Array.isArray(copy.accounts)) {
                  copy.accounts = copy.accounts.map(account => ({
                    ...account,
                    identity: redactedIdentity(account.identity)
                  }));
                }
                return copy;
              })
            };
            localStorage.setItem(snapshotKey, JSON.stringify(persisted));
          } catch (_) {
            // Rendering remains live when storage is unavailable or full.
          }
        }

        function redactedIdentity(identity) {
          if (!identity || !identity.accountEmail) return identity;
          const email = String(identity.accountEmail);
          const at = email.lastIndexOf("@");
          return {
            ...identity,
            accountEmail: at >= 0 ? `redacted${email.slice(at)}` : "redacted"
          };
        }

        function clearSnapshot() {
          try {
            localStorage.removeItem(snapshotKey);
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

        function renderCostChart(history) {
          // Daily spend as an inline SVG bar chart: one thin accent bar per day,
          // 2px gaps, no dual axes, native tooltips per bar. Height is scaled to
          // the busiest day; a zero-spend range renders nothing.
          const days = history.slice(-30);
          const max = Math.max(...days.map(day => day.cost), 0);
          if (!(max > 0) || days.length < 2) return null;

          const width = 100;
          const height = 36;
          const gap = 1;
          const barWidth = Math.max((width - gap * (days.length - 1)) / days.length, 0.5);
          const svgNS = "http://www.w3.org/2000/svg";
          const svg = document.createElementNS(svgNS, "svg");
          svg.setAttribute("viewBox", `0 0 ${width} ${height}`);
          svg.setAttribute("preserveAspectRatio", "none");
          svg.classList.add("chart");
          svg.setAttribute("role", "img");
          svg.setAttribute("aria-label", `Daily spend, last ${days.length} days`);

          days.forEach((day, index) => {
            const barHeight = Math.max((day.cost / max) * height, day.cost > 0 ? 1 : 0);
            const rect = document.createElementNS(svgNS, "rect");
            rect.setAttribute("x", String(index * (barWidth + gap)));
            rect.setAttribute("y", String(height - barHeight));
            rect.setAttribute("width", String(barWidth));
            rect.setAttribute("height", String(barHeight));
            rect.setAttribute("rx", "0.5");
            const title = document.createElementNS(svgNS, "title");
            title.textContent = `${day.date} · ${dollars(day.cost)}`;
            rect.append(title);
            svg.append(rect);
          });

          const wrap = node("div", "chart-wrap");
          wrap.append(svg);
          const caption = node("div", "chart-caption");
          caption.append(node("span", "", `Daily spend · ${days.length}d`));
          caption.append(node("span", "", `peak ${dollars(max)}`));
          wrap.append(caption);
          return wrap;
        }

        function providerGlyph(provider) {
          const url = providerIconURLs[provider.id];
          if (url) {
            const icon = node("span", "provider-icon");
            icon.style.setProperty("--icon", `url("${url}")`);
            icon.setAttribute("aria-hidden", "true");
            return icon;
          }
          const dot = node("span", "provider-dot");
          dot.setAttribute("aria-hidden", "true");
          return dot;
        }

        function worstWindowLevel(windows) {
          const worst = Math.max(...(windows || []).map(w => finiteNumber(w.usedPercent)), -1);
          if (worst < 0) return null;
          if (worst >= 95) return "critical";
          if (worst >= 80) return "warning";
          return "ok";
        }

        function pill(level, label) {
          const el = node("span", `pill ${level}`, label);
          return el;
        }

        function renderAccountCard(provider, account) {
          // Each claude-swap account gets a full card in the group grid — the
          // vertical structure reads better than rows nested inside one card.
          const card = node("article", "card");
          card.style.setProperty("--accent", accentColor(provider.display?.accentColor));
          if (account.active) card.classList.add("active-account");

          const head = node("div", "card-head");
          const title = node("div", "provider-title");
          title.append(providerGlyph(provider));
          const name = account.identity?.accountEmail || account.label || "Account";
          title.append(node("span", "provider-name", name));
          head.append(title);
          if (account.active) {
            head.append(pill("active", "active"));
          } else {
            const level = worstWindowLevel(account.windows);
            if (level) head.append(pill(level, level === "ok" ? "ok" : level === "warning" ? "high" : "critical"));
          }
          card.append(head);

          if (account.updatedAt) {
            const identity = node("div", "identity");
            identity.append(node("span", "", `updated ${relativeTime(account.updatedAt)}`));
            card.append(identity);
          }

          if (account.error) {
            card.append(node("p", "error-message", account.error));
            return card;
          }

          const windows = node("div", "windows");
          for (const window of account.windows || []) windows.append(renderWindow(window));
          card.append(windows);
          return card;
        }

        function renderProvider(provider) {
          const card = node("article", provider._pending ? "card pending" : "card");
          card.style.setProperty("--accent", accentColor(provider.display?.accentColor));
          if (provider.enabled === false) card.classList.add("disabled");
          if (provider.error) card.classList.add("error");

          const head = node("div", "card-head");
          const title = node("div", "provider-title");
          title.append(providerGlyph(provider));
          title.append(node("span", "provider-name", provider.name || provider.id || "Provider"));
          head.append(title);

          // Service-health status rides the snapshot only when the collector
          // fetched provider status pages; serve does not, so hide the chip
          // entirely instead of rendering a meaningless "unknown".
          if (provider.status) {
            const knownStatusLevels = ["ok", "warning", "critical", "unknown"];
            const requestedStatusLevel = provider.status.level || "unknown";
            const statusLevel = knownStatusLevels.includes(requestedStatusLevel) ? requestedStatusLevel : "unknown";
            const statusLabel = provider.status.label || statusLevel;
            const status = node("div", "status");
            const dot = node("span", `dot ${statusLevel}`);
            dot.setAttribute("aria-hidden", "true");
            status.append(dot, node("span", "status-label", statusLabel));
            head.append(status);
          }
          card.append(head);

          if (provider._pending) {
            const lines = node("div", "pending-lines");
            lines.append(node("span", "pending-line"), node("span", "pending-line"));
            card.append(lines);
            return card;
          }

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
          if (provider.accountsError) {
            card.append(node("p", "error-message", provider.accountsError));
          }

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

          const history = state.costHistories[provider.id];
          if (Array.isArray(history)) {
            const chart = renderCostChart(history);
            if (chart) card.append(chart);
          }
          return card;
        }

        function updateFreshness() {
          if (!state.snapshot) return;
          const generatedAt = dateValue(state.snapshot.generatedAt);
          elements.generated.textContent = generatedAt === null
            ? "Updated time unavailable"
            : `Updated ${relativeTime(state.snapshot.generatedAt)}`;
          const staleAfter = Math.max(0, finiteNumber(state.snapshot.staleAfterSeconds));
          const stale = state.forceStale
            || (generatedAt !== null && (Date.now() - generatedAt) / 1000 > staleAfter);
          elements.stale.classList.toggle("visible", stale);
        }

        function renderSnapshot(snapshot, forceStale = false) {
          state.snapshot = snapshot;
          state.forceStale = forceStale;
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

          // Vertical grouping: multi-account providers get their own titled
          // group with one card per account; everything else lands in a
          // second group below.
          const sections = [];
          const rest = [];
          for (const provider of providers) {
            const accounts = Array.isArray(provider.accounts) ? provider.accounts : [];
            if (accounts.length) {
              const group = node("section", "group");
              group.append(node("h2", "group-title", `${provider.name || provider.id} accounts`));
              const grid = node("div", "grid");
              for (const account of accounts) grid.append(renderAccountCard(provider, account));
              if (provider.accountsError) grid.append(node("p", "error-message", provider.accountsError));
              group.append(grid);
              sections.push(group);
            } else {
              rest.push(provider);
            }
          }
          if (rest.length) {
            const group = node("section", "group");
            if (sections.length) group.append(node("h2", "group-title", "Other providers"));
            const grid = node("div", "grid");
            for (const provider of rest) grid.append(renderProvider(provider));
            group.append(grid);
            sections.push(group);
          }
          if (!sections.length) sections.push(node("div", "empty", "No providers are configured."));
          elements.providers.replaceChildren(...sections);
          updateFreshness();
        }

        function showTokenForm() {
          state.fillGeneration += 1;
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

        function requestHeaders(overrideToken) {
          const token = overrideToken || storedToken();
          return token ? { Authorization: `Bearer ${token}` } : {};
        }

        function progressiveErrorMessage(error) {
          return error instanceof Error ? error.message : "Provider data is unavailable.";
        }

        function replaceProgressiveProvider(provider, snapshot, persist) {
          if (!state.snapshot) return;
          const providers = (state.snapshot.providers || []).map(existing => {
            return existing.id === provider.id ? provider : existing;
          });
          state.snapshot = {
            ...state.snapshot,
            generatedAt: snapshot?.generatedAt || state.snapshot.generatedAt,
            staleAfterSeconds: snapshot?.staleAfterSeconds ?? state.snapshot.staleAfterSeconds,
            host: snapshot?.host || state.snapshot.host,
            providers
          };
          renderSnapshot(state.snapshot, true);
          if (persist) persistSnapshot(state.snapshot);
        }

        async function fetchProgressiveProvider(provider, headers, generation) {
          try {
            const response = await fetch(
              `/dashboard/v1/snapshot?provider=${encodeURIComponent(provider.id)}`,
              { headers, cache: "no-store" }
            );
            if (generation !== state.fillGeneration) return;
            if (response.status === 401) {
              showTokenForm();
              return;
            }
            if (!response.ok) throw new Error(`Server returned HTTP ${response.status}`);
            const snapshot = await response.json();
            if (generation !== state.fillGeneration) return;
            const row = (snapshot.providers || []).find(candidate => candidate.id === provider.id);
            if (!row) throw new Error("Provider data was missing from the response.");
            replaceProgressiveProvider(row, snapshot, true);
          } catch (error) {
            if (generation !== state.fillGeneration) return;
            replaceProgressiveProvider({
              ...provider,
              _pending: false,
              _progressiveError: true,
              status: null,
              identity: null,
              windows: [],
              credits: null,
              cost: null,
              accounts: null,
              error: { message: progressiveErrorMessage(error) }
            }, null, false);
          }
        }

        async function runProgressiveFill(overrideToken) {
          clearTimeout(state.timer);
          const generation = ++state.fillGeneration;
          const headers = requestHeaders(overrideToken);
          let shell;
          try {
            const response = await fetch(
              "/dashboard/v1/snapshot?detail=shell",
              { headers, cache: "no-store" }
            );
            if (response.status === 401) {
              showTokenForm();
              return;
            }
            if (!response.ok) throw new Error(`Server returned HTTP ${response.status}`);
            shell = await response.json();
          } catch (error) {
            if (!state.snapshot || !(state.snapshot.providers || []).length) {
              showError(progressiveErrorMessage(error));
              return;
            }
            shell = state.snapshot;
          }
          if (generation !== state.fillGeneration) return;

          const cachedRows = new Map((state.snapshot?.providers || []).map(provider => [provider.id, provider]));
          const shellRows = Array.isArray(shell.providers) ? shell.providers : [];
          const providers = shellRows.map(provider => {
            const cached = cachedRows.get(provider.id);
            return cached
              ? { ...cached, name: provider.name, enabled: provider.enabled, display: provider.display }
              : { ...provider, _pending: true };
          });
          state.snapshot = { ...shell, providers };
          renderSnapshot(state.snapshot, cachedRows.size > 0);

          await Promise.allSettled(
            providers.map(provider => fetchProgressiveProvider(provider, headers, generation))
          );
          if (generation !== state.fillGeneration) return;
          state.fillComplete = true;
          state.forceStale = false;
          if (state.snapshot) renderSnapshot(state.snapshot);
          scheduleRefresh();
        }

        function startProgressiveFill(overrideToken) {
          if (state.fillPromise) return state.fillPromise;
          state.fillPromise = runProgressiveFill(overrideToken).finally(() => {
            state.fillPromise = null;
          });
          return state.fillPromise;
        }

        async function refreshCostHistory(headers) {
          // Daily spend history rides the /cost route. Failures never block the
          // snapshot render: charts simply stay hidden until the next refresh.
          try {
            const response = await fetch("/cost", { headers, cache: "no-store" });
            if (!response.ok) return;
            const rows = await response.json();
            if (!Array.isArray(rows)) return;
            const histories = {};
            for (const row of rows) {
              if (!row || typeof row.provider !== "string") continue;
              if (!Array.isArray(row.daily) || row.daily.length < 2) continue;
              histories[row.provider] = row.daily
                .filter(day => day && typeof day.date === "string")
                .map(day => ({ date: day.date, cost: finiteNumber(day.totalCost) }));
            }
            state.costHistories = histories;
          } catch (error) {
            // Keep the last good histories.
          }
        }

        async function refresh(overrideToken) {
          if (state.fetching) return;
          state.fetching = true;
          clearTimeout(state.timer);
          try {
            const headers = requestHeaders(overrideToken);
            const [response] = await Promise.all([
              fetch("/dashboard/v1/snapshot", { headers, cache: "no-store" }),
              refreshCostHistory(headers)
            ]);
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
            const snapshot = await response.json();
            renderSnapshot(snapshot);
            persistSnapshot(snapshot);
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
          if (state.fillComplete) refresh(token);
          else startProgressiveFill(token);
        });

        elements.signOut.addEventListener("click", () => {
          clearToken();
          clearSnapshot();
          clearTimeout(state.timer);
          showTokenForm();
        });

        elements.retry.addEventListener("click", () => {
          if (state.fillComplete) refresh();
          else startProgressiveFill();
        });

        // No document.hidden gating: embedded panes and sidebars often report
        // "hidden" permanently, and browsers already throttle background timers.
        setInterval(updateFreshness, 1000);
        const cached = storedSnapshot();
        if (cached) renderSnapshot(cached, true);
        startProgressiveFill();
      </script>
    </body>
    </html>
    """#
}
