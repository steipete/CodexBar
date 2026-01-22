/**
 * MiniMax Provider
 * 
 * MiniMax is an AI model provider. This provider checks for
 * MiniMax API configuration or CLI tools.
 */

import { BaseProvider, ProviderUsage, ProviderStatus, calculatePercentage, formatUsage } from '../BaseProvider';
import { runCommand } from '../../utils/subprocess';
import { logger } from '../../utils/logger';
import path from 'path';
import fs from 'fs/promises';
import os from 'os';

export class MiniMaxProvider extends BaseProvider {
  readonly id = 'minimax';
  readonly name = 'MiniMax';
  readonly icon = '🎨';
  readonly websiteUrl = 'https://minimax.io';
  readonly statusPageUrl = undefined;
  
  async isConfigured(): Promise<boolean> {
    // Check for MiniMax API key in environment
    if (process.env.MINIMAX_API_KEY) {
      return true;
    }
    
    // Check for config files
    const configPaths = [
      path.join(os.homedir(), '.minimax', 'config.json'),
      path.join(os.homedir(), '.config', 'minimax', 'config.json'),
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
    // Try to read config file for usage info
    const configPaths = [
      path.join(os.homedir(), '.minimax', 'config.json'),
      path.join(os.homedir(), '.config', 'minimax', 'config.json'),
    ];
    
    for (const configPath of configPaths) {
      try {
        const content = await fs.readFile(configPath, 'utf-8');
        const config = JSON.parse(content);
        
        if (config.usage) {
          const used = config.usage.tokens ?? config.usage.credits ?? 0;
          const limit = config.usage.limit ?? 1000000;
          
          return {
            session: {
              used,
              limit,
              percentage: calculatePercentage(used, limit),
              displayString: formatUsage(used, limit, 'tokens'),
            },
          };
        }
        
        // Config exists but no usage data
        return {
          session: {
            used: 0,
            limit: 0,
            percentage: 0,
            displayString: 'Configured',
          },
        };
      } catch {
        // Try next path
      }
    }
    
    // Check for API key in environment
    if (process.env.MINIMAX_API_KEY) {
      return {
        session: {
          used: 0,
          limit: 0,
          percentage: 0,
          displayString: 'API Key Set',
        },
      };
    }
    
    logger.debug('MiniMax: Not configured');
    return null;
  }
  
  async fetchStatus(): Promise<ProviderStatus | null> {
    return { operational: true };
  }
}
