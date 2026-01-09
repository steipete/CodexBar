/**
 * CodexBar - Main Process Entry Point
 * 
 * This is the Electron main process that handles:
 * - System tray integration
 * - Provider management and polling
 * - IPC communication with renderer
 * - Auto-updates
 */

import { app, BrowserWindow, Tray, Menu, nativeImage, ipcMain } from 'electron';
import path from 'path';
import { ProviderManager } from './providers/ProviderManager';
import { SettingsStore } from './store/SettingsStore';
import { UsageStore } from './store/UsageStore';
import { setupAutoUpdater } from './updater';
import { createTrayMenu } from './tray/TrayMenu';
import { logger } from './utils/logger';

// Keep references to prevent garbage collection
let tray: Tray | null = null;
let settingsWindow: BrowserWindow | null = null;
let providerManager: ProviderManager | null = null;
let settingsStore: SettingsStore | null = null;
let usageStore: UsageStore | null = null;

// Prevent multiple instances
const gotTheLock = app.requestSingleInstanceLock();
if (!gotTheLock) {
  app.quit();
}

async function createTray(): Promise<void> {
  // Create tray icon - use a simple icon for now
  const iconPath = path.join(__dirname, '../../assets/icon.png');
  let trayIcon: Electron.NativeImage;
  
  try {
    trayIcon = nativeImage.createFromPath(iconPath);
    // Resize for system tray (16x16 on Windows, 22x22 on Linux)
    trayIcon = trayIcon.resize({ width: 16, height: 16 });
  } catch {
    // Fallback to empty icon if asset not found
    trayIcon = nativeImage.createEmpty();
    logger.warn('Tray icon not found, using empty icon');
  }

  tray = new Tray(trayIcon);
  tray.setToolTip('CodexBar - AI Usage Monitor');
  
  // Update tray menu
  await updateTrayMenu();
  
  // Handle click (Windows: show menu, Linux: might differ)
  tray.on('click', () => {
    tray?.popUpContextMenu();
  });
}

async function updateTrayMenu(): Promise<void> {
  if (!tray || !providerManager || !settingsStore || !usageStore) return;
  
  const menu = await createTrayMenu({
    providerManager,
    settingsStore,
    usageStore,
    onSettingsClick: () => createSettingsWindow(),
    onQuitClick: () => app.quit(),
    onRefreshClick: () => providerManager?.refreshAll(),
  });
  
  tray.setContextMenu(menu);
}

function createSettingsWindow(): void {
  if (settingsWindow) {
    settingsWindow.focus();
    return;
  }

  settingsWindow = new BrowserWindow({
    width: 600,
    height: 500,
    title: 'CodexBar Settings',
    resizable: true,
    minimizable: true,
    maximizable: false,
    webPreferences: {
      nodeIntegration: false,
      contextIsolation: true,
      preload: path.join(__dirname, 'preload.js'),
    },
  });

  // Load the renderer
  if (process.env.NODE_ENV === 'development') {
    settingsWindow.loadURL('http://localhost:5173');
    settingsWindow.webContents.openDevTools();
  } else {
    settingsWindow.loadFile(path.join(__dirname, '../renderer/index.html'));
  }

  settingsWindow.on('closed', () => {
    settingsWindow = null;
  });
}

function setupIPC(): void {
  // Get all provider states
  ipcMain.handle('get-providers', async () => {
    return providerManager?.getAllProviderStates() ?? [];
  });

  // Get settings
  ipcMain.handle('get-settings', async () => {
    return settingsStore?.getAll() ?? {};
  });

  // Update settings
  ipcMain.handle('set-setting', async (_event, key: string, value: unknown) => {
    settingsStore?.set(key, value);
    await updateTrayMenu();
  });

  // Toggle provider
  ipcMain.handle('toggle-provider', async (_event, providerId: string, enabled: boolean) => {
    settingsStore?.setProviderEnabled(providerId, enabled);
    if (enabled) {
      await providerManager?.refreshProvider(providerId);
    }
    await updateTrayMenu();
  });

  // Manual refresh
  ipcMain.handle('refresh-all', async () => {
    await providerManager?.refreshAll();
    await updateTrayMenu();
  });

  // Get usage data
  ipcMain.handle('get-usage', async () => {
    return usageStore?.getAll() ?? {};
  });
}

async function initialize(): Promise<void> {
  logger.info('CodexBar starting...');

  // Initialize stores
  settingsStore = new SettingsStore();
  usageStore = new UsageStore();
  
  // Initialize provider manager
  providerManager = new ProviderManager(settingsStore, usageStore);
  
  // Set up IPC handlers
  setupIPC();
  
  // Create system tray
  await createTray();
  
  // Start provider polling
  providerManager.on('update', async () => {
    await updateTrayMenu();
  });
  
  await providerManager.startPolling();
  
  // Set up auto-updater (production only)
  if (process.env.NODE_ENV !== 'development') {
    setupAutoUpdater();
  }
  
  logger.info('CodexBar initialized successfully');
}

// App lifecycle
app.on('ready', initialize);

app.on('window-all-closed', () => {
  // Don't quit on window close - we're a tray app
});

app.on('before-quit', () => {
  providerManager?.stopPolling();
});

app.on('second-instance', () => {
  // Focus settings window if trying to launch second instance
  if (settingsWindow) {
    settingsWindow.focus();
  }
});

// Handle uncaught errors
process.on('uncaughtException', (error) => {
  logger.error('Uncaught exception:', error);
});

process.on('unhandledRejection', (reason) => {
  logger.error('Unhandled rejection:', reason);
});
