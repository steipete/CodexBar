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
      <div className="empty-state">
        <div className="empty-state-icon">📡</div>
        <p className="empty-state-text">Loading providers...</p>
      </div>
    );
  }

  return (
    <div className="provider-list">
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
  const usage = provider.result.usage?.session || 
                provider.result.usage?.weekly || 
                provider.result.usage?.monthly;
  
  const getStatusText = () => {
    if (!provider.enabled) return 'Disabled';
    if (provider.result.state === 'loading') return 'Syncing...';
    if (provider.result.state === 'error') return provider.result.error || 'Connection error';
    if (provider.result.state === 'success' && usage) {
      return usage.displayString;
    }
    if (provider.result.state === 'success') return 'Connected';
    return 'Not configured';
  };

  const getStatusClass = () => {
    if (!provider.enabled) return '';
    if (provider.result.state === 'success') return 'success';
    if (provider.result.state === 'error') return 'error';
    return '';
  };

  const getPercentageClass = () => {
    if (!usage) return '';
    if (usage.percentage >= 90) return 'critical';
    if (usage.percentage >= 70) return 'warning';
    return '';
  };

  const getBarClass = () => {
    if (!usage) return '';
    if (usage.percentage >= 90) return 'critical';
    if (usage.percentage >= 70) return 'warning';
    return '';
  };

  return (
    <div className={`provider-card ${!provider.enabled ? 'disabled' : ''}`}>
      <div className="provider-icon">{provider.icon}</div>
      
      <div className="provider-info">
        <div className="provider-name">{provider.name}</div>
        <div className={`provider-status ${getStatusClass()}`}>
          {getStatusText()}
        </div>
      </div>
      
      {provider.enabled && usage && usage.limit > 0 && (
        <div className="provider-usage">
          <div className={`usage-percentage ${getPercentageClass()}`}>
            {usage.percentage}%
          </div>
          <div className="usage-bar-container">
            <div 
              className={`usage-bar-fill ${getBarClass()}`}
              style={{ width: `${Math.min(100, usage.percentage)}%` }}
            />
          </div>
          <div className="usage-details">
            {usage.used.toLocaleString()} / {usage.limit.toLocaleString()}
          </div>
        </div>
      )}
      
      <label className="provider-toggle">
        <input
          type="checkbox"
          checked={provider.enabled}
          onChange={(e) => onToggle(provider.id, e.target.checked)}
        />
        <span className="toggle-slider" />
      </label>
    </div>
  );
}
