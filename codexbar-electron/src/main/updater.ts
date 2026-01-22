/**
 * Auto-updater setup using electron-updater
 */

import { autoUpdater } from 'electron-updater';
import { logger } from './utils/logger';

export function setupAutoUpdater(): void {
  // Configure auto-updater
  autoUpdater.autoDownload = false;
  autoUpdater.autoInstallOnAppQuit = true;
  
  // Event handlers
  autoUpdater.on('checking-for-update', () => {
    logger.info('Checking for updates...');
  });
  
  autoUpdater.on('update-available', (info) => {
    logger.info(`Update available: ${info.version}`);
    // TODO: Show notification or prompt user
    // For now, auto-download
    autoUpdater.downloadUpdate();
  });
  
  autoUpdater.on('update-not-available', () => {
    logger.info('No updates available');
  });
  
  autoUpdater.on('download-progress', (progress) => {
    logger.debug(`Download progress: ${progress.percent.toFixed(1)}%`);
  });
  
  autoUpdater.on('update-downloaded', (info) => {
    logger.info(`Update downloaded: ${info.version}`);
    // TODO: Notify user that update is ready
    // autoUpdater.quitAndInstall() to install immediately
  });
  
  autoUpdater.on('error', (error) => {
    logger.error('Auto-updater error:', error);
  });
  
  // Check for updates on startup (after a delay)
  setTimeout(() => {
    autoUpdater.checkForUpdates().catch((err) => {
      logger.warn('Failed to check for updates:', err);
    });
  }, 10000); // 10 second delay
  
  // Check for updates every 4 hours
  setInterval(() => {
    autoUpdater.checkForUpdates().catch((err) => {
      logger.warn('Failed to check for updates:', err);
    });
  }, 4 * 60 * 60 * 1000);
}

/**
 * Manually check for updates
 */
export async function checkForUpdates(): Promise<void> {
  await autoUpdater.checkForUpdates();
}

/**
 * Quit and install downloaded update
 */
export function installUpdate(): void {
  autoUpdater.quitAndInstall();
}
