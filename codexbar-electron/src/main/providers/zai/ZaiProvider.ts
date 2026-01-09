/**
 * z.ai Provider
 */

import { BaseProvider, ProviderUsage, ProviderStatus, calculatePercentage, formatUsage } from '../BaseProvider';
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
  
  async isConfigured(): Promise<boolean> {
    // Check for z.ai config
    const configPath = path.join(os.homedir(), '.zai', 'config.json');
    try {
      await fs.access(configPath);
      return true;
    } catch {
      return false;
    }
  }
  
  async fetchUsage(): Promise<ProviderUsage | null> {
    try {
      const configPath = path.join(os.homedir(), '.zai', 'config.json');
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
    } catch (error) {
      logger.debug('z.ai: Could not read config:', error);
    }
    
    return null;
  }
  
  async fetchStatus(): Promise<ProviderStatus | null> {
    return { operational: true };
  }
}
