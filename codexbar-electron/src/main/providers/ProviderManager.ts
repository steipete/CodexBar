/**
 * Provider Manager
 * 
 * Manages all AI providers, handles polling, and emits updates.
 */

import { EventEmitter } from 'events';
import { BaseProvider, ProviderResult } from './BaseProvider';
import { SettingsStore } from '../store/SettingsStore';
import { UsageStore } from '../store/UsageStore';
import { logger } from '../utils/logger';

// Import all providers
import { CodexProvider } from './codex/CodexProvider';
import { ClaudeProvider } from './claude/ClaudeProvider';
import { CursorProvider } from './cursor/CursorProvider';
import { GeminiProvider } from './gemini/GeminiProvider';
import { CopilotProvider } from './copilot/CopilotProvider';
import { AntigravityProvider } from './antigravity/AntigravityProvider';
import { FactoryProvider } from './factory/FactoryProvider';
import { ZaiProvider } from './zai/ZaiProvider';
import { KiroProvider } from './kiro/KiroProvider';
import { VertexAIProvider } from './vertexai/VertexAIProvider';
import { AugmentProvider } from './augment/AugmentProvider';
import { MiniMaxProvider } from './minimax/MiniMaxProvider';

export interface ProviderManagerEvents {
  update: () => void;
  error: (providerId: string, error: Error) => void;
}

export class ProviderManager extends EventEmitter {
  private providers: Map<string, BaseProvider> = new Map();
  private pollingInterval: NodeJS.Timeout | null = null;
  private settingsStore: SettingsStore;
  private usageStore: UsageStore;
  
  constructor(settingsStore: SettingsStore, usageStore: UsageStore) {
    super();
    this.settingsStore = settingsStore;
    this.usageStore = usageStore;
    this.initializeProviders();
  }
  
  private initializeProviders(): void {
    // Register all providers
    const allProviders: BaseProvider[] = [
      new CodexProvider(),
      new ClaudeProvider(),
      new CursorProvider(),
      new GeminiProvider(),
      new CopilotProvider(),
      new AntigravityProvider(),
      new FactoryProvider(),
      new ZaiProvider(),
      new KiroProvider(),
      new VertexAIProvider(),
      new AugmentProvider(),
      new MiniMaxProvider(),
    ];
    
    for (const provider of allProviders) {
      this.providers.set(provider.id, provider);
      logger.info(`Registered provider: ${provider.name} (${provider.id})`);
    }
  }
  
  /**
   * Get all registered providers
   */
  getAllProviders(): BaseProvider[] {
    return Array.from(this.providers.values());
  }
  
  /**
   * Get a specific provider by ID
   */
  getProvider(id: string): BaseProvider | undefined {
    return this.providers.get(id);
  }
  
  /**
   * Get enabled providers based on settings
   */
  getEnabledProviders(): BaseProvider[] {
    return this.getAllProviders().filter(p => 
      this.settingsStore.isProviderEnabled(p.id)
    );
  }
  
  /**
   * Get state for all providers (for IPC)
   */
  getAllProviderStates(): Array<{
    id: string;
    name: string;
    icon: string;
    enabled: boolean;
    result: ProviderResult;
  }> {
    return this.getAllProviders().map(p => ({
      id: p.id,
      name: p.name,
      icon: p.icon,
      enabled: this.settingsStore.isProviderEnabled(p.id),
      result: p.result,
    }));
  }
  
  /**
   * Refresh a specific provider
   */
  async refreshProvider(id: string): Promise<ProviderResult | null> {
    const provider = this.providers.get(id);
    if (!provider) {
      logger.warn(`Provider not found: ${id}`);
      return null;
    }
    
    if (!this.settingsStore.isProviderEnabled(id)) {
      logger.debug(`Provider disabled, skipping: ${id}`);
      return null;
    }
    
    try {
      const isConfigured = await provider.isConfigured();
      if (!isConfigured) {
        logger.debug(`Provider not configured: ${id}`);
        return null;
      }
      
      logger.info(`Refreshing provider: ${provider.name}`);
      const result = await provider.refresh();
      
      // Store usage data
      if (result.usage) {
        this.usageStore.setProviderUsage(id, result.usage);
      }
      
      this.emit('update');
      return result;
    } catch (error) {
      logger.error(`Error refreshing provider ${id}:`, error);
      this.emit('error', id, error);
      return null;
    }
  }
  
  /**
   * Refresh all enabled providers
   */
  async refreshAll(): Promise<void> {
    logger.info('Refreshing all providers...');
    
    const enabledProviders = this.getEnabledProviders();
    
    await Promise.allSettled(
      enabledProviders.map(p => this.refreshProvider(p.id))
    );
    
    logger.info('All providers refreshed');
    this.emit('update');
  }
  
  /**
   * Start polling for updates
   */
  async startPolling(): Promise<void> {
    // Initial refresh
    await this.refreshAll();
    
    // Set up polling interval
    const intervalMs = this.settingsStore.getRefreshInterval() * 1000;
    
    this.pollingInterval = setInterval(() => {
      this.refreshAll().catch(err => {
        logger.error('Polling error:', err);
      });
    }, intervalMs);
    
    logger.info(`Polling started with interval: ${intervalMs}ms`);
  }
  
  /**
   * Stop polling
   */
  stopPolling(): void {
    if (this.pollingInterval) {
      clearInterval(this.pollingInterval);
      this.pollingInterval = null;
      logger.info('Polling stopped');
    }
  }
  
  /**
   * Update polling interval
   */
  updatePollingInterval(seconds: number): void {
    this.stopPolling();
    this.settingsStore.setRefreshInterval(seconds);
    this.startPolling();
  }
}
