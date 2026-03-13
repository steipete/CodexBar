const defaults = { baseUrl: 'http://127.0.0.1:8787', utilizationAlertPct: 80 };

function save() {
  const baseUrl = document.getElementById('baseUrl').value.trim() || defaults.baseUrl;
  const utilizationAlertPct = Number(document.getElementById('threshold').value || defaults.utilizationAlertPct);
  chrome.storage.sync.set({ baseUrl, utilizationAlertPct }, () => {
    const status = document.getElementById('status');
    status.textContent = 'Saved ✅';
    status.className = 'ok';
    setTimeout(() => status.textContent = '', 1200);
  });
}

function restore() {
  chrome.storage.sync.get(defaults, (v) => {
    document.getElementById('baseUrl').value = v.baseUrl;
    document.getElementById('threshold').value = v.utilizationAlertPct;
  });
}

document.getElementById('save').addEventListener('click', save);
restore();