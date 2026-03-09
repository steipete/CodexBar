const defaults = {
  baseUrl: 'http://127.0.0.1:8787',
  utilizationAlertPct: 80,
};

async function getSettings() {
  return new Promise((resolve) => {
    chrome.storage.sync.get(defaults, (v) => resolve(v));
  });
}

function setStatus(msg, ok = true) {
  const el = document.getElementById('status');
  el.textContent = msg;
  el.className = ok ? 'ok' : 'err';
}

function fmt(n) {
  if (n === null || n === undefined || Number.isNaN(Number(n))) return '-';
  return Number(n).toLocaleString(undefined, { maximumFractionDigits: 2 });
}

async function fetchJson(url) {
  const res = await fetch(url);
  const json = await res.json();
  if (!res.ok || json.ok === false) throw new Error(json.error || `HTTP ${res.status}`);
  return json;
}

async function refresh() {
  const settings = await getSettings();
  const range = document.getElementById('range').value;
  const base = settings.baseUrl.replace(/\/$/, '');
  try {
    setStatus('Loading…', true);
    const [summary, models] = await Promise.all([
      fetchJson(`${base}/api/usage/summary?range=${range}`),
      fetchJson(`${base}/api/usage/models?range=${range}`),
    ]);

    const d = summary.data;
    document.getElementById('used').textContent = fmt(d.totalUsed);
    document.getElementById('limit').textContent = fmt(d.totalLimit);
    document.getElementById('util').textContent = d.utilizationPct == null ? '-' : `${fmt(d.utilizationPct)}%`;
    document.getElementById('cost').textContent = fmt(d.costUsd);
    document.getElementById('providers').textContent = fmt(d.providerCount);
    document.getElementById('models').textContent = fmt(d.modelCount);

    const top = (models.data.models || []).slice(0, 6);
    const tbody = document.getElementById('modelRows');
    tbody.innerHTML = top.length
      ? top.map(m => `<tr><td>${m.provider}/${m.model}</td><td>${fmt(m.used)}</td><td>${m.utilizationPct == null ? '-' : fmt(m.utilizationPct) + '%'}</td></tr>`).join('')
      : '<tr><td colspan="3" class="muted">No model data</td></tr>';

    setStatus(`Connected • ${range}`, true);
  } catch (e) {
    setStatus(`Bridge unavailable: ${e.message}`, false);
  }
}

document.getElementById('refresh').addEventListener('click', refresh);
document.getElementById('range').addEventListener('change', refresh);
document.getElementById('openOptions').addEventListener('click', () => chrome.runtime.openOptionsPage());

refresh();