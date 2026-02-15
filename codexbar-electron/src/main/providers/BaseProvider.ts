/**
 * Base Provider Interface
 * 
 * All AI providers must implement this interface.
 * Mirrors the Swift architecture from the macOS app.
 */

export interface UsageInfo {
  /** Amount used (requests, tokens, or credits depending on provider) */
  used: number;
  /** Maximum limit */
  limit: number;
  /** Percentage used (0-100) */
  percentage: number;
  /** Human-readable usage string */
  displayString: string;
  /** When the usage resets (ISO 8601) */
  resetTime?: string;
  /** Human-readable reset countdown */
  resetCountdown?: string;
}

export interface ProviderUsage {
  /** Session/daily usage */
  session?: UsageInfo;
  /** Weekly usage */
  weekly?: UsageInfo;
  /** Monthly usage */
  monthly?: UsageInfo;
  /** Cost in dollars (for cost-based providers) */
  cost?: {
    amount: number;
    currency: string;
    displayString: string;
  };
}

export interface ProviderStatus {
  /** Provider is operational */
  operational: boolean;
  /** Current status message */
  message?: string;
  /** Active incidents */
  incidents?: Array<{
    title: string;
    status: string;
    url?: string;
  }>;
}

export type ProviderState = 'idle' | 'loading' | 'success' | 'error';

export interface ProviderResult {
  state: ProviderState;
  usage?: ProviderUsage;
  status?: ProviderStatus;
  error?: string;
  lastUpdated: Date;
}

/**
 * Base class for all AI providers
 */
export abstract class BaseProvider {
  /** Unique identifier for this provider */
  abstract readonly id: string;
  
  /** Display name */
  abstract readonly name: string;
  
  /** Provider icon (emoji or path) */
  abstract readonly icon: string;
  
  /** Provider website URL */
  abstract readonly websiteUrl: string;
  
  /** Status page URL (for incident checking) */
  abstract readonly statusPageUrl?: string;
  
  /** Current state */
  protected _result: ProviderResult = {
    state: 'idle',
    lastUpdated: new Date(),
  };
  
  get result(): ProviderResult {
    return this._result;
  }
  
  /**
   * Fetch usage data from the provider
   */
  abstract fetchUsage(): Promise<ProviderUsage | null>;
  
  /**
   * Fetch provider status (optional)
   */
  async fetchStatus(): Promise<ProviderStatus | null> {
    return null;
  }
  
  /**
   * Check if the provider is configured/authenticated
   */
  abstract isConfigured(): Promise<boolean>;
  
  /**
   * Refresh all data for this provider
   */
  async refresh(): Promise<ProviderResult> {
    this._result = {
      ...this._result,
      state: 'loading',
    };
    
    try {
      const [usage, status] = await Promise.all([
        this.fetchUsage(),
        this.fetchStatus(),
      ]);
      
      this._result = {
        state: 'success',
        usage: usage ?? undefined,
        status: status ?? undefined,
        lastUpdated: new Date(),
      };
    } catch (error) {
      this._result = {
        state: 'error',
        error: error instanceof Error ? error.message : 'Unknown error',
        lastUpdated: new Date(),
      };
    }
    
    return this._result;
  }
}

/**
 * Helper to calculate percentage
 */
export function calculatePercentage(used: number, limit: number): number {
  if (limit <= 0) return 0;
  return Math.min(100, Math.round((used / limit) * 100));
}

/**
 * Helper to format usage string
 */
export function formatUsage(used: number, limit: number, unit = ''): string {
  const suffix = unit ? ` ${unit}` : '';
  return `${used.toLocaleString()}${suffix} / ${limit.toLocaleString()}${suffix}`;
}

/**
 * Helper to format reset countdown
 */
export function formatResetCountdown(resetTime: Date): string {
  const now = new Date();
  const diff = resetTime.getTime() - now.getTime();
  
  if (diff <= 0) return 'Resetting...';
  
  const hours = Math.floor(diff / (1000 * 60 * 60));
  const minutes = Math.floor((diff % (1000 * 60 * 60)) / (1000 * 60));
  
  if (hours > 24) {
    const days = Math.floor(hours / 24);
    return `${days}d ${hours % 24}h`;
  }
  
  if (hours > 0) {
    return `${hours}h ${minutes}m`;
  }
  
  return `${minutes}m`;
}
