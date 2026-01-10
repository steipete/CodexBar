/**
 * Kiro Provider
 * 
 * Kiro is an AI coding assistant from Amazon (AWS).
 * This provider checks for Kiro CLI or VS Code extension.
 */

import { BaseProvider, ProviderUsage, ProviderStatus } from '../BaseProvider';
import { runCommand } from '../../utils/subprocess';
import { logger } from '../../utils/logger';
import path from 'path';
import fs from 'fs/promises';
import os from 'os';

export class KiroProvider extends BaseProvider {
  readonly id = 'kiro';
  readonly name = 'Kiro';
  readonly icon = '🎯';
  readonly websiteUrl = 'https://kiro.dev';
  readonly statusPageUrl = undefined;
  
  async isConfigured(): Promise<boolean> {
    // Check for kiro CLI
    try {
      const result = await runCommand('kiro', ['--version']);
      if (result.exitCode === 0) return true;
    } catch {
      // CLI not found
    }
    
    // Check for VS Code extension
    const vscodeExtensions = path.join(os.homedir(), '.vscode', 'extensions');
    try {
      const extensions = await fs.readdir(vscodeExtensions);
      const hasKiro = extensions.some(ext => 
        ext.toLowerCase().includes('kiro') || ext.includes('amazon.kiro')
      );
      if (hasKiro) return true;
    } catch {
      // Extensions dir not found
    }
    
    // Check for config directories
    const configPaths = [
      path.join(os.homedir(), '.kiro'),
      path.join(os.homedir(), '.config', 'kiro'),
      path.join(os.homedir(), 'AppData', 'Roaming', 'Kiro'),
    ];
    
    for (const configPath of configPaths) {
      try {
        await fs.access(configPath);
        return true;
      } catch {
        // Try next
      }
    }
    
    return false;
  }
  
  async fetchUsage(): Promise<ProviderUsage | null> {
    // Try to get version from CLI
    try {
      const result = await runCommand('kiro', ['--version']);
      if (result.exitCode === 0) {
        return {
          session: {
            used: 0,
            limit: 0,
            percentage: 0,
            displayString: `CLI ${result.stdout.trim() || 'installed'}`,
          },
        };
      }
    } catch {
      // CLI not available
    }
    
    // Check for VS Code extension
    const vscodeExtensions = path.join(os.homedir(), '.vscode', 'extensions');
    try {
      const extensions = await fs.readdir(vscodeExtensions);
      const kiroExt = extensions.find(ext => 
        ext.toLowerCase().includes('kiro') || ext.includes('amazon.kiro')
      );
      if (kiroExt) {
        return {
          session: {
            used: 0,
            limit: 0,
            percentage: 0,
            displayString: 'VS Code Extension',
          },
        };
      }
    } catch {
      // Extensions dir not found
    }
    
    logger.debug('Kiro: Not configured');
    return null;
  }
  
  async fetchStatus(): Promise<ProviderStatus | null> {
    return { operational: true };
  }
}
