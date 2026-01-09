/**
 * GitHub Copilot Provider
 * 
 * Fetches usage from GitHub Copilot's usage API.
 */

import { BaseProvider, ProviderUsage, ProviderStatus, calculatePercentage, formatUsage } from '../BaseProvider';
import { logger } from '../../utils/logger';
import path from 'path';
import fs from 'fs/promises';
import os from 'os';

export class CopilotProvider extends BaseProvider {
  readonly id = 'copilot';
  readonly name = 'GitHub Copilot';
  readonly icon = '🐙';
  readonly websiteUrl = 'https://github.com/features/copilot';
  readonly statusPageUrl = 'https://www.githubstatus.com';
  
  async isConfigured(): Promise<boolean> {
    // Check for GitHub CLI auth or Copilot extension config
    const ghConfigPath = path.join(os.homedir(), '.config', 'gh', 'hosts.yml');
    const ghConfigPathWin = path.join(os.homedir(), 'AppData', 'Roaming', 'GitHub CLI', 'hosts.yml');
    
    try {
      await fs.access(ghConfigPath);
      return true;
    } catch {
      try {
        await fs.access(ghConfigPathWin);
        return true;
      } catch {
        return false;
      }
    }
  }
  
  async fetchUsage(): Promise<ProviderUsage | null> {
    // Copilot doesn't expose usage limits in the same way
    // It's typically unlimited for paid subscribers
    // We could track local completion counts if needed
    
    logger.debug('Copilot: Usage tracking not yet implemented');
    
    // Return a placeholder indicating active status
    return {
      session: {
        used: 0,
        limit: -1, // Unlimited
        percentage: 0,
        displayString: 'Unlimited',
      },
    };
  }
  
  async fetchStatus(): Promise<ProviderStatus | null> {
    // TODO: Check GitHub status page
    return { operational: true };
  }
}
