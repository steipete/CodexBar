import React, { useEffect, useState } from 'react';
import { ProviderList } from './components/ProviderList';
import './styles.css';

type Tab = 'providers' | 'settings' | 'about';

interface Provider {
  id: string;
  name: string;
  icon: string;
  enabled: boolean;
  result: {
    state: 'idle' | 'loading' | 'success' | 'error';
    usage?: {
      session?: { used: number; limit: number; percentage: number; displayString: string };
      weekly?: { used: number; limit: number; percentage: number; displayString: string };
      monthly?: { used: number; limit: number; percentage: number; displayString: string };
    };
    error?: string;
  };
}

interface Settings {
  refreshInterval?: number;
  showNotifications?: boolean;
  startAtLogin?: boolean;
  theme?: string;
}

export function App() {
  const [tab, setTab] = useState<Tab>('providers');
  const [providers, setProviders] = useState<Provider[]>([]);
  const [settings, setSettings] = useState<Settings>({});
  const [refreshing, setRefreshing] = useState(false);

  useEffect(() => {
    loadData();
    const unsub = window.codexbar?.onUpdate(() => loadData());
    return () => unsub?.();
  }, []);

  const loadData = async () => {
    const [p, s] = await Promise.all([
      window.codexbar?.getProviders() ?? [],
      window.codexbar?.getSettings() ?? {},
    ]);
    setProviders(p);
    setSettings(s);
  };

  const handleRefresh = async () => {
    setRefreshing(true);
    await window.codexbar?.refreshAll();
    await loadData();
    setTimeout(() => setRefreshing(false), 400);
  };

  const toggleProvider = async (id: string, enabled: boolean) => {
    await window.codexbar?.toggleProvider(id, enabled);
    await loadData();
  };

  const updateSetting = async (key: string, value: any) => {
    await window.codexbar?.setSetting(key, value);
    await loadData();
  };

  return (
    <div className="app">
      <div className="titlebar-drag-region" />
      
      <header className="header">
        <div className="header-top">
          <div className="logo">
            <div className="logo-icon">C</div>
            <span className="logo-text">CodexBar</span>
          </div>
        </div>
        <div className="tabs">
          <button className={`tab ${tab === 'providers' ? 'active' : ''}`} onClick={() => setTab('providers')}>Providers</button>
          <button className={`tab ${tab === 'settings' ? 'active' : ''}`} onClick={() => setTab('settings')}>Settings</button>
          <button className={`tab ${tab === 'about' ? 'active' : ''}`} onClick={() => setTab('about')}>About</button>
        </div>
      </header>

      <main className="content">
        {tab === 'providers' && (
          <ProviderList providers={providers} onToggle={toggleProvider} />
        )}

        {tab === 'settings' && (
          <>
            <div className="settings-group">
              <div className="settings-title">Sync</div>
              <div className="setting-item">
                <div>
                  <div className="setting-label">Refresh Interval</div>
                  <div className="setting-desc">How often to sync usage data</div>
                </div>
                <select 
                  className="select-input" 
                  value={settings.refreshInterval || 300} 
                  onChange={e => updateSetting('refreshInterval', +e.target.value)}
                >
                  <option value={60}>1 min</option>
                  <option value={120}>2 min</option>
                  <option value={300}>5 min</option>
                  <option value={600}>10 min</option>
                  <option value={900}>15 min</option>
                </select>
              </div>
            </div>

            <div className="settings-group">
              <div className="settings-title">Notifications</div>
              <div className="setting-item">
                <div>
                  <div className="setting-label">Usage Alerts</div>
                  <div className="setting-desc">Notify when usage exceeds 80%</div>
                </div>
                <label className="toggle">
                  <input type="checkbox" checked={settings.showNotifications ?? true} onChange={e => updateSetting('showNotifications', e.target.checked)} />
                  <div className="toggle-track" />
                </label>
              </div>
            </div>

            <div className="settings-group">
              <div className="settings-title">System</div>
              <div className="setting-item">
                <div>
                  <div className="setting-label">Start at Login</div>
                  <div className="setting-desc">Launch CodexBar on startup</div>
                </div>
                <label className="toggle">
                  <input type="checkbox" checked={settings.startAtLogin ?? false} onChange={e => updateSetting('startAtLogin', e.target.checked)} />
                  <div className="toggle-track" />
                </label>
              </div>
            </div>
            
            <div className="settings-group">
              <div className="settings-title">Actions</div>
              <div className="setting-item" style={{ cursor: 'pointer' }} onClick={handleRefresh}>
                 <div>
                  <div className="setting-label">Refresh All Data</div>
                  <div className="setting-desc">Manually trigger a sync for all providers</div>
                </div>
                <div style={{ opacity: refreshing ? 0.5 : 1 }}>
                  {refreshing ? 'Syncing...' : 'Start'}
                </div>
              </div>
            </div>
          </>
        )}

        {tab === 'about' && (
          <div className="about-container">
            <div className="about-logo">⚡</div>
            <h1 style={{ fontSize: '18px', fontWeight: 600, marginBottom: '8px', color: 'var(--text-primary)' }}>CodexBar</h1>
            <p style={{ marginBottom: '16px', fontSize: '13px' }}>Monitor your AI usage across providers</p>
            <div className="about-version">v0.1.0 · Windows/Linux</div>
            <div style={{ display: 'flex', gap: '12px', justifyContent: 'center' }}>
              <a href="https://github.com/steipete/CodexBar" target="_blank" rel="noopener" className="btn-secondary">
                GitHub
              </a>
              <a href="https://github.com/steipete/CodexBar/issues" target="_blank" rel="noopener" className="btn-secondary">
                Report Issue
              </a>
            </div>
          </div>
        )}
      </main>
    </div>
  );
}
