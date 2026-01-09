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
        <h3>Refresh</h3>
        
        <div className="setting-row">
          <div>
            <div className="setting-label">Refresh Interval</div>
            <div className="setting-description">How often to check for usage updates</div>
          </div>
          <select
            className="setting-input"
            value={settings.refreshInterval || 300}
            onChange={(e) => onChange('refreshInterval', parseInt(e.target.value))}
          >
            <option value={60}>1 minute</option>
            <option value={120}>2 minutes</option>
            <option value={300}>5 minutes</option>
            <option value={600}>10 minutes</option>
            <option value={900}>15 minutes</option>
            <option value={1800}>30 minutes</option>
          </select>
        </div>
      </div>

      <div className="settings-section">
        <h3>Notifications</h3>
        
        <div className="setting-row">
          <div>
            <div className="setting-label">Show Notifications</div>
            <div className="setting-description">Get notified when usage is high</div>
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
            <div className="setting-label">Start at Login</div>
            <div className="setting-description">Launch CodexBar when you log in</div>
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
            <div className="setting-label">Theme</div>
            <div className="setting-description">Application color scheme</div>
          </div>
          <select
            className="setting-input"
            value={settings.theme || 'system'}
            onChange={(e) => onChange('theme', e.target.value)}
          >
            <option value="system">System</option>
            <option value="light">Light</option>
            <option value="dark">Dark</option>
          </select>
        </div>
      </div>
    </div>
  );
}
