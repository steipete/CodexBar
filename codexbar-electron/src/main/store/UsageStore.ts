/**
 * Usage Store
 * 
 * Stores and tracks usage data for all providers.
 */

import Store from 'electron-store';
import { ProviderUsage } from '../providers/BaseProvider';
import { logger } from '../utils/logger';

interface UsageEntry {
  usage: ProviderUsage;
  lastUpdated: string; // ISO 8601
}

interface UsageSchema {
  providers: Record<string, UsageEntry>;
  history: Record<string, Array<{ timestamp: string; usage: ProviderUsage }>>;
}

const defaults: UsageSchema = {
  providers: {},
  history: {},
};

export class UsageStore {
  private store: Store<UsageSchema>;
  
  constructor() {
    this.store = new Store<UsageSchema>({
      name: 'usage',
      defaults,
    });
  }
  
  /**
   * Get all usage data
   */
  getAll(): Record<string, UsageEntry> {
    return this.store.get('providers');
  }
  
  /**
   * Get usage for a specific provider
   */
  getProviderUsage(providerId: string): UsageEntry | null {
    const providers = this.store.get('providers');
    return providers[providerId] ?? null;
  }
  
  /**
   * Set usage for a provider
   */
  setProviderUsage(providerId: string, usage: ProviderUsage): void {
    const providers = this.store.get('providers');
    const now = new Date().toISOString();
    
    providers[providerId] = {
      usage,
      lastUpdated: now,
    };
    
    this.store.set('providers', providers);
    
    // Also add to history (keep last 100 entries per provider)
    this.addToHistory(providerId, usage);
    
    logger.debug(`Usage updated for ${providerId}`);
  }
  
  /**
   * Add usage to history
   */
  private addToHistory(providerId: string, usage: ProviderUsage): void {
    const history = this.store.get('history');
    const providerHistory = history[providerId] ?? [];
    
    providerHistory.push({
      timestamp: new Date().toISOString(),
      usage,
    });
    
    // Keep only last 100 entries
    if (providerHistory.length > 100) {
      providerHistory.shift();
    }
    
    history[providerId] = providerHistory;
    this.store.set('history', history);
  }
  
  /**
   * Get usage history for a provider
   */
  getHistory(providerId: string): Array<{ timestamp: string; usage: ProviderUsage }> {
    const history = this.store.get('history');
    return history[providerId] ?? [];
  }
  
  /**
   * Clear all usage data
   */
  clear(): void {
    this.store.clear();
    logger.info('Usage data cleared');
  }
}
