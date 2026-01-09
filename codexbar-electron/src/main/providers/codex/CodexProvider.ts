/**
 * Codex (OpenAI) Provider
 * 
 * Fetches usage from:
 * 1. Codex CLI (`codex --status`)
 * 2. OpenAI Dashboard (web scraping with cookies)
 * 3. Cost tracking from local logs
 */

import { BaseProvider, ProviderUsage, ProviderStatus, calculatePercentage, formatUsage } from '../BaseProvider';
import { runCommand } from '../../utils/subprocess';
import { logger } from '../../utils/logger';

export class CodexProvider extends BaseProvider {
  readonly id = 'codex';
  readonly name = 'Codex';
  readonly icon = '🤖';
  readonly websiteUrl = 'https://platform.openai.com';
  readonly statusPageUrl = 'https://status.openai.com';
  
  async isConfigured(): Promise<boolean> {
    try {
      // Check if codex CLI is available
      const result = await runCommand('codex', ['--version']);
      return result.exitCode === 0;
    } catch {
      return false;
    }
  }
  
  async fetchUsage(): Promise<ProviderUsage | null> {
    try {
      // Run codex --status to get usage info
      const result = await runCommand('codex', ['--status']);
      
      if (result.exitCode !== 0) {
        logger.warn('Codex CLI returned non-zero exit code');
        return null;
      }
      
      return this.parseStatusOutput(result.stdout);
    } catch (error) {
      logger.error('Failed to fetch Codex usage:', error);
      return null;
    }
  }
  
  private parseStatusOutput(output: string): ProviderUsage | null {
    // Parse the codex --status output
    // Format varies, but typically includes:
    // - Requests used/limit
    // - Session info
    // - Reset time
    
    const usage: ProviderUsage = {};
    
    // Try to parse session usage
    const sessionMatch = output.match(/session[:\s]+(\d+)\s*\/\s*(\d+)/i);
    if (sessionMatch) {
      const used = parseInt(sessionMatch[1], 10);
      const limit = parseInt(sessionMatch[2], 10);
      usage.session = {
        used,
        limit,
        percentage: calculatePercentage(used, limit),
        displayString: formatUsage(used, limit, 'requests'),
      };
    }
    
    // Try to parse weekly/monthly usage
    const weeklyMatch = output.match(/week(?:ly)?[:\s]+(\d+)\s*\/\s*(\d+)/i);
    if (weeklyMatch) {
      const used = parseInt(weeklyMatch[1], 10);
      const limit = parseInt(weeklyMatch[2], 10);
      usage.weekly = {
        used,
        limit,
        percentage: calculatePercentage(used, limit),
        displayString: formatUsage(used, limit, 'requests'),
      };
    }
    
    // Parse reset time if present
    const resetMatch = output.match(/reset[s]?\s+(?:in\s+)?(.+)/i);
    if (resetMatch && usage.session) {
      usage.session.resetCountdown = resetMatch[1].trim();
    }
    
    return Object.keys(usage).length > 0 ? usage : null;
  }
  
  async fetchStatus(): Promise<ProviderStatus | null> {
    // TODO: Implement status page scraping
    return { operational: true };
  }
}
