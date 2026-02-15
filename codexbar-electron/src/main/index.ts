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
  // Create tray icon
  const iconPath = path.join(__dirname, '../../assets/icon.png');
  let trayIcon: Electron.NativeImage;
  
  try {
    trayIcon = nativeImage.createFromPath(iconPath);
    if (trayIcon.isEmpty()) {
      throw new Error('Icon loaded but is empty');
    }
    // Resize for system tray (16x16 on Windows)
    trayIcon = trayIcon.resize({ width: 16, height: 16 });
    logger.info('Tray icon loaded from:', iconPath);
  } catch (err) {
    // Create a simple colored icon as fallback
    logger.warn('Tray icon not found, creating fallback icon:', err);
    // Create a 16x16 icon with a simple design
    const size = 16;
    const canvas = `
      <svg width="${size}" height="${size}" xmlns="http://www.w3.org/2000/svg">
        <rect width="${size}" height="${size}" rx="3" fill="#3b82f6"/>
        <text x="8" y="12" text-anchor="middle" fill="white" font-size="10" font-weight="bold">C</text>
      </svg>
    `;
    trayIcon = nativeImage.createFromDataURL(
      `data:image/svg+xml;base64,${Buffer.from(canvas).toString('base64')}`
    );
    trayIcon = trayIcon.resize({ width: 16, height: 16 });
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

  const iconPath = path.join(__dirname, '../../assets/icon.png');

  settingsWindow = new BrowserWindow({
    width: 500,
    height: 600,
    title: 'CodexBar',
    icon: iconPath, // Set the window icon explicitly for taskbar
    backgroundColor: '#09090b',
    titleBarStyle: 'hidden',
    titleBarOverlay: {
      color: '#09090b',
      symbolColor: '#a1a1aa',
      height: 36
    },
    trafficLightPosition: { x: 16, y: 16 },
    resizable: true,
    minimizable: true,
    maximizable: false,
    show: false, // Don't show until ready-to-show to prevent white flash
    webPreferences: {
      nodeIntegration: false,
      contextIsolation: true,
      preload: path.join(__dirname, 'preload.js'),
      sandbox: false // Required for some electron-store operations in renderer if used directly
    },
  });

  // Graceful showing
  settingsWindow.once('ready-to-show', () => {
    settingsWindow?.show();
  });

  // Load the renderer
  if (process.env.NODE_ENV === 'development') {
    settingsWindow.loadURL('http://localhost:5173');
    // settingsWindow.webContents.openDevTools({ mode: 'detach' });
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
    settingsStore?.setAny(key, value);
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

  // Remove default menu for a cleaner look
  Menu.setApplicationMenu(null);

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
