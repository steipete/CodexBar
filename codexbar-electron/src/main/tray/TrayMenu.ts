/**
 * System Tray Menu Builder
 * 
 * Creates the context menu shown when clicking the tray icon.
 */

import { Menu, MenuItem, shell } from 'electron';
import { ProviderManager } from '../providers/ProviderManager';
import { SettingsStore } from '../store/SettingsStore';
import { UsageStore } from '../store/UsageStore';

interface TrayMenuOptions {
  providerManager: ProviderManager;
  settingsStore: SettingsStore;
  usageStore: UsageStore;
  onSettingsClick: () => void;
  onQuitClick: () => void;
  onRefreshClick: () => void;
}

export async function createTrayMenu(options: TrayMenuOptions): Promise<Menu> {
  const { providerManager, settingsStore, onSettingsClick, onQuitClick, onRefreshClick } = options;
  
  const menu = new Menu();
  
  // Header
  menu.append(new MenuItem({
    label: 'CodexBar',
    enabled: false,
  }));
  
  menu.append(new MenuItem({ type: 'separator' }));
  
  // Provider usage items
  const providers = providerManager.getAllProviderStates();
  const enabledProviders = providers.filter(p => p.enabled);
  
  if (enabledProviders.length === 0) {
    menu.append(new MenuItem({
      label: 'No providers enabled',
      enabled: false,
    }));
  } else {
    for (const provider of enabledProviders) {
      const submenu = new Menu();
      
      // Usage info
      if (provider.result.usage) {
        const { usage } = provider.result;
        
        if (usage.session) {
          submenu.append(new MenuItem({
            label: `Session: ${usage.session.displayString} (${usage.session.percentage}%)`,
            enabled: false,
          }));
          
          if (usage.session.resetCountdown) {
            submenu.append(new MenuItem({
              label: `  Resets in: ${usage.session.resetCountdown}`,
              enabled: false,
            }));
          }
        }
        
        if (usage.weekly) {
          submenu.append(new MenuItem({
            label: `Weekly: ${usage.weekly.displayString} (${usage.weekly.percentage}%)`,
            enabled: false,
          }));
        }
        
        if (usage.monthly) {
          submenu.append(new MenuItem({
            label: `Monthly: ${usage.monthly.displayString} (${usage.monthly.percentage}%)`,
            enabled: false,
          }));
        }
        
        if (usage.cost) {
          submenu.append(new MenuItem({
            label: `Cost: ${usage.cost.displayString}`,
            enabled: false,
          }));
        }
      } else if (provider.result.state === 'loading') {
        submenu.append(new MenuItem({
          label: 'Loading...',
          enabled: false,
        }));
      } else if (provider.result.state === 'error') {
        submenu.append(new MenuItem({
          label: `Error: ${provider.result.error}`,
          enabled: false,
        }));
      } else {
        submenu.append(new MenuItem({
          label: 'No data',
          enabled: false,
        }));
      }
      
      submenu.append(new MenuItem({ type: 'separator' }));
      
      // Open website
      submenu.append(new MenuItem({
        label: 'Open Website',
        click: () => {
          const p = providerManager.getProvider(provider.id);
          if (p?.websiteUrl) {
            shell.openExternal(p.websiteUrl);
          }
        },
      }));
      
      // Status indicator
      let statusIcon = '⚪'; // idle
      if (provider.result.state === 'success') statusIcon = '🟢';
      else if (provider.result.state === 'loading') statusIcon = '🟡';
      else if (provider.result.state === 'error') statusIcon = '🔴';
      
      menu.append(new MenuItem({
        label: `${provider.icon} ${provider.name} ${statusIcon}`,
        submenu,
      }));
    }
  }
  
  menu.append(new MenuItem({ type: 'separator' }));
  
  // Actions
  menu.append(new MenuItem({
    label: 'Refresh All',
    accelerator: 'CmdOrCtrl+R',
    click: onRefreshClick,
  }));
  
  menu.append(new MenuItem({ type: 'separator' }));
  
  // Settings
  menu.append(new MenuItem({
    label: 'Settings...',
    accelerator: 'CmdOrCtrl+,',
    click: onSettingsClick,
  }));
  
  // Provider toggles submenu
  const toggleSubmenu = new Menu();
  for (const provider of providers) {
    toggleSubmenu.append(new MenuItem({
      label: `${provider.icon} ${provider.name}`,
      type: 'checkbox',
      checked: provider.enabled,
      click: () => {
        settingsStore.setProviderEnabled(provider.id, !provider.enabled);
        if (!provider.enabled) {
          providerManager.refreshProvider(provider.id);
        }
      },
    }));
  }
  
  menu.append(new MenuItem({
    label: 'Providers',
    submenu: toggleSubmenu,
  }));
  
  menu.append(new MenuItem({ type: 'separator' }));
  
  // About & Quit
  menu.append(new MenuItem({
    label: 'About CodexBar',
    click: () => {
      shell.openExternal('https://github.com/steipete/CodexBar');
    },
  }));
  
  menu.append(new MenuItem({
    label: 'Quit CodexBar',
    accelerator: 'CmdOrCtrl+Q',
    click: onQuitClick,
  }));
  
  return menu;
}
