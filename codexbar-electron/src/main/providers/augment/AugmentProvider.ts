/**
 * Augment Provider
 * 
 * Augment is an AI coding assistant. This provider checks for
 * Augment CLI, VS Code extension, or configuration files.
 */

import { BaseProvider, ProviderUsage, ProviderStatus } from '../BaseProvider';
import { runCommand } from '../../utils/subprocess';
import { logger } from '../../utils/logger';
import path from 'path';
import fs from 'fs/promises';
import os from 'os';

export class AugmentProvider extends BaseProvider {
  readonly id = 'augment';
  readonly name = 'Augment';
  readonly icon = '🔮';
  readonly websiteUrl = 'https://augment.dev';
  readonly statusPageUrl = undefined;
  
  async isConfigured(): Promise<boolean> {
    // Check for augment CLI
    try {
      const result = await runCommand('augment', ['--version']);
      if (result.exitCode === 0) return true;
    } catch {
      // CLI not found
    }
    
    // Check for VS Code extension
    const vscodeExtensions = path.join(os.homedir(), '.vscode', 'extensions');
    try {
      const extensions = await fs.readdir(vscodeExtensions);
      const hasAugment = extensions.some(ext => 
        ext.toLowerCase().includes('augment')
      );
      if (hasAugment) return true;
    } catch {
      // Extensions dir not found
    }
    
    // Check for config directories
    const configPaths = [
      path.join(os.homedir(), '.augment'),
      path.join(os.homedir(), '.config', 'augment'),
      path.join(os.homedir(), 'AppData', 'Roaming', 'Augment'),
      path.join(os.homedir(), 'AppData', 'Local', 'Augment'),
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
      const result = await runCommand('augment', ['--version']);
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
      const augmentExt = extensions.find(ext => 
        ext.toLowerCase().includes('augment')
      );
      if (augmentExt) {
        // Try to extract version
        const versionMatch = augmentExt.match(/augment[^-]*-(\d+\.\d+\.\d+)/i);
        const version = versionMatch ? `v${versionMatch[1]}` : '';
        
        return {
          session: {
            used: 0,
            limit: 0,
            percentage: 0,
            displayString: `VS Code${version ? ` ${version}` : ''}`,
          },
        };
      }
    } catch {
      // Extensions dir not found
    }
    
    logger.debug('Augment: Not configured');
    return null;
  }
  
  async fetchStatus(): Promise<ProviderStatus | null> {
    return { operational: true };
  }
}
