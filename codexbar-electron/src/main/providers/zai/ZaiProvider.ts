/**
 * z.ai Provider
 * 
 * z.ai is an AI assistant. This provider checks for z.ai CLI or configuration.
 */

import { BaseProvider, ProviderUsage, ProviderStatus, calculatePercentage, formatUsage } from '../BaseProvider';
import { runCommand } from '../../utils/subprocess';
import { logger } from '../../utils/logger';
import path from 'path';
import fs from 'fs/promises';
import os from 'os';

export class ZaiProvider extends BaseProvider {
  readonly id = 'zai';
  readonly name = 'z.ai';
  readonly icon = '⚡';
  readonly websiteUrl = 'https://z.ai';
  readonly statusPageUrl = undefined;
  
  private zaiDir = path.join(os.homedir(), '.zai');
  
  async isConfigured(): Promise<boolean> {
    // Check for z.ai CLI
    try {
      const result = await runCommand('zai', ['--version']);
      if (result.exitCode === 0) return true;
    } catch {
      // CLI not found
    }
    
    // Check for config directory
    try {
      await fs.access(this.zaiDir);
      return true;
    } catch {
      return false;
    }
  }
  
  async fetchUsage(): Promise<ProviderUsage | null> {
    try {
      // Try to read config file
      const configPath = path.join(this.zaiDir, 'config.json');
      
      try {
        const content = await fs.readFile(configPath, 'utf-8');
        const config = JSON.parse(content);
        
        if (config.usage) {
          const used = config.usage.current ?? 0;
          const limit = config.usage.limit ?? 1000;
          
          return {
            session: {
              used,
              limit,
              percentage: calculatePercentage(used, limit),
              displayString: formatUsage(used, limit, 'credits'),
            },
          };
        }
      } catch {
        // Config file not found or invalid
      }
      
      // Try CLI version as fallback
      try {
        const result = await runCommand('zai', ['--version']);
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
    } catch (error) {
      logger.debug('z.ai: Could not read config:', error);
    }
    
    return null;
  }
  
  async fetchStatus(): Promise<ProviderStatus | null> {
    return { operational: true };
  }
}
