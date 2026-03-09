chrome.runtime.onInstalled.addListener(() => {
  chrome.alarms.create('codexbar-refresh', { periodInMinutes: 15 });
});

chrome.alarms.onAlarm.addListener(async (alarm) => {
  if (alarm.name !== 'codexbar-refresh') return;

  const defaults = { baseUrl: 'http://127.0.0.1:8787', utilizationAlertPct: 80 };
  const settings = await chrome.storage.sync.get(defaults);
  const base = settings.baseUrl.replace(/\/$/, '');

  try {
    const res = await fetch(`${base}/api/usage/summary?range=weekly`);
    const json = await res.json();
    if (!res.ok || json.ok === false) return;
    const util = json?.data?.utilizationPct;
    if (typeof util === 'number' && util >= settings.utilizationAlertPct) {
      chrome.notifications.create({
        type: 'basic',
        iconUrl: 'icons/icon128.png',
        title: 'CodexBar Usage Alert',
        message: `Weekly utilization is ${util.toFixed(1)}%`,
      });
    }
  } catch (_) {
    // silent fail for bridge offline
  }
});