import React from 'react';

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

interface Props {
  providers: Provider[];
  onToggle: (id: string, enabled: boolean) => void;
}

export function ProviderList({ providers, onToggle }: Props) {
  if (providers.length === 0) {
    return (
      <div style={{ padding: '24px', textAlign: 'center', color: 'var(--text-secondary)' }}>
        Loading providers...
      </div>
    );
  }

  return (
    <div className="provider-grid">
      {providers.map((provider) => (
        <ProviderCard
          key={provider.id}
          provider={provider}
          onToggle={onToggle}
        />
      ))}
    </div>
  );
}

function ProviderCard({ provider, onToggle }: { provider: Provider; onToggle: Props['onToggle'] }) {
  // Usage Ring Logic
  const usage = provider.result.usage?.session || 
                provider.result.usage?.weekly || 
                provider.result.usage?.monthly;
  
  const percentage = usage ? Math.min(100, Math.max(0, usage.percentage)) : 0;
  const radius = 13; // 32px box, ring needs to fit
  const circumference = 2 * Math.PI * radius;
  const strokeDashoffset = circumference - (percentage / 100) * circumference;

  const getStatusClass = () => {
    if (!provider.enabled) return '';
    if (provider.result.state === 'loading') return 'loading';
    if (provider.result.state === 'error') return 'error';
    if (provider.result.state === 'success') return 'connected';
    return ''; // idle
  };

  const getStatusText = () => {
    if (!provider.enabled) return 'Disabled';
    if (provider.result.state === 'loading') return 'Syncing...';
    if (provider.result.state === 'error') return provider.result.error || 'Error';
    if (provider.result.state === 'success' && usage) return usage.displayString;
    if (provider.result.state === 'success') return 'Connected';
    return 'Idle';
  };

  const getUsageColorClass = () => {
    if (percentage >= 90) return 'critical';
    if (percentage >= 70) return 'warning';
    return '';
  };

  return (
    <div className={`provider-card ${!provider.enabled ? 'disabled' : ''}`}>
      <div className="provider-info">
        <div className="provider-name">{provider.name}</div>
        <div className={`status-badge ${getStatusClass()}`}>
          {provider.enabled && <div className="status-dot" />}
          <span>{getStatusText()}</span>
        </div>
      </div>
      
      {provider.enabled && usage && usage.limit > 0 && (
        <div className="usage-display">
          <div className="usage-ring-container">
            <svg className="usage-ring-svg" viewBox="0 0 32 32">
              <circle 
                className="usage-ring-bg" 
                cx="16" cy="16" r={radius} 
              />
              <circle 
                className={`usage-ring-value ${getUsageColorClass()}`}
                cx="16" cy="16" r={radius}
                style={{ strokeDasharray: circumference, strokeDashoffset }}
              />
            </svg>
            <div className="usage-text">{percentage}%</div>
          </div>
        </div>
      )}
      
      <label className="toggle">
        <input
          type="checkbox"
          checked={provider.enabled}
          onChange={(e) => onToggle(provider.id, e.target.checked)}
        />
        <div className="toggle-track" />
      </label>
    </div>
  );
}
