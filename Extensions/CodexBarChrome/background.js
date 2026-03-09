chrome.runtime.onInstalled.addListener(() => {
  chrome.alarms.create('codexbar-refresh', { periodInMinutes: 15 });
  chrome.action.setBadgeText({ text: '' });
});

function badgeForUtil(util) {
  if (typeof util !== 'number') return { text: '', color: '#64748b' };
  if (util >= 90) return { text: 'HIGH', color: '#dc2626' };
  if (util >= 70) return { text: 'MID', color: '#d97706' };
  return { text: 'OK', color: '#15803d' };
}

async function refreshOnce() {
  const defaults = { baseUrl: 'http://127.0.0.1:8787', utilizationAlertPct: 80 };
  const settings = await chrome.storage.sync.get(defaults);
  const base = settings.baseUrl.replace(/\/$/, '');

  try {
    const res = await fetch(`${base}/api/usage/summary?range=weekly`);
    const json = await res.json();
    if (!res.ok || json.ok === false) {
      chrome.action.setBadgeText({ text: 'OFF' });
      chrome.action.setBadgeBackgroundColor({ color: '#6b7280' });
      return;
    }
    const util = json?.data?.utilizationPct;
    const badge = badgeForUtil(util);
    chrome.action.setBadgeText({ text: badge.text });
    chrome.action.setBadgeBackgroundColor({ color: badge.color });

    if (typeof util === 'number' && util >= settings.utilizationAlertPct) {
      chrome.notifications.create({
        type: 'basic',
        iconUrl: 'icons/icon128.png',
        title: 'CodexBar Usage Alert',
        message: `Weekly utilization is ${util.toFixed(1)}%`,
      });
    }
  } catch (_) {
    chrome.action.setBadgeText({ text: 'OFF' });
    chrome.action.setBadgeBackgroundColor({ color: '#6b7280' });
  }
}

chrome.alarms.onAlarm.addListener(async (alarm) => {
  if (alarm.name !== 'codexbar-refresh') return;
  await refreshOnce();
});

chrome.runtime.onStartup?.addListener(() => {
  refreshOnce();
});