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
    if (provider.result.state === 'loading') return 'Loading...';
    if (provider.result.state === 'error') return provider.result.error || 'Error';
    if (provider.result.state === 'success' && usage) return usage.displayString;
    return 'No data';
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
        <div className="provider-status">{getStatusText()}</div>
      </div>
      
      {provider.enabled && usage && (
        <div className="provider-usage">
          <div className="usage-bar">
            <div 
              className={`usage-bar-fill ${getBarClass()}`}
              style={{ width: `${Math.min(100, usage.percentage)}%` }}
            />
          </div>
          <div className="usage-text">{usage.percentage}%</div>
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
