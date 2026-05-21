// swiftlint:disable file_length
enum CLIWebUI {
    // Single-file web UI served at / by `codexbar serve`.
    // Replicates the macOS popover layout: provider tabs, usage bars, reset countdowns, cost section.
    static let html = #"""
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8"/>
<meta name="viewport" content="width=device-width,initial-scale=1"/>
<title>CodexBar</title>
<style>
  :root {
    --bg: #1a1a2e;
    --card: rgba(255,255,255,0.06);
    --card-border: rgba(255,255,255,0.10);
    --text: #f0f0f0;
    --text-secondary: rgba(240,240,240,0.55);
    --track: rgba(255,255,255,0.12);
    --divider: rgba(255,255,255,0.08);
    --tab-active-bg: rgba(255,255,255,0.13);
    --tab-hover-bg: rgba(255,255,255,0.07);
    --error: #ff6b6b;
    --green: #34c759;
    --red: #ff3b30;
  }
  * { box-sizing: border-box; margin: 0; padding: 0; }
  body {
    font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", system-ui, sans-serif;
    background: var(--bg);
    color: var(--text);
    min-height: 100vh;
    display: flex;
    justify-content: center;
    padding: 24px 16px;
  }
  .shell {
    width: 100%;
    max-width: 400px;
  }

  /* ── top bar ── */
  .topbar {
    display: flex;
    align-items: center;
    justify-content: space-between;
    margin-bottom: 16px;
  }
  .topbar-title {
    display: flex;
    align-items: center;
    gap: 8px;
    font-size: 15px;
    font-weight: 600;
  }
  .topbar-title svg { opacity: 0.9; }
  .refresh-btn {
    background: none;
    border: none;
    color: var(--text-secondary);
    cursor: pointer;
    padding: 4px;
    border-radius: 6px;
    display: flex;
    align-items: center;
    transition: color 0.15s, background 0.15s;
  }
  .refresh-btn:hover { color: var(--text); background: var(--tab-hover-bg); }
  .refresh-btn.spinning svg { animation: spin 0.7s linear infinite; }
  @keyframes spin { to { transform: rotate(360deg); } }

  /* ── provider tabs ── */
  .tabs {
    display: flex;
    gap: 4px;
    overflow-x: auto;
    scrollbar-width: none;
    padding-bottom: 12px;
    margin-bottom: 4px;
  }
  .tabs::-webkit-scrollbar { display: none; }
  .tab {
    display: flex;
    flex-direction: column;
    align-items: center;
    gap: 4px;
    padding: 6px 10px;
    border-radius: 10px;
    cursor: pointer;
    border: none;
    background: none;
    color: var(--text-secondary);
    font-size: 11px;
    font-weight: 500;
    white-space: nowrap;
    transition: background 0.15s, color 0.15s;
    min-width: 52px;
    position: relative;
  }
  .tab:hover { background: var(--tab-hover-bg); color: var(--text); }
  .tab.active { background: var(--tab-active-bg); color: var(--text); }
  .tab-icon {
    width: 22px;
    height: 22px;
    border-radius: 6px;
    display: flex;
    align-items: center;
    justify-content: center;
    font-size: 13px;
    font-weight: 700;
  }
  .tab-bar {
    position: absolute;
    bottom: 3px;
    left: 10px;
    right: 10px;
    height: 2px;
    border-radius: 1px;
    opacity: 0;
    transition: opacity 0.15s;
  }
  .tab.active .tab-bar { opacity: 1; }

  /* ── card ── */
  .card {
    background: var(--card);
    border: 1px solid var(--card-border);
    border-radius: 16px;
    padding: 16px;
    display: none;
  }
  .card.visible { display: block; }

  /* ── card header ── */
  .card-header { margin-bottom: 14px; }
  .card-header-row {
    display: flex;
    justify-content: space-between;
    align-items: baseline;
  }
  .provider-name { font-size: 17px; font-weight: 600; }
  .plan-badge {
    font-size: 12px;
    color: var(--text-secondary);
    font-weight: 500;
  }
  .updated-text {
    font-size: 12px;
    color: var(--text-secondary);
    margin-top: 2px;
  }
  .error-text { font-size: 12px; color: var(--error); margin-top: 4px; }

  /* ── usage metric ── */
  .metric { margin-bottom: 14px; }
  .metric:last-child { margin-bottom: 0; }
  .metric-header {
    display: flex;
    justify-content: space-between;
    align-items: baseline;
    margin-bottom: 6px;
  }
  .metric-label { font-size: 14px; font-weight: 500; }
  .metric-pct {
    font-size: 13px;
    color: var(--text-secondary);
  }
  .track {
    width: 100%;
    height: 6px;
    background: var(--track);
    border-radius: 3px;
    overflow: visible;
    position: relative;
  }
  .fill {
    height: 100%;
    border-radius: 3px;
    min-width: 0;
    transition: width 0.4s ease;
  }
  .pace-line {
    position: absolute;
    top: -2px;
    width: 2px;
    height: 10px;
    border-radius: 1px;
    opacity: 0.85;
  }
  .metric-footer {
    display: flex;
    justify-content: space-between;
    align-items: center;
    margin-top: 5px;
  }
  .reset-text { font-size: 12px; color: var(--text-secondary); }
  .pace-text { font-size: 12px; }
  .pace-behind { color: var(--red); }
  .pace-ahead  { color: var(--green); }

  /* ── divider ── */
  .divider {
    height: 1px;
    background: var(--divider);
    margin: 12px 0;
  }

  /* ── credits / cost ── */
  .section-label {
    font-size: 14px;
    font-weight: 500;
    margin-bottom: 8px;
  }
  .cost-row {
    display: flex;
    justify-content: space-between;
    font-size: 13px;
    color: var(--text-secondary);
    margin-bottom: 4px;
  }
  .cost-row span:last-child { color: var(--text); }

  /* ── status badge ── */
  .status-badge {
    display: inline-block;
    width: 7px;
    height: 7px;
    border-radius: 50%;
    margin-right: 5px;
    vertical-align: middle;
  }

  /* ── skeleton / empty ── */
  .skeleton {
    background: var(--track);
    border-radius: 4px;
    animation: pulse 1.4s ease-in-out infinite;
  }
  @keyframes pulse { 0%,100%{opacity:0.4} 50%{opacity:0.9} }

  /* ── error card ── */
  .error-card {
    background: var(--card);
    border: 1px solid var(--card-border);
    border-radius: 16px;
    padding: 20px;
    text-align: center;
    color: var(--text-secondary);
    font-size: 13px;
    display: none;
  }
  .error-card.visible { display: block; }

  /* ── footer ── */
  .footer {
    text-align: center;
    font-size: 11px;
    color: var(--text-secondary);
    margin-top: 20px;
    opacity: 0.5;
  }

  /* ── responsive ── */
  @media (max-width: 440px) {
    body { padding: 16px 8px; }
  }
</style>
</head>
<body>
<div class="shell">

  <div class="topbar">
    <div class="topbar-title">
      <svg width="20" height="20" viewBox="0 0 20 20" fill="none">
        <rect width="20" height="20" rx="5" fill="rgba(255,255,255,0.12)"/>
        <rect x="4" y="13" width="3" height="4" rx="1" fill="white"/>
        <rect x="8.5" y="9" width="3" height="8" rx="1" fill="white" opacity="0.7"/>
        <rect x="13" y="5" width="3" height="12" rx="1" fill="white" opacity="0.4"/>
      </svg>
      CodexBar
    </div>
    <button class="refresh-btn" id="refreshBtn" title="Refresh" onclick="refresh()">
      <svg id="refreshIcon" width="16" height="16" viewBox="0 0 16 16" fill="none">
        <path d="M13.65 2.35A8 8 0 1 0 15 8h-2a6 6 0 1 1-1.06-3.39L10 6h5V1l-1.35 1.35z" fill="currentColor"/>
      </svg>
    </button>
  </div>

  <div class="tabs" id="tabs"></div>
  <div id="cards"></div>
  <div class="error-card" id="errorCard">
    <div style="font-size:28px;margin-bottom:8px">⚠️</div>
    <div id="errorMsg">Could not connect to CodexBar server.</div>
    <div style="margin-top:6px;font-size:11px">Make sure <code>codexbar serve</code> is running.</div>
  </div>

  <div class="footer">CodexBar • <span id="lastUpdated"></span></div>
</div>

<script>
const PROVIDER_COLORS = {
  claude:       [204,124,94],
  codex:        [73,163,176],
  cursor:       [0,191,165],
  gemini:       [171,135,234],
  copilot:      [168,85,247],
  openrouter:   [100,103,242],
  deepseek:     [82,125,240],
  grok:         [16,163,127],
  windsurf:     [52,232,187],
  kiro:         [255,153,0],
  kilo:         [242,112,39],
  warp:         [147,139,180],
  augment:      [99,102,241],
  jetbrains:    [255,51,153],
  ollama:       [136,136,136],
  amp:          [220,38,38],
  opencode:     [59,130,246],
  vertexai:     [66,133,244],
  mistral:      [255,80,15],
  perplexity:   [32,178,170],
  abacus:       [56,189,248],
  venice:       [51,153,255],
  moonshot:     [32,93,235],
  minimax:      [254,96,60],
  kimi:         [254,96,60],
  manus:        [52,50,45],
  codebuff:     [68,255,0],
  zai:          [232,90,106],
  antigravity:  [96,186,126],
  factory:      [255,107,53],
  stepfun:      [33,150,243],
  alibaba:      [255,106,0],
};

const PROVIDER_INITIALS = {
  claude:'Cl', codex:'Cx', cursor:'Cu', gemini:'Gm', copilot:'Co',
  openrouter:'OR', deepseek:'DS', grok:'Gk', windsurf:'Ws', kiro:'Ki',
  kilo:'Kl', warp:'Wp', augment:'Au', jetbrains:'JB', ollama:'Ol',
  amp:'Amp', opencode:'OC', vertexai:'VA', mistral:'Mi', perplexity:'Px',
  abacus:'Ab', venice:'Ve', moonshot:'Ms', minimax:'MM', kimi:'Km',
  manus:'Mn', codebuff:'Cb', zai:'Za', antigravity:'Ag', factory:'Fc',
  stepfun:'SF', alibaba:'Al',
};

function providerColor(id) {
  const rgb = PROVIDER_COLORS[id?.toLowerCase()] || [120,120,140];
  return `rgb(${rgb[0]},${rgb[1]},${rgb[2]})`;
}
function providerInitial(id, name) {
  return PROVIDER_INITIALS[id?.toLowerCase()] || (name||id||'?').slice(0,2);
}

function relativeTime(dateStr) {
  if (!dateStr) return null;
  const diff = (Date.now() - new Date(dateStr).getTime()) / 1000;
  if (diff < 5)  return 'just now';
  if (diff < 60) return `${Math.round(diff)}s ago`;
  if (diff < 3600) return `${Math.round(diff/60)}m ago`;
  return `${Math.round(diff/3600)}h ago`;
}

function formatCountdown(dateStr) {
  if (!dateStr) return null;
  const secs = Math.max(0, (new Date(dateStr).getTime() - Date.now()) / 1000);
  if (secs <= 0) return 'Resetting…';
  const d = Math.floor(secs / 86400);
  const h = Math.floor((secs % 86400) / 3600);
  const m = Math.floor((secs % 3600) / 60);
  if (d > 0) return `Resets in ${d}d ${h}h`;
  if (h > 0) return `Resets in ${h}h ${m}m`;
  return `Resets in ${m}m`;
}

function statusColor(indicator) {
  switch (indicator) {
    case 'none': return '#34c759';
    case 'minor': return '#ff9f0a';
    case 'major': case 'critical': return '#ff3b30';
    default: return '#8e8e93';
  }
}

function buildMetric(label, window, color, extraDetail) {
  if (!window) return '';
  const pct = Math.min(100, Math.max(0, window.usedPercent || 0));
  const pctLabel = pct < 1 ? '0% used' : `${Math.round(pct)}% used`;
  const resetLabel = window.resetsAt ? formatCountdown(window.resetsAt)
                   : window.resetDescription || '';

  let paceHTML = '';
  if (window.pacePercent != null) {
    const diff = window.pacePercent - pct;
    const sign = diff >= 0 ? '+' : '';
    const cls  = diff < 0 ? 'pace-behind' : 'pace-ahead';
    paceHTML = `<span class="pace-text ${cls}">Pace: ${sign}${Math.round(diff)}%</span>`;
  }

  let paceLineHTML = '';
  if (window.pacePercent != null) {
    const pacePct = Math.min(100, Math.max(0, window.pacePercent));
    const lineColor = window.pacePercent > pct ? 'var(--red)' : 'var(--green)';
    paceLineHTML = `<div class="pace-line" style="left:${pacePct}%;background:${lineColor}"></div>`;
  }

  const extra = extraDetail ? `<div class="reset-text" style="margin-top:2px">${extraDetail}</div>` : '';

  return `
    <div class="metric">
      <div class="metric-header">
        <span class="metric-label">${label}</span>
        <span class="metric-pct">${pctLabel}</span>
      </div>
      <div class="track">
        <div class="fill" style="width:${pct}%;background:${color}"></div>
        ${paceLineHTML}
      </div>
      <div class="metric-footer">
        <span class="reset-text">${resetLabel}</span>
        ${paceHTML}
      </div>
      ${extra}
    </div>`;
}

function buildCredits(credits, color) {
  if (!credits) return '';
  const remaining = credits.remaining;
  if (remaining == null) return '';
  const total = credits.total ?? null;
  const pct = (total && total > 0) ? Math.min(100, (remaining / total) * 100) : null;
  return `
    <div class="divider"></div>
    <div class="section-label">Credits</div>
    <div class="metric">
      ${pct != null ? `
      <div class="track" style="margin-bottom:6px">
        <div class="fill" style="width:${pct}%;background:${color}"></div>
      </div>` : ''}
      <div class="cost-row">
        <span>Remaining</span>
        <span>$${remaining.toFixed(2)}</span>
      </div>
      ${total != null ? `<div class="cost-row"><span>Total</span><span>$${total.toFixed(2)}</span></div>` : ''}
    </div>`;
}

function buildProviderCost(providerCost, color) {
  if (!providerCost) return '';
  const used = providerCost.used ?? 0;
  const limit = providerCost.limit ?? 0;
  const pct = (limit > 0) ? Math.min(100, (used / limit) * 100) : 0;
  const currency = providerCost.currencyCode || 'USD';
  return `
    <div class="divider"></div>
    <div class="section-label">Extra usage</div>
    <div class="metric">
      <div class="track" style="margin-bottom:6px">
        <div class="fill" style="width:${pct}%;background:${color}"></div>
      </div>
      <div class="cost-row">
        <span>This month</span>
        <span>$${used.toFixed(2)} / $${limit.toFixed(2)} ${currency}</span>
      </div>
    </div>`;
}

function buildCard(provider) {
  const id = provider.provider || '';
  const name = provider.usage?.identity?.displayName || id;
  const color = providerColor(id);
  const usage = provider.usage || {};
  const updatedAt = usage.updatedAt || provider.updatedAt;
  const plan = usage.identity?.planName || '';
  const account = usage.identity?.email || provider.account || '';
  const err = provider.error;

  let statusDot = '';
  if (provider.status?.indicator && provider.status.indicator !== 'none') {
    statusDot = `<span class="status-badge" style="background:${statusColor(provider.status.indicator)}"></span>`;
  }

  let body = '';
  if (err) {
    body = `<div class="error-text">${statusDot}${err.message || 'Error fetching data'}</div>`;
  } else {
    const meta = usage.identity || {};
    const sessionLabel = meta.sessionLabel || 'Session';
    const weeklyLabel  = meta.weeklyLabel  || 'Weekly';
    const tertiaryLabel = meta.opusLabel   || 'Opus';

    body += buildMetric(sessionLabel, usage.primary, color);
    body += buildMetric(weeklyLabel, usage.secondary, color,
      usage.secondary?.pacePercent != null
        ? (usage.secondary.pacePercent < (usage.secondary.usedPercent||0)
            ? `Pace: Behind (${Math.round(usage.secondary.pacePercent - (usage.secondary.usedPercent||0))}%) · Lasts to reset`
            : null)
        : null);
    if (usage.tertiary) body += buildMetric(tertiaryLabel, usage.tertiary, color);

    if (usage.extraRateWindows) {
      for (const w of usage.extraRateWindows) {
        body += buildMetric(w.label || w.name, w.window, color);
      }
    }

    body += buildProviderCost(usage.providerCost, color);
    body += buildCredits(provider.credits, color);
  }

  const updatedLabel = updatedAt ? `Updated ${relativeTime(updatedAt)}` : '';

  return `
    <div class="card" id="card-${id}">
      <div class="card-header">
        <div class="card-header-row">
          <span class="provider-name">${statusDot}${name}</span>
          ${plan ? `<span class="plan-badge">${plan}</span>` : ''}
        </div>
        ${account ? `<div class="updated-text">${account}</div>` : ''}
        <div class="updated-text">${updatedLabel}</div>
      </div>
      ${body}
    </div>`;
}

function buildTab(provider) {
  const id = provider.provider || '';
  const name = provider.usage?.identity?.displayName || id;
  const color = providerColor(id);
  const initial = providerInitial(id, name);
  const pct = provider.usage?.primary?.usedPercent || 0;
  const hasError = !!provider.error;

  return `
    <button class="tab" id="tab-${id}" onclick="selectTab('${id}')">
      <div class="tab-icon" style="background:${color}22;color:${color}">
        ${hasError ? '!' : initial}
      </div>
      <span>${name.length > 7 ? name.slice(0,7) : name}</span>
      <div class="tab-bar" style="background:${color}"></div>
    </button>`;
}

let currentTab = null;
let allProviders = [];

function selectTab(id) {
  currentTab = id;
  document.querySelectorAll('.tab').forEach(t => t.classList.remove('active'));
  document.querySelectorAll('.card').forEach(c => c.classList.remove('visible'));
  const tab = document.getElementById(`tab-${id}`);
  const card = document.getElementById(`card-${id}`);
  if (tab) tab.classList.add('active');
  if (card) card.classList.add('visible');
}

function renderProviders(providers) {
  allProviders = providers;
  const tabsEl  = document.getElementById('tabs');
  const cardsEl = document.getElementById('cards');
  tabsEl.innerHTML  = providers.map(buildTab).join('');
  cardsEl.innerHTML = providers.map(buildCard).join('');
  document.getElementById('lastUpdated').textContent = new Date().toLocaleTimeString();

  const firstId = providers[0]?.provider;
  selectTab(currentTab && providers.find(p => p.provider === currentTab) ? currentTab : firstId);
}

async function load() {
  const btn = document.getElementById('refreshBtn');
  btn.classList.add('spinning');
  document.getElementById('errorCard').classList.remove('visible');

  try {
    const res = await fetch('/usage');
    if (!res.ok) throw new Error(`HTTP ${res.status}`);
    const data = await res.json();
    if (!Array.isArray(data) || data.length === 0) throw new Error('No providers returned');
    renderProviders(data);
  } catch (e) {
    document.getElementById('errorMsg').textContent = `Error: ${e.message}`;
    document.getElementById('errorCard').classList.add('visible');
  } finally {
    btn.classList.remove('spinning');
  }
}

function refresh() { load(); }

// Auto-refresh every 60 seconds
load();
setInterval(load, 60000);

// Update relative timestamps every 30s without re-fetching
setInterval(() => {
  if (allProviders.length) renderProviders(allProviders);
}, 30000);
</script>
</body>
</html>
"""#
}
// swiftlint:enable file_length
