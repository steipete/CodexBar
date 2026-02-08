/**
 * Factory/Droid Provider
 * 
 * Factory.ai (formerly Droid) is an AI coding assistant.
 * This provider checks for Factory CLI or configuration files.
 */

import { BaseProvider, ProviderUsage, ProviderStatus } from '../BaseProvider';
import { runCommand } from '../../utils/subprocess';
import { logger } from '../../utils/logger';
import path from 'path';
import fs from 'fs/promises';
import os from 'os';

export class FactoryProvider extends BaseProvider {
  readonly id = 'factory';
  readonly name = 'Factory';
  readonly icon = '🏭';
  readonly websiteUrl = 'https://factory.ai';
  readonly statusPageUrl = undefined;
  
  async isConfigured(): Promise<boolean> {
    // Check for factory CLI
    try {
      const result = await runCommand('factory', ['--version']);
      if (result.exitCode === 0) return true;
    } catch {
      // CLI not found
    }
    
    // Check for droid CLI (old name)
    try {
      const result = await runCommand('droid', ['--version']);
      if (result.exitCode === 0) return true;
    } catch {
      // CLI not found
    }
    
    // Check for config directories
    const configPaths = [
      path.join(os.homedir(), '.factory'),
      path.join(os.homedir(), '.droid'),
      path.join(os.homedir(), '.config', 'factory'),
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
    // Try to get version/status from CLI
    try {
      const result = await runCommand('factory', ['--version']);
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
    
    // Try droid CLI
    try {
      const result = await runCommand('droid', ['--version']);
      if (result.exitCode === 0) {
        return {
          session: {
            used: 0,
            limit: 0,
            percentage: 0,
            displayString: `Droid ${result.stdout.trim() || 'installed'}`,
          },
        };
      }
    } catch {
      // CLI not available
    }
    
    logger.debug('Factory: No CLI found');
    return null;
  }
  
  async fetchStatus(): Promise<ProviderStatus | null> {
    return { operational: true };
  }
}
