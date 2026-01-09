import React, { useEffect, useState } from 'react';
import { ProviderList } from './components/ProviderList';
import { GeneralSettings } from './components/GeneralSettings';
import './styles.css';

type Tab = 'providers' | 'general' | 'about';

export function App() {
  const [activeTab, setActiveTab] = useState<Tab>('providers');
  const [providers, setProviders] = useState<any[]>([]);
  const [settings, setSettings] = useState<any>({});
  const [isRefreshing, setIsRefreshing] = useState(false);

  useEffect(() => {
    loadData();
    
    const unsubscribe = window.codexbar?.onUpdate(() => {
      loadData();
    });
    
    return () => unsubscribe?.();
  }, []);

  async function loadData() {
    try {
      const [providerData, settingsData] = await Promise.all([
        window.codexbar?.getProviders() ?? [],
        window.codexbar?.getSettings() ?? {},
      ]);
      setProviders(providerData);
      setSettings(settingsData);
    } catch (err) {
      console.error('Failed to load data:', err);
    }
  }

  async function handleToggleProvider(id: string, enabled: boolean) {
    await window.codexbar?.toggleProvider(id, enabled);
    await loadData();
  }

  async function handleSettingChange(key: string, value: any) {
    await window.codexbar?.setSetting(key, value);
    await loadData();
  }

  async function handleRefresh() {
    setIsRefreshing(true);
    try {
      await window.codexbar?.refreshAll();
      await loadData();
    } finally {
      setTimeout(() => setIsRefreshing(false), 500);
    }
  }

  return (
    <div className="app">
      <header className="app-header">
        <h1>CodexBar</h1>
        <button 
          className="refresh-btn" 
          onClick={handleRefresh}
          disabled={isRefreshing}
        >
          <svg 
            viewBox="0 0 24 24" 
            fill="none" 
            stroke="currentColor" 
            strokeWidth="2"
            style={{
              animation: isRefreshing ? 'spin 1s linear infinite' : 'none'
            }}
          >
            <path d="M21 12a9 9 0 0 1-9 9m9-9a9 9 0 0 0-9-9m9 9H3m9 9a9 9 0 0 1-9-9m9 9c-1.657 0-3-4.03-3-9s1.343-9 3-9m0 18c1.657 0 3-4.03 3-9s-1.343-9-3-9" />
          </svg>
          {isRefreshing ? 'Refreshing...' : 'Refresh'}
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
          Settings
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
            <div className="about-logo">⚡</div>
            <h2>CodexBar</h2>
            <p className="about-tagline">Monitor your AI usage, beautifully.</p>
            <span className="version">v0.1.0 • Windows</span>
            <div className="about-links">
              <a 
                href="https://github.com/steipete/CodexBar" 
                target="_blank" 
                rel="noopener noreferrer"
                className="about-link"
              >
                <svg width="16" height="16" viewBox="0 0 24 24" fill="currentColor">
                  <path d="M12 0c-6.626 0-12 5.373-12 12 0 5.302 3.438 9.8 8.207 11.387.599.111.793-.261.793-.577v-2.234c-3.338.726-4.033-1.416-4.033-1.416-.546-1.387-1.333-1.756-1.333-1.756-1.089-.745.083-.729.083-.729 1.205.084 1.839 1.237 1.839 1.237 1.07 1.834 2.807 1.304 3.492.997.107-.775.418-1.305.762-1.604-2.665-.305-5.467-1.334-5.467-5.931 0-1.311.469-2.381 1.236-3.221-.124-.303-.535-1.524.117-3.176 0 0 1.008-.322 3.301 1.23.957-.266 1.983-.399 3.003-.404 1.02.005 2.047.138 3.006.404 2.291-1.552 3.297-1.23 3.297-1.23.653 1.653.242 2.874.118 3.176.77.84 1.235 1.911 1.235 3.221 0 4.609-2.807 5.624-5.479 5.921.43.372.823 1.102.823 2.222v3.293c0 .319.192.694.801.576 4.765-1.589 8.199-6.086 8.199-11.386 0-6.627-5.373-12-12-12z"/>
                </svg>
                GitHub
              </a>
              <a 
                href="https://github.com/steipete/CodexBar/issues" 
                target="_blank" 
                rel="noopener noreferrer"
                className="about-link"
              >
                Feedback
              </a>
            </div>
            <p className="copyright">
              Made with ♥ by CodexBar Contributors
            </p>
          </div>
        )}
      </main>

      <style>{`
        @keyframes spin {
          from { transform: rotate(0deg); }
          to { transform: rotate(360deg); }
        }
      `}</style>
    </div>
  );
}
