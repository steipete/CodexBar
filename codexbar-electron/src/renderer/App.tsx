import React, { useEffect, useState } from 'react';
import { ProviderList } from './components/ProviderList';
import { GeneralSettings } from './components/GeneralSettings';

type Tab = 'providers' | 'general' | 'about';

export function App() {
  const [activeTab, setActiveTab] = useState<Tab>('providers');
  const [providers, setProviders] = useState<any[]>([]);
  const [settings, setSettings] = useState<any>({});

  useEffect(() => {
    // Load initial data
    loadData();
    
    // Subscribe to updates
    const unsubscribe = window.codexbar.onUpdate(() => {
      loadData();
    });
    
    return unsubscribe;
  }, []);

  async function loadData() {
    const [providerData, settingsData] = await Promise.all([
      window.codexbar.getProviders(),
      window.codexbar.getSettings(),
    ]);
    setProviders(providerData);
    setSettings(settingsData);
  }

  async function handleToggleProvider(id: string, enabled: boolean) {
    await window.codexbar.toggleProvider(id, enabled);
    await loadData();
  }

  async function handleSettingChange(key: string, value: any) {
    await window.codexbar.setSetting(key, value);
    await loadData();
  }

  async function handleRefresh() {
    await window.codexbar.refreshAll();
  }

  return (
    <div className="app">
      <header className="app-header">
        <h1>CodexBar Settings</h1>
        <button className="refresh-btn" onClick={handleRefresh}>
          ↻ Refresh
        </button>
      </header>

      <nav className="tabs">
        <button
          className={activeTab === 'providers' ? 'active' : ''}
          onClick={() => setActiveTab('providers')}
        >
          Providers
        </button>
        <button
          className={activeTab === 'general' ? 'active' : ''}
          onClick={() => setActiveTab('general')}
        >
          General
        </button>
        <button
          className={activeTab === 'about' ? 'active' : ''}
          onClick={() => setActiveTab('about')}
        >
          About
        </button>
      </nav>

      <main className="content">
        {activeTab === 'providers' && (
          <ProviderList
            providers={providers}
            onToggle={handleToggleProvider}
          />
        )}
        {activeTab === 'general' && (
          <GeneralSettings
            settings={settings}
            onChange={handleSettingChange}
          />
        )}
        {activeTab === 'about' && (
          <div className="about">
            <h2>CodexBar</h2>
            <p>Monitor API usage limits for AI providers</p>
            <p className="version">Version 0.1.0 (Windows Port)</p>
            <p>
              <a href="https://github.com/steipete/CodexBar" target="_blank" rel="noopener">
                GitHub Repository
              </a>
            </p>
            <p className="copyright">
              © 2024 CodexBar Contributors. MIT License.
            </p>
          </div>
        )}
      </main>
    </div>
  );
}
