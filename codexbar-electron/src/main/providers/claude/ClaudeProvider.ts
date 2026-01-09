/**
 * Claude (Anthropic) Provider
 * 
 * Fetches usage from:
 * 1. Claude CLI (`claude --status` or `/status` command)
 * 2. Claude web API (with OAuth)
 * 3. Cost tracking from local logs
 */

import { BaseProvider, ProviderUsage, ProviderStatus, calculatePercentage, formatUsage, formatResetCountdown } from '../BaseProvider';
import { runCommand } from '../../utils/subprocess';
import { logger } from '../../utils/logger';
import path from 'path';
import fs from 'fs/promises';
import os from 'os';

export class ClaudeProvider extends BaseProvider {
  readonly id = 'claude';
  readonly name = 'Claude';
  readonly icon = '🎭';
  readonly websiteUrl = 'https://claude.ai';
  readonly statusPageUrl = 'https://status.anthropic.com';
  
  async isConfigured(): Promise<boolean> {
    try {
      // Check if claude CLI is available
      const result = await runCommand('claude', ['--version']);
      return result.exitCode === 0;
    } catch {
      // Also check for config file
      const configPath = path.join(os.homedir(), '.claude', 'config.json');
      try {
        await fs.access(configPath);
        return true;
      } catch {
        return false;
      }
    }
  }
  
  async fetchUsage(): Promise<ProviderUsage | null> {
    try {
      // Try running claude with status flag
      // Note: The actual command depends on the Claude CLI version
      const result = await runCommand('claude', ['--status'], { timeout: 10000 });
      
      if (result.exitCode === 0 && result.stdout) {
        return this.parseStatusOutput(result.stdout);
      }
      
      // Fallback: try to read from local state file
      return await this.readLocalState();
    } catch (error) {
      logger.error('Failed to fetch Claude usage:', error);
      return null;
    }
  }
  
  private parseStatusOutput(output: string): ProviderUsage | null {
    // Strip ANSI codes
    const cleanOutput = output.replace(/\x1b\[[0-9;]*m/g, '');
    
    const usage: ProviderUsage = {};
    
    // Parse various formats from Claude CLI output
    // Format: "Session: X/Y requests" or "X of Y requests used"
    
    const sessionPatterns = [
      /session[:\s]+(\d+)\s*\/\s*(\d+)/i,
      /(\d+)\s+of\s+(\d+)\s+requests?\s+used/i,
      /requests?[:\s]+(\d+)\s*\/\s*(\d+)/i,
    ];
    
    for (const pattern of sessionPatterns) {
      const match = cleanOutput.match(pattern);
      if (match) {
        const used = parseInt(match[1], 10);
        const limit = parseInt(match[2], 10);
        usage.session = {
          used,
          limit,
          percentage: calculatePercentage(used, limit),
          displayString: formatUsage(used, limit, 'requests'),
        };
        break;
      }
    }
    
    // Parse reset time
    const resetPatterns = [
      /reset[s]?\s+(?:in\s+)?(\d+[hm]?\s*\d*[hm]?)/i,
      /(\d+)\s*(?:hours?|h)\s*(?:(\d+)\s*(?:minutes?|m))?/i,
    ];
    
    for (const pattern of resetPatterns) {
      const match = cleanOutput.match(pattern);
      if (match && usage.session) {
        usage.session.resetCountdown = match[0].trim();
        break;
      }
    }
    
    // Parse cost if present
    const costMatch = cleanOutput.match(/\$(\d+\.?\d*)/);
    if (costMatch) {
      usage.cost = {
        amount: parseFloat(costMatch[1]),
        currency: 'USD',
        displayString: `$${costMatch[1]}`,
      };
    }
    
    return Object.keys(usage).length > 0 ? usage : null;
  }
  
  private async readLocalState(): Promise<ProviderUsage | null> {
    // Try to read Claude's local state file
    const statePath = path.join(os.homedir(), '.claude', 'state.json');
    
    try {
      const content = await fs.readFile(statePath, 'utf-8');
      const state = JSON.parse(content);
      
      if (state.usage) {
        const used = state.usage.used ?? 0;
        const limit = state.usage.limit ?? 100;
        
        return {
          session: {
            used,
            limit,
            percentage: calculatePercentage(used, limit),
            displayString: formatUsage(used, limit, 'requests'),
          },
        };
      }
    } catch {
      // State file doesn't exist or is invalid
    }
    
    return null;
  }
  
  async fetchStatus(): Promise<ProviderStatus | null> {
    // TODO: Implement status page scraping
    return { operational: true };
  }
}
