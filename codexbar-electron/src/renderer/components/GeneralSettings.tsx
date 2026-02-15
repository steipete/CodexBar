import React from 'react';

interface Settings {
  refreshInterval: number;
  showNotifications: boolean;
  startAtLogin: boolean;
  theme: 'system' | 'light' | 'dark';
}

interface Props {
  settings: Partial<Settings>;
  onChange: (key: string, value: any) => void;
}

export function GeneralSettings({ settings, onChange }: Props) {
  return (
    <div className="general-settings">
      <div className="settings-section">
        <h3>Data</h3>
        
        <div className="setting-row">
          <div>
            <div className="setting-label">Refresh Interval</div>
            <div className="setting-description">How often to sync usage data</div>
          </div>
          <select
            className="setting-input"
            value={settings.refreshInterval || 300}
            onChange={(e) => onChange('refreshInterval', parseInt(e.target.value))}
          >
            <option value={60}>Every minute</option>
            <option value={120}>Every 2 minutes</option>
            <option value={300}>Every 5 minutes</option>
            <option value={600}>Every 10 minutes</option>
            <option value={900}>Every 15 minutes</option>
            <option value={1800}>Every 30 minutes</option>
          </select>
        </div>
      </div>

      <div className="settings-section">
        <h3>Notifications</h3>
        
        <div className="setting-row">
          <div>
            <div className="setting-label">Usage Alerts</div>
            <div className="setting-description">Notify when usage exceeds 80%</div>
          </div>
          <label className="provider-toggle">
            <input
              type="checkbox"
              checked={settings.showNotifications ?? true}
              onChange={(e) => onChange('showNotifications', e.target.checked)}
            />
            <span className="toggle-slider" />
          </label>
        </div>
      </div>

      <div className="settings-section">
        <h3>System</h3>
        
        <div className="setting-row">
          <div>
            <div className="setting-label">Launch at Startup</div>
            <div className="setting-description">Start CodexBar when you log in</div>
          </div>
          <label className="provider-toggle">
            <input
              type="checkbox"
              checked={settings.startAtLogin ?? false}
              onChange={(e) => onChange('startAtLogin', e.target.checked)}
            />
            <span className="toggle-slider" />
          </label>
        </div>

        <div className="setting-row">
          <div>
            <div className="setting-label">Appearance</div>
            <div className="setting-description">Color theme preference</div>
          </div>
          <select
            className="setting-input"
            value={settings.theme || 'system'}
            onChange={(e) => onChange('theme', e.target.value)}
          >
            <option value="system">System</option>
            <option value="dark">Dark</option>
            <option value="light">Light</option>
          </select>
        </div>
      </div>
    </div>
  );
}
