/**
 * Preload script - exposes safe APIs to renderer process
 */

import { contextBridge, ipcRenderer } from 'electron';

// Expose protected methods to the renderer process
contextBridge.exposeInMainWorld('codexbar', {
  // Provider methods
  getProviders: () => ipcRenderer.invoke('get-providers'),
  toggleProvider: (id: string, enabled: boolean) => 
    ipcRenderer.invoke('toggle-provider', id, enabled),
  refreshAll: () => ipcRenderer.invoke('refresh-all'),
  
  // Settings methods
  getSettings: () => ipcRenderer.invoke('get-settings'),
  setSetting: (key: string, value: unknown) => 
    ipcRenderer.invoke('set-setting', key, value),
  
  // Usage methods
  getUsage: () => ipcRenderer.invoke('get-usage'),
  
  // Event listeners
  onUpdate: (callback: () => void) => {
    ipcRenderer.on('providers-updated', callback);
    return () => ipcRenderer.removeListener('providers-updated', callback);
  },
});

// Type definitions for the exposed API
export interface CodexBarAPI {
  getProviders: () => Promise<ProviderState[]>;
  toggleProvider: (id: string, enabled: boolean) => Promise<void>;
  refreshAll: () => Promise<void>;
  getSettings: () => Promise<Settings>;
  setSetting: (key: string, value: unknown) => Promise<void>;
  getUsage: () => Promise<UsageData>;
  onUpdate: (callback: () => void) => () => void;
}

export interface ProviderState {
  id: string;
  name: string;
  enabled: boolean;
  status: 'ok' | 'loading' | 'error' | 'disabled';
  usage?: {
    used: number;
    limit: number;
    percentage: number;
    resetTime?: string;
  };
  error?: string;
}

export interface Settings {
  enabledProviders: string[];
  refreshInterval: number;
  showNotifications: boolean;
  startAtLogin: boolean;
}

export interface UsageData {
  [providerId: string]: {
    session: { used: number; limit: number };
    weekly: { used: number; limit: number };
    lastUpdated: string;
  };
}

declare global {
  interface Window {
    codexbar: CodexBarAPI;
  }
}
