/**
 * Gemini (Google) Provider
 * 
 * Fetches usage from:
 * 1. Gemini CLI (`gemini --stats`)
 * 2. Google Cloud API
 */

import { BaseProvider, ProviderUsage, ProviderStatus, calculatePercentage, formatUsage } from '../BaseProvider';
import { runCommand } from '../../utils/subprocess';
import { logger } from '../../utils/logger';
import path from 'path';
import fs from 'fs/promises';
import os from 'os';

export class GeminiProvider extends BaseProvider {
  readonly id = 'gemini';
  readonly name = 'Gemini';
  readonly icon = '💎';
  readonly websiteUrl = 'https://gemini.google.com';
  readonly statusPageUrl = 'https://status.cloud.google.com';
  
  async isConfigured(): Promise<boolean> {
    try {
      // Check if gemini CLI exists
      const result = await runCommand('gemini', ['--version']);
      if (result.exitCode === 0) return true;
    } catch {
      // CLI not found
    }
    
    // Check for Google Cloud credentials
    const credPath = path.join(os.homedir(), '.config', 'gcloud', 'application_default_credentials.json');
    try {
      await fs.access(credPath);
      return true;
    } catch {
      return false;
    }
  }
  
  async fetchUsage(): Promise<ProviderUsage | null> {
    try {
      // Try gemini CLI first
      const result = await runCommand('gemini', ['--stats'], { timeout: 10000 });
      
      if (result.exitCode === 0 && result.stdout) {
        return this.parseStatsOutput(result.stdout);
      }
    } catch (error) {
      logger.debug('Gemini CLI not available:', error);
    }
    
    // TODO: Implement Google Cloud API fallback
    return null;
  }
  
  private parseStatsOutput(output: string): ProviderUsage | null {
    // Parse gemini --stats output
    // Format typically includes table with usage numbers
    
    const usage: ProviderUsage = {};
    
    // Look for request counts
    const requestMatch = output.match(/requests?[:\s]+(\d+)\s*\/\s*(\d+)/i);
    if (requestMatch) {
      const used = parseInt(requestMatch[1], 10);
      const limit = parseInt(requestMatch[2], 10);
      usage.session = {
        used,
        limit,
        percentage: calculatePercentage(used, limit),
        displayString: formatUsage(used, limit, 'requests'),
      };
    }
    
    // Look for token counts
    const tokenMatch = output.match(/tokens?[:\s]+(\d+)\s*\/\s*(\d+)/i);
    if (tokenMatch) {
      const used = parseInt(tokenMatch[1], 10);
      const limit = parseInt(tokenMatch[2], 10);
      usage.weekly = {
        used,
        limit,
        percentage: calculatePercentage(used, limit),
        displayString: formatUsage(used, limit, 'tokens'),
      };
    }
    
    return Object.keys(usage).length > 0 ? usage : null;
  }
  
  async fetchStatus(): Promise<ProviderStatus | null> {
    return { operational: true };
  }
}
