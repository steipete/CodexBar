/**
 * Settings Store
 * 
 * Persists user settings using electron-store.
 */

import Store from 'electron-store';
import { logger } from '../utils/logger';

interface SettingsSchema {
  enabledProviders: string[];
  refreshInterval: number; // seconds
  showNotifications: boolean;
  startAtLogin: boolean;
  showInDock: boolean;
  theme: 'system' | 'light' | 'dark';
}

const defaults: SettingsSchema = {
  enabledProviders: ['codex', 'claude', 'cursor', 'gemini'],
  refreshInterval: 300, // 5 minutes
  showNotifications: true,
  startAtLogin: false,
  showInDock: false,
  theme: 'system',
};

export class SettingsStore {
  private store: Store<SettingsSchema>;
  
  constructor() {
    this.store = new Store<SettingsSchema>({
      name: 'settings',
      defaults,
    });
    
    logger.info('Settings loaded:', this.store.store);
  }
  
  /**
   * Get all settings
   */
  getAll(): SettingsSchema {
    return this.store.store;
  }
  
  /**
   * Get a specific setting
   */
  get<K extends keyof SettingsSchema>(key: K): SettingsSchema[K] {
    return this.store.get(key);
  }
  
  /**
   * Set a specific setting
   */
  set<K extends keyof SettingsSchema>(key: K, value: SettingsSchema[K]): void {
    this.store.set(key, value);
    logger.debug(`Setting updated: ${key} = ${JSON.stringify(value)}`);
  }
  
  /**
   * Check if a provider is enabled
   */
  isProviderEnabled(providerId: string): boolean {
    return this.store.get('enabledProviders').includes(providerId);
  }
  
  /**
   * Enable or disable a provider
   */
  setProviderEnabled(providerId: string, enabled: boolean): void {
    const providers = this.store.get('enabledProviders');
    
    if (enabled && !providers.includes(providerId)) {
      this.store.set('enabledProviders', [...providers, providerId]);
    } else if (!enabled && providers.includes(providerId)) {
      this.store.set('enabledProviders', providers.filter(p => p !== providerId));
    }
  }
  
  /**
   * Get refresh interval in seconds
   */
  getRefreshInterval(): number {
    return this.store.get('refreshInterval');
  }
  
  /**
   * Set refresh interval in seconds
   */
  setRefreshInterval(seconds: number): void {
    this.store.set('refreshInterval', Math.max(60, seconds)); // Minimum 1 minute
  }
  
  /**
   * Reset all settings to defaults
   */
  reset(): void {
    this.store.clear();
    logger.info('Settings reset to defaults');
  }
}
